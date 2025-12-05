// InviteOrb.swift
import SwiftUI
import Foundation
import FirebaseAuth
import FirebaseFirestore
import UIKit

// MARK: - Notification for captured media
extension Notification.Name {
    static let inviteOrbCapturedMedia = Notification.Name("inviteOrbCapturedMedia")
}

// MARK: - Build the invite text (Smart Link; no invite code shown)
enum InviteLinkBuilder {
    /// Final share text: uses your smart link (routes to App Store or TestFlight).
    static func shareText(inviteCode _: String, circleSize: Int?, nextTarget: Int?) -> String {
        let current = circleSize ?? 0
        var s = "🚀 Join the BlackApp movement ✊🏾✨\nNightlife • Creators • Brands — all in one app.\n"

        if let target = nextTarget, target > current {
            let remaining = max(0, target - current)
            s += "\n⭐️ Expand your circle by \(remaining) invites to reach the next Star Power level (\(target)).\n"
        } else {
            s += "\n👑 You’ve reached the top Star Power level.\n"
        }

        s += "\n📲 Get the app: https://blackapp.io/app\n"
        return s
    }
}

// Derive all Star Power level thresholds using your badge API.
fileprivate func inviteBadgeLevels() -> [Int] {
    var levels: [Int] = []
    var cursor = 0
    var guardCount = 0
    while let next = _InviteOrbBadge.nextTarget(after: cursor), guardCount < 50 {
        guard next > cursor else { break }
        levels.append(next)
        cursor = next
        guardCount += 1
    }
    return levels
}

// MARK: - Fetch the current user's invite code
fileprivate func fetchInviteCode(for userId: String?, completion: @escaping (String) -> Void) {
    let targetUid = userId ?? Auth.auth().currentUser?.uid
    guard let uid = targetUid, !uid.isEmpty else {
        completion("BA-\(UUID().uuidString.prefix(7).uppercased())")
        return
    }
    Firestore.firestore().collection("users").document(uid).getDocument { doc, _ in
        let code = (doc?.data()?["inviteCode"] as? String) ?? uid
        completion(code)
    }
}

// MARK: - System share sheet
struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - A tiny loader that fetches code, then renders the share sheet
private struct InviteShareSheet: View {
    let userId: String?
    let circleSize: Int?

    @State private var items: [Any]? = nil

    var body: some View {
        Group {
            if let items {
                SystemShareSheet(items: items)
            } else {
                ZStack {
                    Color.black.opacity(0.001)
                    ProgressView("Preparing invite…").padding()
                }
                .onAppear(perform: prepare)
            }
        }
    }

    private func prepare() {
        let next = _InviteOrbBadge.nextTarget(after: circleSize ?? 0)
        fetchInviteCode(for: userId) { code in
            let text = InviteLinkBuilder.shareText(inviteCode: code, circleSize: circleSize, nextTarget: next)
            self.items = [text]
            UIPasteboard.general.string = code
        }
    }
}

// MARK: - Dismissible coaching bubble
struct CoachingBubble: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(.white)
                .padding(.top, 2)
            Text(text)
                .font(.footnote)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(radius: 10)
        .padding(.trailing, 10)
    }
}

// MARK: - Local badge helper
fileprivate enum _InviteOrbBadge {
    // 0 = white (new user), then 5/10/20/40/80/160/320/640...
    static let thresholds: [Int] = [0, 5, 10, 20, 40, 80, 160, 320, 640]
    static func nextTarget(after size: Int) -> Int? {
        thresholds.first(where: { $0 > size })
    }
}

// =====================================================
// MARK: - SiriWaveOrb (animated, less translucent, subtle pop)
// =====================================================
struct SiriWaveOrb: View {
    var size: CGFloat = 64
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer breathing aura (stronger)
                BreathingAura(size: size)

