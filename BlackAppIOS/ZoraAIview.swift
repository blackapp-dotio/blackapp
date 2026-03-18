//
//  ZoraAIView.swift
//  BlackAppIOS
//
//  Self-contained Jarvis-style Zora panel with safe networking + TTS + voice input
//  Apple-review friendly: explicit AI disclosure, permission-safe mic/speech handling,
//  and server-driven capability/config so Zora can improve without requiring iOS rebuilds.
//
//  NOTE (Info.plist REQUIRED):
//   - NSMicrophoneUsageDescription
//   - NSSpeechRecognitionUsageDescription
//

import SwiftUI
import AVFoundation
import Speech
import FirebaseAuth

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Keyboard helpers
fileprivate extension View {
    /// Dismisses the iOS keyboard from anywhere.
    func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Server models (namespaced to avoid collisions)
private struct ZOR_Resp: Decodable {
    let ok: Bool
    let tookMs: Int?
    let cards: [ZOR_Card]?
    let error: String?
    let config: ZOR_RemoteConfig?
}

private struct ZOR_Card: Decodable, Identifiable {
    let type: String
    let text: String?
    let items: [String]?
    let label: String?
    let action: ZOR_Action?
    let card: ZOR_EventCard?
    let meta: [String: String]?

    var id: String {
        if let t = text, !t.isEmpty { return "\(type):\(t)" }
        if let l = label, !l.isEmpty { return "\(type):\(l)" }
        if let m = meta?["id"], !m.isEmpty { return "\(type):\(m)" }
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

private struct ZOR_RemoteConfig: Decodable {
    let suggestions: [String]?
    let aiDisclosure: String?
    let allowTTS: Bool?
    let allowVoice: Bool?
    let maxInputChars: Int?
    let schemaVersion: Int?
}

// MARK: - Local chat models (namespaced)
private enum ZRole { case user, zora, system }

private struct ZMessage: Identifiable {
    let id = UUID()
    let role: ZRole
    let text: AttributedString
    let timestamp: Date = Date()
}

// MARK: - TTS controller (delegate-based speaking state; no timers)
final class ZoraTTSController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking: Bool = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ut = AVSpeechUtterance(string: trimmed)
        ut.voice = AVSpeechSynthesisVoice(language: "en-US")
        ut.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        ut.pitchMultiplier = 1.02
        synthesizer.speak(ut)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }
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

    func canRecord() -> Bool {
        guard micPermGranted else { return false }
        if let status = authStatus, (status == .denied || status == .restricted) { return false }
        return true
    }

    /// Start speech recognition. `onUpdate(text, isFinal)` is called on the main thread.
    func start(onUpdate: @escaping (_ text: String, _ isFinal: Bool) -> Void) {
        guard canRecord() else {
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

// MARK: - Server-backed service (server-driven config so capabilities can evolve without iOS rebuild)
final class ZoraService: ObservableObject {

    private let functionURL = URL(string: "https://us-central1-blackappios.cloudfunctions.net/aiOrbHandle")!

    // Server-driven settings (safe defaults)
    @Published var suggestions: [String] = [
        "Plan my day",
        "Help me focus for an hour",
        "Suggest events nearby tonight",
        "Optimize my morning routine"
    ]
    @Published var aiDisclosure: String =
        "Zora is an AI assistant. Responses may be inaccurate. Do not rely on it for medical, legal, or financial advice."
    @Published var allowTTS: Bool = true
    @Published var allowVoice: Bool = true
    @Published var maxInputChars: Int = 900
    @Published var schemaVersion: Int = 1

    private var inFlightTask: Task<Void, Never>?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 25
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    func cancelInFlight() {
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    func bootstrapIfNeeded(uid: String) async {
        do {
            let resp = try await call(intent: "zora.bootstrap", uid: uid, payload: [:])
            if let cfg = resp.config {
                await MainActor.run { self.applyRemoteConfig(cfg) }
            }
        } catch {
            // Keep defaults if bootstrap fails
        }
    }

    /// Ask Zora. Returns decoded response or throws.
    fileprivate func ask(text: String, uid: String) async throws -> ZOR_Resp {
        return try await call(intent: "zora.ask", uid: uid, payload: ["text": text])
    }

    private func call(intent: String, uid: String, payload: [String: String]) async throws -> ZOR_Resp {
        var req = URLRequest(url: functionURL)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BlackAppIOS/ZoraAI", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "uid": uid,
            "intent": intent,
            "schemaVersion": schemaVersion,
            "payload": payload
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        do {
            return try JSONDecoder().decode(ZOR_Resp.self, from: data)
        } catch {
            let raw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                return ZOR_Resp(
                    ok: true,
                    tookMs: nil,
                    cards: [ZOR_Card(type: "title", text: raw, items: nil, label: nil, action: nil, card: nil, meta: nil)],
                    error: nil,
                    config: nil
                )
            }
            throw error
        }
    }

    private func applyRemoteConfig(_ cfg: ZOR_RemoteConfig) {
        if let s = cfg.suggestions, !s.isEmpty { self.suggestions = s }
        if let d = cfg.aiDisclosure, !d.isEmpty { self.aiDisclosure = d }
        if let t = cfg.allowTTS { self.allowTTS = t }
        if let v = cfg.allowVoice { self.allowVoice = v }
        if let m = cfg.maxInputChars, m >= 200 { self.maxInputChars = min(m, 4000) }
        if let sv = cfg.schemaVersion, sv >= 1 { self.schemaVersion = sv }
    }
}

// MARK: - Main View
struct ZoraAIView: View {
    @State private var input = ""
    @State private var messages: [ZMessage] = []
    @State private var thinking = false
    @State private var glowPulse = false

    // Keyboard visibility tracking
    @State private var keyboardVisible: Bool = false

    // Controllers
    @StateObject private var speech = SpeechIOController()
    @StateObject private var tts = ZoraTTSController()
    @StateObject private var service = ZoraService()

    // Apple-friendly: explicit AI disclosure UI
    @State private var showAbout = false
    @State private var showMicHelp = false

    // Rate-limit / safety
    @State private var lastSentAt: Date = .distantPast
    private let minSendInterval: TimeInterval = 0.75

    @Environment(\.openURL) private var openURL

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
                disclosureBar
                chatPanel
            }

            if thinking {
                // Touch passthrough dim prevents accidental taps while waiting
                Color.black.opacity(0.001).ignoresSafeArea()
            }
        }
        .onAppear {
            if messages.isEmpty {
                addSystem("Hi, I’m Zora. Ask me anything or tap a suggestion.")
            }
            Task {
                await speech.requestPermissions()
                let uid = Auth.auth().currentUser?.uid ?? ""
                await service.bootstrapIfNeeded(uid: uid)
            }
        }
        .onDisappear {
            speech.stop()
            tts.stop()
            service.cancelInFlight()
        }
        // Keyboard show/hide tracking
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .sheet(isPresented: $showAbout) {
            ZoraAboutView(text: service.aiDisclosure)
        }
        .alert("Voice permissions needed", isPresented: $showMicHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable Microphone and Speech Recognition permissions in Settings to use voice input.")
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 12) {
            ZoraOrb(size: 36)
                .overlay(
                    Circle()
                        .strokeBorder(glowPulse ? Color.cyan.opacity(0.45) : Color.white.opacity(0.12),
                                      lineWidth: glowPulse ? 2.0 : 1.0)
                        .blur(radius: glowPulse ? 2 : 0.8)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glowPulse)
                )
                .onAppear { glowPulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text("ZORA")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan.opacity(0.6), radius: 6)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(thinking ? .cyan : .secondary)
            }

            Spacer()

            Button {
                dismissKeyboard()
                showAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Zora")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var statusText: String {
        if tts.speaking { return "Speaking…" }
        if thinking { return "Thinking…" }
        if speech.isRecording { return "Listening…" }
        return "Online • Ready"
    }

    // MARK: Disclosure bar
    private var disclosureBar: some View {
        Button {
            dismissKeyboard()
            showAbout = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("AI Assistant • Tap for details")
                    .font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.10)), alignment: .bottom)
        }
        .buttonStyle(.plain)
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
                    // Drag/scroll dismisses keyboard (native behavior)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
                    }
                }

                if !service.suggestions.isEmpty {
                    suggestionRow
                }

                inputRow
            }
            // Tap anywhere in panel dismisses keyboard
            .contentShape(Rectangle())
            .onTapGesture {
                dismissKeyboard()
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(service.suggestions, id: \.self) { s in
                    Button {
                        dismissKeyboard()
                        send(text: s)
                    } label: {
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
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
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
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .onChange(of: input) { newValue in
                    if newValue.count > service.maxInputChars {
                        input = String(newValue.prefix(service.maxInputChars))
                    }
                }

            // Keyboard dismiss button (shows only when keyboard is visible)
            if keyboardVisible {
                Button {
                    dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(10)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Dismiss keyboard")
                .disabled(thinking)
            }

            // Mic button
            if service.allowVoice {
                Button {
                    if !speech.canRecord() {
                        showMicHelp = true
                        return
                    }
                    dismissKeyboard()
                    if speech.isRecording {
                        speech.stop()
                    } else {
                        tts.stop()
                        speech.start { text, isFinal in
                            self.input = text
                            if isFinal {
                                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    self.send(text: trimmed)
                                }
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
                                .stroke(speech.isRecording ? Color.red.opacity(0.6) : Color.cyan.opacity(0.4),
                                        lineWidth: speech.isRecording ? 3 : 1.5)
                                .blur(radius: speech.isRecording ? 1.2 : 0.8)
                        )
                }
                .buttonStyle(.plain)
                .help(speech.isRecording ? "Stop listening" : "Start voice input")
                .disabled(thinking)
            }

            Button {
                dismissKeyboard()
                send(text: input)
            } label: {
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
            .disabled(thinking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Message bubbles

    private func messageBubble(_ msg: ZMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if msg.role == .zora || msg.role == .system {
                ZoraOrb(size: 18).opacity(0.9)
            }

            Text(msg.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(msg.role == .user ? Color.white.opacity(0.10) : Color.blue.opacity(0.18))
                )
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
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
        if service.allowTTS && !speech.isRecording {
            tts.speak(text)
        }
    }

    // MARK: - Send / Networking

    private func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // throttle
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= minSendInterval else { return }
        lastSentAt = now

        // Stop voice capture if sending
        if speech.isRecording { speech.stop() }

        // Cap input
        let capped = trimmed.count > service.maxInputChars ? String(trimmed.prefix(service.maxInputChars)) : trimmed

        input = ""
        addUser(capped)
        thinking = true

        service.cancelInFlight()

        Task { await talkToZora(capped) }
    }

    private func talkToZora(_ text: String) async {
        let uid = Auth.auth().currentUser?.uid ?? ""
        let safeUid = uid

        let maxRetries = 2
        var lastError: NSError?

        for attempt in 0...maxRetries {
            if Task.isCancelled { break }

            do {
                let decoded = try await service.ask(text: text, uid: safeUid)

                if let cfg = decoded.config {
                    await MainActor.run {
                        if let s = cfg.suggestions, !s.isEmpty { service.suggestions = s }
                        if let d = cfg.aiDisclosure, !d.isEmpty { service.aiDisclosure = d }
                        if let t = cfg.allowTTS { service.allowTTS = t }
                        if let v = cfg.allowVoice { service.allowVoice = v }
                        if let m = cfg.maxInputChars, m >= 200 { service.maxInputChars = min(m, 4000) }
                        if let sv = cfg.schemaVersion, sv >= 1 { service.schemaVersion = sv }
                    }
                }

                let picked = pickReply(from: decoded)

                await MainActor.run {
                    addZora(picked.text)
                    if let action = picked.firstAction {
                        handleAction(action)
                    }
                    thinking = false
                }
                return
            } catch {
                let ns = error as NSError
                lastError = ns

                if ns.domain == NSURLErrorDomain &&
                    (ns.code == NSURLErrorCannotParseResponse || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorTimedOut) &&
                    attempt < maxRetries {
                    let backoff = UInt64(Double.random(in: 0.2...0.6) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: backoff)
                    continue
                } else {
                    break
                }
            }
        }

        await MainActor.run {
            addZora("I hit a network issue (\(lastError?.code ?? -1)). Please try again.")
            thinking = false
        }
    }

    // MARK: - Reply extraction

    fileprivate struct PickedReply {
        let text: String
        let firstAction: ZOR_Action?
    }

    fileprivate func pickReply(from resp: ZOR_Resp) -> PickedReply {
        guard resp.ok, let cards = resp.cards, !cards.isEmpty else {
            return PickedReply(text: resp.error ?? "I’m here.", firstAction: nil)
        }

        var parts: [String] = []
        var firstAction: ZOR_Action?

        for c in cards {
            if firstAction == nil, let a = c.action { firstAction = a }

            switch c.type {
            case "title", "subtitle", "text":
                if let t = c.text, !t.isEmpty { parts.append(t) }

            case "bullets", "list":
                if let its = c.items, !its.isEmpty {
                    parts.append(its.map { "• \($0)" }.joined(separator: "\n"))
                }

            case "card":
                if let ec = c.card {
                    var s = "• \(ec.title)"
                    if let sub = ec.subtitle, !sub.isEmpty { s += " — \(sub)" }
                    parts.append(s)
                }

            case "cta":
                if let lbl = c.label, !lbl.isEmpty { parts.append(lbl) }

            default:
                if let t = c.text, !t.isEmpty { parts.append(t) }
                else if let m = c.meta?["text"], !m.isEmpty { parts.append(m) }
            }
        }

        let combined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return PickedReply(text: combined.isEmpty ? "Done." : combined, firstAction: firstAction)
    }

    // MARK: - Safe action handling

    private func handleAction(_ action: ZOR_Action) {
        switch action.type {
        case "open_url":
            guard let raw = action.url, let url = URL(string: raw) else { return }
            guard isAllowedURL(url) else { return }
            openURL(url)

        case "open_event":
            if let id = action.id, let url = URL(string: "blackappios://event/\(id)") {
                openURL(url)
            }

        default:
            return
        }
    }

    private func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        let allowedHosts: Set<String> = [
            "blackapp.io",
            "www.blackapp.io",
            "blackappios.web.app",
            "blackappios.firebaseapp.com"
        ]
        return allowedHosts.contains(host)
    }
}

// MARK: - About sheet
private struct ZoraAboutView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("About Zora")
                        .font(.title2.weight(.heavy))

                    Text(text)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Divider().opacity(0.6)

                    Text("Privacy")
                        .font(.headline)
                    Text("Zora sends your typed or transcribed text to the BlackApp server to generate a response. Audio is not uploaded by this view. Avoid sharing sensitive information.")
                        .foregroundStyle(.secondary)

                    Divider().opacity(0.6)

                    Text("Safety")
                        .font(.headline)
                    Text("Zora may be inaccurate. Do not rely on responses for medical, legal, or financial decisions.")
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("Zora AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
            ForEach(0..<3) { _ in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == 0 ? 0.85 : 1.0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = 1
            }
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
