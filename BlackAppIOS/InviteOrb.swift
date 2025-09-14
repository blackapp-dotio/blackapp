import SwiftUI
import Foundation
import FirebaseAuth
import FirebaseFirestore
import UIKit

// MARK: - Notification for captured media
extension Notification.Name {
    static let inviteOrbCapturedMedia = Notification.Name("inviteOrbCapturedMedia")
}

// MARK: - Build the invite text (TestFlight + Invite Code)
enum InviteLinkBuilder {
    /// Final share text: includes TestFlight steps and the inviter's short code.
    static func shareText(inviteCode: String, circleSize: Int?, nextTarget: Int?) -> String {
        var s = "🚀 Join the BlackApp movement ✊🏾✨\nNightlife • Creators • Brands — all in one app.\n"
        if let n = nextTarget { s += "Help me hit my next invite milestone: \(n)! 💫\n" }
        s += "\n📲 iOS beta install:\n"
        s += "1) Get TestFlight: https://apps.apple.com/app/testflight/id899247664\n"
        s += "2) Join BlackApp Beta: https://testflight.apple.com/join/p5ZFKcen\n"
        s += "\n🔑 Invite code (paste in app or keep copied): \(inviteCode)\n"
        return s
    }
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

// MARK: - Futuristic Invite Orb Button (visual only)
// MARK: - Futuristic Invite Orb Button (visual only)
struct FuturisticInviteOrb: View {
    var size: CGFloat = 62
    var action: () -> Void

    @State private var breathe = false
    @State private var shimmer = false
    @State private var t: CGFloat = 0
    @State private var phase: CGFloat = 0.0
    @GestureState private var hover: CGPoint = .zero