                // Soft base glow behind the shell to improve contrast
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.blue.opacity(0.22),
                                Color.purple.opacity(0.18),
                                .clear
                            ],
                            center: .center,
                            startRadius: 1,
                            endRadius: size * 0.9
                        )
                    )
                    .blur(radius: 14)
                    .blendMode(.plusLighter)

                // Glassy shell (less translucent than before)
                Circle()
                    .fill(.ultraThinMaterial.opacity(0.72))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.0)
                            .blur(radius: 0.8)
                            .opacity(0.95)
                    )
                    // Extra neon rim for “alive” look
                    .overlay(
                        Circle()
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        .blue.opacity(0.75),
                                        .purple.opacity(0.75),
                                        .blue.opacity(0.75)
                                    ]),
                                    center: .center
                                ),
                                lineWidth: 1.2
                            )
                            .blur(radius: 1.2)
                            .opacity(0.9)
                    )

                // Fluid ribbons (animated)
                FluidRibbons(size: size, reduceMotion: reduceMotion)

                // Conic sheen (has its own spin state internally)
                ConicSheen(size: size, reduceMotion: reduceMotion)
            }
            .frame(width: size, height: size)
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 8)
            .contentShape(Circle())
            .accessibilityLabel("AI orb")
            // Subtle heartbeat pop so it never feels “static”
            .scaleEffect(pop ? 1.04 : 1.0)
            .onAppear {
                // Drive the heartbeat; respect Reduce Motion by slowing it and lowering amplitude
                let dur = reduceMotion ? 3.0 : 1.8
                withAnimation(.easeInOut(duration: dur).repeatForever(autoreverses: true)) {
                    pop = true
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breathing Aura
fileprivate struct BreathingAura: View {
    var size: CGFloat
    @State private var breathe = false
    
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.22),   // stronger inner light
                        Color.white.opacity(0.10),
                        .clear
                    ],
                    center: .center, startRadius: 1, endRadius: size * 1.10
                )
            )
            .blur(radius: 10)
            .scaleEffect(breathe ? 1.08 : 0.95)
            .opacity(0.95)
            .blendMode(.plusLighter)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

// MARK: - Fluid Ribbons (animated with TimelineView)
fileprivate struct FluidRibbons: View {
    let size: CGFloat
    let reduceMotion: Bool
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, sz in
                let rect = CGRect(origin: .zero, size: sz)
                ctx.addFilter(.blur(radius: 6))
                ctx.blendMode = .plusLighter
                
                // Draw three ribbons with different phases/speeds
                drawRibbon(into: &ctx, in: rect,
                           t: t, speed: 0.9, amp: 1.0, freq: 1.7,
                           colors: [Color.cyan.opacity(0.75), Color.blue.opacity(0.55)],
                           reduceMotion: reduceMotion)
                
                drawRibbon(into: &ctx, in: rect,
                           t: t, speed: 0.7, amp: 0.9, freq: 2.3,
                           colors: [Color.purple.opacity(0.70), Color.mint.opacity(0.50)],
                           reduceMotion: reduceMotion)
                
                drawRibbon(into: &ctx, in: rect,
                           t: t, speed: 1.2, amp: 0.8, freq: 3.2,
                           colors: [Color.pink.opacity(0.75), Color.indigo.opacity(0.55)],
                           reduceMotion: reduceMotion)
            }
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
    }
    
    private func drawRibbon(into ctx: inout GraphicsContext,
                            in rect: CGRect,
                            t: TimeInterval,
                            speed: Double,
                            amp: CGFloat,
                            freq: CGFloat,
                            colors: [Color],
                            reduceMotion: Bool) {
        let w = rect.width, h = rect.height
        let midY = h * 0.5
        
        // Animation drivers
        let time = CGFloat(t) * (reduceMotion ? (0.15 * speed) : speed)
        let phase = time * .pi * 2
        
        // Build a curvy path across the circle
        var path = Path()
        let steps = 90
        let band = h * 0.18 * amp   // use amp to scale band height
        
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * w
            let y = midY
            + sin((x / w) * .pi * 2 * freq + phase) * band
            + sin((x / w) * .pi * 2 * (freq * 0.5) - phase * 0.6) * band * 0.35
            
            let thickness = max(1.5, (1 + sin((x / w) * .pi * 2 + phase * 0.8)) * 3.5)
            if i == 0 { path.move(to: CGPoint(x: x, y: y - thickness)) }
            else { path.addLine(to: CGPoint(x: x, y: y - thickness)) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let x = CGFloat(i) / CGFloat(steps) * w
            let y = midY
            + sin((x / w) * .pi * 2 * freq + phase) * band
            + sin((x / w) * .pi * 2 * (freq * 0.5) - phase * 0.6) * band * 0.35
            
            let thickness = max(1.5, (1 + sin((x / w) * .pi * 2 + phase * 0.8)) * 3.5)
            path.addLine(to: CGPoint(x: x, y: y + thickness))
        }
        path.closeSubpath()
        
        // Gradient fill
        let swiftUIGradient: SwiftUI.Gradient = .init(stops: [
            .init(color: colors[0], location: 0.00),
            .init(color: (colors.last ?? colors[0]), location: 1.00)
        ])

        let offsetX = sin(phase * 0.35) * (w * 0.08)
        let startPt = CGPoint(x: rect.midX - offsetX, y: rect.minY)
        let endPt   = CGPoint(x: rect.midX + offsetX, y: rect.maxY)

        let shading: GraphicsContext.Shading = GraphicsContext.Shading.linearGradient(
            swiftUIGradient,
            startPoint: startPt,
            endPoint: endPt
        )

        // Fill the ribbon with the shading
        ctx.fill(path, with: shading)

        // Soft rim highlight
        ctx.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
    }
}

