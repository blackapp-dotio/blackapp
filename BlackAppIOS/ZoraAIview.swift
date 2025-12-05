//
//  ZoraAIView.swift
//  BlackAppIOS
//
//  Self-contained Jarvis-style Zora panel with safe networking + TTS + voice input
//

import SwiftUI
import AVFoundation
import Speech
import FirebaseAuth

// MARK: - Server models (namespaced to avoid collisions)
private struct ZOR_Resp: Decodable {
    let ok: Bool
    let tookMs: Int?
    let cards: [ZOR_Card]?
    let error: String?
}

private struct ZOR_Card: Decodable, Identifiable {
    let type: String
    let text: String?
    let items: [String]?
    let label: String?
    let action: ZOR_Action?
    let card: ZOR_EventCard?

    var id: String {
        if let t = text, !t.isEmpty { return "\(type):\(t)" }
        if let l = label, !l.isEmpty { return "\(type):\(l)" }
        return UUID().uuidString
    }
}

private struct ZOR_EventCard: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let image: String?
    let chips: [String]?
}

private struct ZOR_Action: Decodable {
    let type: String
    let url: String?
    let id: String?
    let name: String?
    let payload: [String: String]?
}

// MARK: - Local chat models (namespaced)
private enum ZRole { case user, zora, system }

private struct ZMessage: Identifiable {
    let id = UUID()
    let role: ZRole
    let text: AttributedString
}

// MARK: - Speech controller (fixes "self is immutable" by moving mutation out of the View)
final class SpeechIOController: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var micPermGranted: Bool = false
    @Published var authStatus: SFSpeechRecognizerAuthorizationStatus?
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var inputNode: AVAudioInputNode? { audioEngine.inputNode }
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }

    /// Request microphone + speech permissions (call once, e.g., onAppear)
    func requestPermissions() async {
        // Mic
        let micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            audioSession.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        await MainActor.run { self.micPermGranted = micOK }

        // Speech
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s) }
        }
        await MainActor.run { self.authStatus = status }
    }

    /// Start speech recognition. `onUpdate(text, isFinal)` is called on the main thread.
    func start(onUpdate: @escaping (_ text: String, _ isFinal: Bool) -> Void) {
        guard micPermGranted else {
            onUpdate("", true)
            return
        }
        if let status = authStatus, status == .denied || status == .restricted {
            onUpdate("", true)
            return
        }

        stop() // ensure clean state

        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onUpdate("", true)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        guard let inputNode = self.inputNode else {
            onUpdate("", true)
            return
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            onUpdate("", true)
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                DispatchQueue.main.async {
                    onUpdate(result.bestTranscription.formattedString, result.isFinal)
                }
                if result.isFinal { self.stop() }
            }
            if error != nil {
                DispatchQueue.main.async { onUpdate("", true) }
                self.stop()
            }
        }

        DispatchQueue.main.async { self.isRecording = true }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            inputNode?.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        do { try audioSession.setActive(false, options: .notifyOthersOnDeactivation) } catch { /* ignore */ }
        DispatchQueue.main.async { self.isRecording = false }
    }
}

// MARK: - Main View
struct ZoraAIView: View {
    @State private var input = ""
    @State private var messages: [ZMessage] = []
    @State private var thinking = false
    @State private var speaking = false
    @State private var suggestions: [String] = [
        "Plan my day",
        "Help me focus for an hour",
        "Suggest events nearby tonight",
        "Optimize my morning routine"
    ]
    @State private var glowPulse = false

    // TTS
    private let synthesizer = AVSpeechSynthesizer()

    // Speech controller
    @StateObject private var speech = SpeechIOController()