    var body: some View {
        let radius = size / 2
        let tiltX = (hover.x - radius) / radius
        let tiltY = (hover.y - radius) / radius

        let core = interpolatedColor(phase: phase)
        let rim  = interpolatedColor(phase: phase * 0.9 + 0.05)
        let aura = interpolatedColor(phase: phase * 1.1 + 0.1).opacity(0.22) // more translucent

        Button(action: action) {
            ZStack {
                // Soft energy aura
                Circle()
                    .fill(aura)
                    .blur(radius: 22)
                    .scaleEffect(breathe ? 1.035 : 0.975)
                    .animation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true), value: breathe)
                    .blendMode(.plusLighter)

                // Core plasma blob (translucent center)
                LiquidBlob(t: t, wobble: 0.030)
                    .fill(
                        RadialGradient(
                            colors: [
                                core.opacity(0.75),
                                core.mix(with: .black, amount: 0.50).opacity(0.62),
                                Color.black.opacity(0.35)
                            ],
                            center: .init(x: 0.46 + tiltX * 0.10, y: 0.42 + tiltY * 0.06),
                            startRadius: size * 0.06,
                            endRadius: size * 0.90
                        )
                    )
                    .overlay(
                        // inner whisper glow
                        LiquidBlob(t: t * 0.95 + 0.8, wobble: 0.020)
                            .stroke(core.opacity(0.25), lineWidth: 0.8)
                            .blur(radius: 0.6)
                            .blendMode(.screen)
                    )

                // Moving specular sheen (rotates via shimmer + phase)
                Canvas { ctx, size in
                    let g = Gradient(colors: [
                        .white.opacity(0.00),
                        .white.opacity(0.06),
                        .white.opacity(0.00),
                        .white.opacity(0.10),
                        .white.opacity(0.00)
                    ])
                    let rect = CGRect(origin: .zero, size: size)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let path = Path(ellipseIn: rect)
                    // phase drives the conic sweep (continuous revolution)
                    let angle = Angle(degrees: Double(phase * 360))
                    ctx.fill(path, with: .conicGradient(g, center: center, angle: angle))
                }
                .clipShape(LiquidBlob(t: t * 0.55 + 2.0, wobble: 0.012))
                .opacity(0.80)
                .animation(.linear(duration: 6.0).repeatForever(autoreverses: false), value: shimmer)
                .blendMode(.screen)

                // Subtle rim energy
                LiquidBlob(t: t * 0.50, wobble: 0.010)
                    .stroke(
                        AngularGradient(
                            colors: [
                                rim.opacity(0.18),
                                .white.opacity(0.08),
                                rim.opacity(0.18),
                                .white.opacity(0.08)
                            ],
                            center: .center
                        ),
                        lineWidth: 1.1
                    )
                    .blur(radius: 0.35)

                // Highlight flare
                LiquidBlob(t: t * 0.45 + 1.7, wobble: 0.014)
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.10), .clear],
                            center: .init(x: 0.30 - tiltX * 0.14, y: 0.26 - tiltY * 0.14),
                            startRadius: size * 0.02,
                            endRadius: size * 0.30
                        )
                    )
                    .blendMode(.screen)

                // Outer falloff
                LiquidBlob(t: t * 0.40 + 0.9, wobble: 0.008)
                    .stroke(
                        RadialGradient(
                            colors: [core.opacity(0.35), .clear],
                            center: .center,
                            startRadius: size * 0.50,
                            endRadius: size * 0.82
                        ),
                        lineWidth: 1.0
                    )
                    .blur(radius: 1.0)

                // Breathing thin rim
                LiquidBlob(t: t * 0.35 + 5.0, wobble: 0.008)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .scaleEffect(breathe ? 1.035 : 0.975)
                    .blur(radius: breathe ? 1.1 : 1.6)
                    .animation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true), value: breathe)

                // Plus icon
                Image(systemName: "plus")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.95), .white.opacity(0.65)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2.5, x: 0, y: 1.2)
            }
            .frame(width: size, height: size)
            .background(
                // thinner material for translucency
                Circle().fill(.ultraThinMaterial.opacity(0.04)).blur(radius: 6)
            )
            .shadow(color: core.opacity(0.22), radius: 18, x: 0, y: 10)
            // Subtle parallax tilt
            .rotation3DEffect(.degrees(Double(tiltY * 7)), axis: (x: 1, y: 0, z: 0))
            .rotation3DEffect(.degrees(Double(-tiltX * 7)), axis: (x: 0, y: 1, z: 0))
            // Continuous *self* rotation using existing `phase`
            .rotationEffect(.degrees(Double(phase * 360)))
            // Gentle micro-orbit wobble you already had (slightly more visible)
            .offset(x: sin(t * 0.12) * 1.0, y: cos(t * 0.11) * 1.0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($hover) { value, state, _ in
                        let p = value.location
                        state = CGPoint(x: max(0, min(size, p.x)), y: max(0, min(size, p.y)))
                    }
            )
            .onAppear {
                breathe = true
                shimmer = true
                // Smooth, nonstop motion:
                // - t drives blob wobble/orbit
                withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) { t = 60 }
                // - phase drives color flow (blue↔purple) AND self-rotation
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { phase = 1.0 }
            }
        }
        .accessibilityLabel("Invite orb — capture or share")
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    private func interpolatedColor(phase: CGFloat) -> Color {
        let t = (sin(phase * .pi * 2) + 1) / 2 // 0…1
        let blue   = SIMD3<Double>(0.20, 0.45, 1.00)
        let violet = SIMD3<Double>(0.55, 0.20, 0.85)
        let mix = blue * (1 - t) + violet * t
        return Color(red: mix.x, green: mix.y, blue: mix.z)
    }
}


// MARK: - LiquidBlob Shape
fileprivate struct LiquidBlob: Shape {
    var t: CGFloat
    var wobble: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let R = min(rect.width, rect.height) * 0.5
        var p = Path()
        let steps = 140
        let twoPi = CGFloat.pi * 2
        let k1: CGFloat = 0.25, k2: CGFloat = 0.18, k3: CGFloat = 0.12

        for i in 0..<steps {
            let a = (CGFloat(i) / CGFloat(steps)) * twoPi
            let r = R * (1
                         + wobble * 0.90 * sin(a * 3.0 + t * k1)
                         + wobble * 0.65 * sin(a * 5.0 - t * k2)
                         + wobble * 0.40 * sin(a * 9.0 + t * k3))
            let x = cx + r * cos(a)
            let y = cy + r * sin(a)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }
}