// MARK: - Conic Sheen (slow rotating)
fileprivate struct ConicSheen: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var spin: CGFloat = 0

    var body: some View {
        Canvas { ctx, sz in
            let rect = CGRect(origin: .zero, size: sz)
            let center = CGPoint(x: sz.width/2, y: sz.height/2)
            let angle = Angle(degrees: Double(spin * 360))

            let g: Gradient = Gradient(stops: [
                .init(color: .white.opacity(0.00), location: 0.00),
                .init(color: .white.opacity(0.08), location: 0.12),
                .init(color: .white.opacity(0.00), location: 0.25),
                .init(color: .white.opacity(0.12), location: 0.60),
                .init(color: .white.opacity(0.00), location: 0.85),
            ])

            let base = Path(ellipseIn: rect)
            ctx.addFilter(.blur(radius: 2))
            ctx.fill(base, with: .conicGradient(g, center: center, angle: angle))
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
        .onAppear {
            // Always animate; if Reduce Motion is on, rotate slower
            let duration = reduceMotion ? 20.0 : 9.0
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                spin = 1.0
            }
        }
        .frame(width: size, height: size)
        .opacity(0.9)
        .blendMode(.screen)
    }
}

// =====================================================
// MARK: - Floating Invite Orb (presents capture + share + AI)
// =====================================================
public struct InviteOrb: View {
    let userId: String?
    let circleSize: Int?

    @State private var showShare = false
    @State private var showCoach = true
    @State private var showCapture = false
    @State private var showMenu = false
    @State private var showZoraPanel = false

    // Smart, time-aware copy (label only; NOT used in the coach bubble)
    private var phase: DayPhase { currentDayPhase() }
    private var captureCTA: String { smartCaptureTitle(for: phase) }

    // Orbit animation (gentle)
    @State private var orbitAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var orbitActive: Bool { !showShare && !showCapture && !showMenu && !showZoraPanel }
    private var orbitRadius: CGFloat { reduceMotion ? 4 : 14 }
    private var orbitPeriod: Double { reduceMotion ? 18 : 12 }

    public init(userId: String?, circleSize: Int?) {
        self.userId = userId
        self.circleSize = circleSize
    }