    var body: some View {
        ZStack {
            // Background
            AngularGradient(
                gradient: Gradient(colors: [.black, .indigo.opacity(0.55), .black, .blue.opacity(0.45), .black]),
                center: .center
            )
            .ignoresSafeArea()

            // Soft particle glow
            NebulaDots()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                chatPanel
            }

            if thinking {
                // Touch passthrough dim prevents accidental taps while waiting
                Color.black.opacity(0.001).ignoresSafeArea()
            }
        }
        .onAppear {
            if messages.isEmpty { addSystem("Hi, I’m Zora. Ask me anything or tap a suggestion ✨") }
            Task { await speech.requestPermissions() }
        }
        .onDisappear {
            speech.stop()
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 12) {
            ZoraOrb(size: 36)
                .overlay(
                    Circle()
                        .strokeBorder(glowPulse ? Color.cyan.opacity(0.45) : Color.white.opacity(0.12), lineWidth: glowPulse ? 2.0 : 1.0)
                        .blur(radius: glowPulse ? 2 : 0.8)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glowPulse)
                )
                .onAppear { glowPulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text("ZORA")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan.opacity(0.6), radius: 6)
                Text(speaking ? "Speaking…" : (thinking ? "Thinking…" : (speech.isRecording ? "Listening…" : "Online • Ready")))
                    .font(.caption)
                    .foregroundStyle(thinking ? .cyan : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: Chat Panel
    private var chatPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            AngularGradient(gradient: Gradient(colors: [.blue.opacity(0.5), .purple.opacity(0.5), .blue.opacity(0.5)]),
                                            center: .center),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 12)

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { msg in
                                messageBubble(msg)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            if thinking { typingBubble }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
                    }
                }

                // Suggestions
                if !suggestions.isEmpty {
                    suggestionRow
                }

                // Input Row
                inputRow
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(text: s) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text(s)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [.blue.opacity(0.30), .purple.opacity(0.30)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        )
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("Talk to Zora…", text: $input, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(false)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            // Mic button
            Button {
                if speech.isRecording {
                    speech.stop()
                } else {
                    speech.start { text, isFinal in
                        self.input = text
                        if isFinal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.send(text: text)
                        }
                    }
                }
            } label: {
                Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(speech.isRecording ? Color.red : Color.cyan, Color.white.opacity(0.95))
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.vertical, 4)
                    .overlay(
                        Circle()
                            .stroke(speech.isRecording ? Color.red.opacity(0.6) : Color.cyan.opacity(0.4), lineWidth: speech.isRecording ? 3 : 1.5)
                            .blur(radius: speech.isRecording ? 1.2 : 0.8)
                    )
            }
            .buttonStyle(.plain)
            .help(speech.isRecording ? "Stop listening" : "Start voice input")
            .disabled(!(speech.micPermGranted && (speech.authStatus == .authorized || speech.authStatus == .notDetermined || speech.authStatus == nil)))

            Button { send(text: input) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(
                        Circle().fill(
                            LinearGradient(colors: [.cyan.opacity(0.9), .blue.opacity(0.9)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    )
                    .shadow(color: .cyan.opacity(0.4), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Message bubbles

    private func messageBubble(_ msg: ZMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if msg.role == .zora || msg.role == .system { ZoraOrb(size: 18).opacity(0.9) }
            Text(msg.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(msg.role == .user ? Color.white.opacity(0.10) : Color.blue.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .id(msg.id)
            if msg.role == .user { Spacer(minLength: 0) }
        }
    }

    private var typingBubble: some View {
        HStack(spacing: 8) {
            ZoraOrb(size: 18).opacity(0.9)
            TypingDots()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .padding(.leading, 16)
    }

    private func addSystem(_ text: String) {
        messages.append(ZMessage(role: .system, text: AttributedString(text)))
    }

    private func addUser(_ text: String) {
        messages.append(ZMessage(role: .user, text: AttributedString(text)))
    }

    private func addZora(_ text: String) {
        messages.append(ZMessage(role: .zora, text: AttributedString(text)))
        speak(text)
    }

    // MARK: - Send / Networking

    private func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        addUser(trimmed)
        thinking = true
        Task { await talkToZora(trimmed) }
    }

    /// Calls your Cloud Function with intent "zora.ask".
    /// Retries on cannotParseResponse / connection lost; never throws to UI.
    private func talkToZora(_ text: String) async {
        let uid = Auth.auth().currentUser?.uid ?? ""
        guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/aiOrbHandle") else {
            await MainActor.run { addZora("I couldn’t reach the server."); thinking = false }
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "uid": uid,
            "intent": "zora.ask",
            "payload": ["text": text]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        let maxRetries = 2
        var lastError: NSError?
        for attempt in 0...maxRetries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let decoded: ZOR_Resp
                do {
                    decoded = try JSONDecoder().decode(ZOR_Resp.self, from: data)
                } catch {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    await MainActor.run {
                        addZora(raw.isEmpty ? "I’m here, but I couldn’t parse that." : raw)
                        thinking = false
                    }
                    return
                }

                let reply = pickReply(from: decoded)
                await MainActor.run {
                    addZora(reply)
                    thinking = false
                }
                return
            } catch {
                let ns = error as NSError
                lastError = ns
                if ns.domain == NSURLErrorDomain &&
                    (ns.code == NSURLErrorCannotParseResponse || ns.code == NSURLErrorNetworkConnectionLost) &&
                    attempt < maxRetries {
                    let backoff = UInt64(Double.random(in: 0.15...0.45) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: backoff)
                    continue
                } else {
                    break
                }
            }
        }

        await MainActor.run {
            addZora("Network hiccup (\(lastError?.code ?? -1)). Tap a suggestion to try again.")
            thinking = false
        }
    }

    /// Collapse server cards into a friendly reply string
    private func pickReply(from resp: ZOR_Resp) -> String {
        guard resp.ok, let cards = resp.cards, !cards.isEmpty else {
            return resp.error ?? "I’m here."
        }
        var parts: [String] = []
        for c in cards {
            switch c.type {
            case "title", "subtitle":
                if let t = c.text, !t.isEmpty { parts.append(t) }
            case "bullets":
                if let its = c.items, !its.isEmpty {
                    parts.append(its.map { "• \($0)" }.joined(separator: "\n"))
                }
            case "card":
                if let ec = c.card {
                    var s = "• \(ec.title)"
                    if let sub = ec.subtitle { s += " — \(sub)" }
                    parts.append(s)
                }
            case "cta":
                if let lbl = c.label { parts.append("[\(lbl)]") }
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - TTS
    private func speak(_ text: String) {
        // If we’re recording, don’t echo to prevent audio feedback.
        guard !speech.isRecording else { return }
        let ut = AVSpeechUtterance(string: text)
        ut.voice = AVSpeechSynthesisVoice(language: "en-US")
        ut.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        ut.pitchMultiplier = 1.02
        speaking = true
        synthesizer.speak(ut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { speaking = false }
    }
}

// MARK: - Animated bits

private struct ZoraOrb: View {
    let size: CGFloat
    @State private var spin: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color.cyan.opacity(0.35), .black.opacity(0.1)],
                                   center: .center, startRadius: 1, endRadius: size * 0.8)
                )
                .blur(radius: 3)
                .scaleEffect(breathe ? 1.04 : 0.96)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: breathe)

            Circle()
                .fill(.ultraThinMaterial.opacity(0.75))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))

            AngularGradient(
                gradient: Gradient(colors: [
                    .white.opacity(0.00), .white.opacity(0.18), .white.opacity(0.00),
                    .white.opacity(0.12), .white.opacity(0.00)
                ]),
                center: .center,
                angle: .degrees(Double(spin * 360))
            )
            .clipShape(Circle())
            .blur(radius: 1.0)
            .opacity(0.9)
        }
        .frame(width: size, height: size)
        .onAppear {
            breathe = true
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = 1 }
        }
    }
}

private struct TypingDots: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(for: i))
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: phase)
            }
        }
        .onAppear { phase = 1 }
    }
    private func scale(for i: Int) -> CGFloat {
        switch i {
        case 0: return 0.85
        case 1: return 1.0
        default: return 0.85
        }
    }
}

private struct NebulaDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.blendMode = .plusLighter
                for i in 0..<26 {
                    let p = CGPoint(
                        x: (sin(t * 0.08 + Double(i)) * 0.45 + 0.5) * size.width,
                        y: (cos(t * 0.10 + Double(i) * 1.618) * 0.45 + 0.5) * size.height
                    )
                    let r: CGFloat = (i % 5 == 0) ? 30 : 18
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r*2, height: r*2)),
                        with: .radialGradient(
                            Gradient(colors: [Color.cyan.opacity(0.16), .clear]),
                            center: p, startRadius: 0, endRadius: r
                        )
                    )
                }
            }
        }
    }
}