// MARK: - Tiny Color utility for mixing
fileprivate extension Color {
    func mix(with other: Color, amount: CGFloat) -> Color {
        let a = max(0, min(1, amount))
        let c1 = UIColor(self), c2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: Double(r1 + (r2 - r1) * a),
            green: Double(g1 + (g2 - g1) * a),
            blue: Double(b1 + (b2 - b1) * a),
            opacity: Double(a1 + (a2 - a1) * a)
        )
    }
}

// MARK: - Smart copy helpers (time-aware)
fileprivate enum DayPhase { case day, night }

fileprivate func currentDayPhase(now: Date = Date(), tz: TimeZone = .current) -> DayPhase {
    // Night = 6pm–5:59am (adjust to taste)
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


// MARK: - Floating Invite Orb (presents capture + share)
public struct InviteOrb: View {
    let userId: String?
    let circleSize: Int?
    
    @State private var showShare = false
    @State private var showCoach = true
    @State private var showCapture = false

    // NEW: inline menu instead of confirmationDialog
    @State private var showMenu = false

    // Smart, time-aware copy (label only; NOT used in the coach bubble)
    private var phase: DayPhase { currentDayPhase() }
    private var captureCTA: String { smartCaptureTitle(for: phase) }

    // Orbit animation (gentle)
    @State private var orbitAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var orbitActive: Bool { !showShare && !showCapture && !showMenu }
    private var orbitRadius: CGFloat { reduceMotion ? 4 : 14 }
    private var orbitPeriod: Double { reduceMotion ? 18 : 12 }

    public init(userId: String?, circleSize: Int?) {
        self.userId = userId
        self.circleSize = circleSize
    }
    
    // Milestone message ONLY (removed time-aware coaching text)
    private var nextTargetText: String {
        let next = _InviteOrbBadge.nextTarget(after: circleSize ?? 0)
        if let n = next {
            return "Just \(n - (circleSize ?? 0)) invites away from reaching \(n)! Expand your circle and rise to the next Star Power level! 🌟🎉"
        } else {
            return "You’ve reached the ultimate popularity level/badge. 👑"
        }
    }
    
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if showCoach {
                CoachingBubble(text: nextTargetText) { showCoach = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .padding(.bottom, 120)
                    .padding(.trailing, 18)
            }

            // Dismiss area when menu is open
            if showMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showMenu = false }
                    }
            }

            // Orbit offset around the anchor
            let radians = orbitAngle * .pi / 180
            let dx = cos(radians) * orbitRadius
            let dy = sin(radians) * orbitRadius

            // Inline expanding menu (stacks upward along right edge)
            VStack(alignment: .trailing, spacing: 10) {
                if showMenu {
                    // Smart Camera button
                    MenuPill(icon: "camera.aperture", title: captureCTA) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showMenu = false }
                        showCapture = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    
                    // Share Invite button
                    MenuPill(icon: "envelope.open.fill", title: "Share Invite") {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showMenu = false }
                        showShare = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // The orb itself (offset with gentle orbit)
                FuturisticInviteOrb(size: 64) {
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
        // Share & Capture flows
        .sheet(isPresented: $showShare) {
            InviteShareSheet(userId: userId, circleSize: circleSize)
        }
        .fullScreenCover(isPresented: $showCapture) {
            LiveCaptureView()
                .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteOrbCapturedMedia)) { _ in
            showCapture = false
        }
        // Motion lifecycle
        .onAppear { startOrbitIfNeeded() }
        .onChange(of: orbitActive) { _ in
            if orbitActive { startOrbitIfNeeded() } else { stopOrbit() }
        }
    }

    // MARK: - Orbit control
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
                            colors: [
                                Color.blue.opacity(0.30),
                                Color.purple.opacity(0.30)
                            ],
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
            // no-op; .onHover not used on iOS, but keep signature for multiplatform
            #else
            hover = isHovering
            #endif
        }
    }
}