    // Milestone message ONLY (short + clear)
    private var nextTargetText: String {
        let current = circleSize ?? 0
        if let next = _InviteOrbBadge.nextTarget(after: current) {
            let remaining = max(0, next - current)
            return "Expand your circle by \(remaining) invites to rise to the next Star Power level."
        } else {
            return "You’ve reached the top Star Power level. 👑"
        }
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if showCoach {
                StarPowerCoachCard(circleSize: circleSize) { showCoach = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .padding(.bottom, 120)
                    .padding(.trailing, 18)
            }

            if showMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showMenu = false }
                    }
            }

            let radians = orbitAngle * .pi / 180
            let dx = cos(radians) * orbitRadius
            let dy = sin(radians) * orbitRadius

            VStack(alignment: .trailing, spacing: 10) {
                if showMenu {
                    // Smart Camera
                    MenuPill(icon: "camera.aperture", title: captureCTA) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showMenu = false }
                        showCapture = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))

                    // Share Invite
                    MenuPill(icon: "envelope.open.fill", title: "Share Invite") {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showMenu = false }
                        showShare = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))

                    // AI Assistant (now routes to ZoraAIView via OrbPanel wrapper)
                    MenuPill(icon: "sparkles", title: "AI Assistant") {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showMenu = false }
                        showZoraPanel = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // Siri-like animated orb
                SiriWaveOrb(size: 64) {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showMenu.toggle()
                    }
                }
                .offset(x: dx, y: dy)
            }
            .padding(.trailing, 18)
            .padding(.bottom, 86)
        }
        // Flows
        .sheet(isPresented: $showShare) {
            InviteShareSheet(userId: userId, circleSize: circleSize)
        }
        .fullScreenCover(isPresented: $showCapture) {
            LiveCaptureView().ignoresSafeArea()
        }
        .sheet(isPresented: $showZoraPanel) {
            // Forward-compat wrapper so existing calls compile; shows your Iron-Man style assistant
            OrbPanel(uid: userId, initialIntent: "life_sync.brief", initialPayload: nil)
                .ignoresSafeArea(edges: .bottom)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteOrbCapturedMedia)) { _ in
            showCapture = false
        }
        .onAppear { startOrbitIfNeeded() }
        .onChange(of: orbitActive) { _ in
            if orbitActive { startOrbitIfNeeded() } else { stopOrbit() }
        }
    }

    // Replace previous StarPowerCoachCard with this one (same signature)
    fileprivate struct StarPowerCoachCard: View {
        let circleSize: Int?
        let onClose: () -> Void

        var body: some View {
            // Coach card is intentionally disabled for now to avoid distraction.
            // Keeping the original layout inside `if false` so we can easily
            // restore or repurpose it later without breaking call sites.
            if false {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.white)
                        .padding(.top, 2)

                    // Message + inline star meter
                    StarPowerNextTargetMeter(circleSize: circleSize, levels: inviteBadgeLevels())

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.32),
                                    Color.purple.opacity(0.32)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .background(.ultraThinMaterial.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                        .shadow(color: Color.blue.opacity(0.25), radius: 12, x: 0, y: 8)
                )
                .padding(.trailing, 10)
            } else {
                EmptyView()
            }
        }
    }

    // Orbit control
    private func startOrbitIfNeeded() {
        guard orbitActive else { return }
        orbitAngle = 0
        withAnimation(.linear(duration: orbitPeriod).repeatForever(autoreverses: false)) {
            orbitAngle = 360
        }
    }
    private func stopOrbit() {
        let normalized = orbitAngle.truncatingRemainder(dividingBy: 360)
        withAnimation(.none) { orbitAngle = normalized }
    }
}

// Simple inline “next target” visual (now disabled to avoid distraction)
fileprivate struct StarPowerNextTargetMeter: View {
    let circleSize: Int?
    let levels: [Int]

    var body: some View {
        // Intentionally empty: we’ve disabled the announcement text
        EmptyView()
    }
}


// MARK: - MenuPill (water-drop UI)
fileprivate struct MenuPill: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial.opacity(0.20))
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    )
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.trailing, 2)
            }
            .padding(.vertical, 10)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.30), Color.purple.opacity(0.30)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: Color.blue.opacity(0.25), radius: 10, x: 0, y: 6)
            )
            .scaleEffect(hover ? 1.03 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            #if os(iOS)
            // no-op for iOS
            #else
            hover = isHovering
            #endif
        }
    }
}

// =====================================================
// MARK: - Smart copy helpers (time-aware)
// =====================================================
fileprivate enum DayPhase { case day, night }

fileprivate func currentDayPhase(now: Date = Date(), tz: TimeZone = .current) -> DayPhase {
    var cal = Calendar.current
    cal.timeZone = tz
    let hour = cal.component(.hour, from: now)
    return (hour >= 18 || hour < 6) ? .night : .day
}

fileprivate func smartCaptureTitle(for phase: DayPhase) -> String {
    switch phase {
    case .day:   return "Capture Experiences"
    case .night: return "Capture Nightlife"
    }
}

// =====================================================
// MARK: - Remote Orb (server-driven; types kept for compatibility)
// =====================================================
fileprivate enum OrbAPI {
    static let project = "blackappios"
    static let base = "https://us-central1-\(project).cloudfunctions.net"
    static let configURL = URL(string: "\(base)/aiOrbConfig")!
    static let handleURL = URL(string: "\(base)/aiOrbHandle")!
}

// Cards the server can return (kept so older code compiles; ZoraAIView handles UI)
enum OrbCard: Codable, Identifiable {
    case title(text: String)
    case subtitle(text: String)
    case bullets(items: [String])
    case cta(label: String, action: OrbAction)
    case card(OrbEventCard)

    var id: String {
        switch self {
        case .title(let t): return "title:\(t)"
        case .subtitle(let t): return "subtitle:\(t)"
        case .bullets(let items): return "bullets:\(items.joined(separator: "|"))"
        case .cta(let label, let action): return "cta:\(label):\(action.id)"
        case .card(let c): return "event:\(c.id)"
        }
    }

    enum CodingKeys: String, CodingKey { case type, text, items, label, action, card }
    enum CType: String, Codable { case title, subtitle, bullets, cta, card }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(CType.self, forKey: .type)
        switch t {
        case .title:
            self = .title(text: try c.decode(String.self, forKey: .text))
        case .subtitle:
            self = .subtitle(text: try c.decode(String.self, forKey: .text))
        case .bullets:
            self = .bullets(items: try c.decode([String].self, forKey: .items))
        case .cta:
            self = .cta(label: try c.decode(String.self, forKey: .label),
                        action: try c.decode(OrbAction.self, forKey: .action))
        case .card:
            self = .card(try c.decode(OrbEventCard.self, forKey: .card))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .title(let text):
            try c.encode(CType.title, forKey: .type)
            try c.encode(text, forKey: .text)
        case .subtitle(let text):
            try c.encode(CType.subtitle, forKey: .type)
            try c.encode(text, forKey: .text)
        case .bullets(let items):
            try c.encode(CType.bullets, forKey: .type)
            try c.encode(items, forKey: .items)
        case .cta(let label, let action):
            try c.encode(CType.cta, forKey: .type)
            try c.encode(label, forKey: .label)
            try c.encode(action, forKey: .action)
        case .card(let card):
            try c.encode(CType.card, forKey: .type)
            try c.encode(card, forKey: .card)
        }
    }
}

struct OrbEventCard: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let image: String?
    let chips: [String]?
    let ctas: [OrbCTA]?
}

struct OrbCTA: Codable, Identifiable {
    let label: String
    let action: OrbAction
    var id: String { "\(label):\(action.id)" }
}

enum OrbAction: Codable {
    case openURL(String)
    case openEvent(id: String)
    case intent(name: String, payload: [String: String]?)

    var id: String {
        switch self {
        case .openURL(let u): return "open_url:\(u)"
        case .openEvent(let id): return "open_event:\(id)"
        case .intent(let n, _): return "intent:\(n)"
        }
    }

    enum CodingKeys: String, CodingKey { case type, url, id, name, payload }
    enum AType: String, Codable { case open_url, open_event, intent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(AType.self, forKey: .type)
        switch t {
        case .open_url:
            self = .openURL(try c.decode(String.self, forKey: .url))
        case .open_event:
            self = .openEvent(id: try c.decode(String.self, forKey: .id))
        case .intent:
            self = .intent(name: try c.decode(String.self, forKey: .name),
                           payload: try? c.decode([String:String].self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openURL(let u):
            try c.encode(AType.open_url, forKey: .type)
            try c.encode(u, forKey: .url)
        case .openEvent(let id):
            try c.encode(AType.open_event, forKey: .type)
            try c.encode(id, forKey: .id)
        case .intent(let n, let payload):
            try c.encode(AType.intent, forKey: .type)
            try c.encode(n, forKey: .name)
            if let payload { try c.encode(payload, forKey: .payload) }
        }
    }
}

struct OrbConfigResponse: Codable {
    let ok: Bool
    let version: String?
    let release: Release?
    let userProfile: [String: String]?

    struct Release: Codable {
        let phaseFlags: [String: Bool]?
        let ui: UI?
        struct UI: Codable {
            let theme: String?
            let cards: [String]?
        }
    }
}

struct OrbHandleResponse: Codable {
    let ok: Bool
    let tookMs: Int?
    let cards: [OrbCard]?
    let error: String?
}

fileprivate func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(T.self, from: data)
}

// MARK: - RemoteOrbService (robust: JSON Accept header, retries, safe decode)
struct OrbHandleBody: Codable { let uid: String; let intent: String; let payload: [String:String]? }

final class RemoteOrbService {
    static let shared = RemoteOrbService()
    private init() {}

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.allowsCellularAccess = true
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
        return URLSession(configuration: cfg)
    }()

    private func userIdHeader(_ uid: String?) -> String {
        uid ?? Auth.auth().currentUser?.uid ?? ""
    }

    // Generic runner with small retry on -1017/-1005
    private func run(_ req: URLRequest, retries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastErr: Error?
        while attempt <= retries {
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            } catch {
                lastErr = error
                let nsErr = error as NSError
                // Retry only on parse and connection-lost
                if nsErr.domain == NSURLErrorDomain,
                   (nsErr.code == NSURLErrorCannotParseResponse || nsErr.code == NSURLErrorNetworkConnectionLost),
                   attempt < retries {
                    let backoff = Double.random(in: 0.18...0.45)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? URLError(.cannotParseResponse)
    }

    // GET /aiOrbConfig
    func fetchConfig(uid: String?) async throws -> OrbConfigResponse {
        var req = URLRequest(url: OrbAPI.configURL)
        req.httpMethod = "GET"
        req.addValue(userIdHeader(uid), forHTTPHeaderField: "x-user-id")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        let (data, http) = try await run(req)
        guard http.statusCode == 200 else {
            // return a benign default so UI proceeds
            return OrbConfigResponse(ok: true, version: "shim", release: nil, userProfile: nil)
        }
        do {
            return try decodeJSON(data)
        } catch {
            // If server replied with non-JSON by accident, still succeed
            return OrbConfigResponse(ok: true, version: "shim", release: nil, userProfile: nil)
        }
    }

    // POST /aiOrbHandle — keep this name/signature (your app calls it)
    func runIntent(uid: String?, intent: String, payload: [String:String]? = nil) async throws -> OrbHandleResponse {
        var req = URLRequest(url: OrbAPI.handleURL)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20

        let body = OrbHandleBody(uid: userIdHeader(uid), intent: intent, payload: payload)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await run(req)
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            print("❌ aiOrbHandle \(http.statusCode) intent=\(intent) — \(bodyText)")
            return OrbHandleResponse(ok: false, tookMs: nil, cards: nil, error: "Server \(http.statusCode)")
        }
        do {
            let decoded: OrbHandleResponse = try decodeJSON(data)
            print("✅ aiOrbHandle 200 intent=\(intent)")
            return decoded
        } catch {
            // If decode fails, still deliver a friendly fallback card so the panel never breaks
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("❌ aiOrbHandle decode failed (intent=\(intent)). Raw:", raw)
            return OrbHandleResponse(
                ok: true,
                tookMs: nil,
                cards: [
                    .title(text: "Connecting to AI…"),
                    .subtitle(text: "We’re back online now. Tap to continue."),
                    .cta(label: "Retry", action: .intent(name: intent, payload: payload))
                ],
                error: nil
            )
        }
    }
}


// MARK: - OrbPanel wrapper -> presents your Iron-Man style assistant UI (ZoraAIView)
struct OrbPanel: View {
    let uid: String?
    let initialIntent: String
    let initialPayload: [String:String]?

    init(uid: String?, initialIntent: String = "life_sync.brief", initialPayload: [String:String]? = nil) {
        self.uid = uid
        self.initialIntent = initialIntent
        self.initialPayload = initialPayload
    }

    var body: some View {
        // IMPORTANT: ZoraAIView must exist elsewhere in your project.
        // This keeps your existing calls intact and avoids “argument passed to call that takes no arguments”.
        ZoraAIView()
            .ignoresSafeArea(edges: .bottom)
    }
}

// =====================================================
// MARK: - Tiny Color utility for mixing (used earlier)
// =====================================================
fileprivate extension Color {
    func mix(with other: Color, amount: CGFloat) -> Color {
        let a = max(0, min(1, amount))
        let c1 = UIColor(self), c2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1c: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2c: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1c)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2c)
        return Color(
            red: Double(r1 + (r2 - r1) * a),
            green: Double(g1 + (g2 - g1) * a),
            blue: Double(b1 + (b2 - b1) * a),
            opacity: Double(a1c + (a2c - a1c) * a)
        )
    }
}
