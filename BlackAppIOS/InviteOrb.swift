import SwiftUI
import Foundation
import FirebaseAuth
import FirebaseFirestore
import UIKit

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
    // Prefer the provided userId, else Auth user
    let targetUid = userId ?? Auth.auth().currentUser?.uid
    guard let uid = targetUid, !uid.isEmpty else {
        completion("BA-\(UUID().uuidString.prefix(7).uppercased())") // fallback (won't resolve, but share won’t break)
        return
    }
    Firestore.firestore().collection("users").document(uid).getDocument { doc, _ in
        let code = (doc?.data()?["inviteCode"] as? String) ?? uid // fallback to uid if code not present yet
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
            if let items { // when ready, present the native share UI
                SystemShareSheet(items: items)
            } else {
                // quick lightweight loader while fetching the code
                ZStack {
                    Color.black.opacity(0.001) // keep sheet dimming consistent
                    ProgressView("Preparing invite…")
                        .padding()
                }
                .onAppear(perform: prepare)
            }
        }
    }

    private func prepare() {
        let next = _InviteOrbBadge.nextTarget(after: circleSize ?? 0)
        fetchInviteCode(for: userId) { code in
            let text = InviteLinkBuilder.shareText(inviteCode: code, circleSize: circleSize, nextTarget: next)
            // Put the text *once*; iOS auto-linkifies URLs inside the message
            self.items = [text]
            // TIP: you could also pre-copy the code for convenience:
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

// MARK: - Local badge helper (scoped to this file to avoid conflicts)
fileprivate enum _InviteOrbBadge {
    // 0 = white (new user), then 5/10/20/40/80/160/320/640...
    static let thresholds: [Int] = [0, 5, 10, 20, 40, 80, 160, 320, 640]
    static func nextTarget(after size: Int) -> Int? {
        thresholds.first(where: { $0 > size })
    }
}

// MARK: - Liquid, Siri-style animated orb with Blue ↔ Violet color morph
struct FuturisticInviteOrb: View {
    var size: CGFloat = 62
    var action: () -> Void

    // Animation state
    @State private var breathe = false
    @State private var shimmer = false
    @State private var t: CGFloat = 0          // time phase for liquid wobble
    @State private var phase: CGFloat = 0.0    // 0→1 color cycle (blue↔violet↔blue)
    @GestureState private var hover: CGPoint = .zero

    var body: some View {
        let radius = size / 2
        let tiltX = (hover.x - radius) / radius
        let tiltY = (hover.y - radius) / radius

        let core = interpolatedColor(phase: phase)                // main color
        let rim  = interpolatedColor(phase: phase * 0.9 + 0.05)   // slightly shifted for depth
        let aura = interpolatedColor(phase: phase * 1.1 + 0.1).opacity(0.30)

        Button(action: action) {
            ZStack {
                // Backdrop defocus halo (breathing)
                Circle()
                    .fill(aura)
                    .blur(radius: 18)
                    .scaleEffect(breathe ? 1.03 : 0.985)
                    .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: breathe)

                // === LIQUID CORE (morphing) — color-cycling Blue ↔ Violet
                LiquidBlob(t: t, wobble: 0.032)
                    .fill(
                        RadialGradient(
                            colors: [
                                core.opacity(0.95),                       // bright core
                                core.mix(with: .black, amount: 0.55)      // deepen towards edge
                                    .opacity(0.92),
                                Color.black.opacity(0.70)                 // vignette
                            ],
                            center: .init(x: 0.46 + tiltX * 0.10, y: 0.42 + tiltY * 0.06),
                            startRadius: size * 0.08,
                            endRadius: size * 0.88
                        )
                    )

                // Subsurface/inner glow
                LiquidBlob(t: t * 0.65 + 4.0, wobble: 0.16)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.08), .clear],
                            center: .init(x: 0.42 - tiltX * 0.10, y: 0.35 - tiltY * 0.10),
                            startRadius: size * 0.05,
                            endRadius: size * 0.58
                        )
                    )
                    .blendMode(.screen)

                // Caustic swirl (conic shimmer)
                Canvas { ctx, size in
                    let g = Gradient(colors: [
                        .white.opacity(0.00),
                        .white.opacity(0.05),
                        .white.opacity(0.00),
                        .white.opacity(0.10),
                        .white.opacity(0.00)
                    ])
                    let rect = CGRect(origin: .zero, size: size)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let path = Path(ellipseIn: rect)
                    ctx.fill(path, with: .conicGradient(g, center: center, angle: .degrees(shimmer ? 360 : 0)))
                }
                .clipShape(LiquidBlob(t: t * 0.55 + 2.0, wobble: 0.012))
                .opacity(0.85)
                .animation(.linear(duration: 6.0).repeatForever(autoreverses: false), value: shimmer)

                // Rim light (defined edges, tinted with rim color)
                LiquidBlob(t: t * 0.50, wobble: 0.010)
                    .stroke(
                        AngularGradient(
                            colors: [
                                rim.opacity(0.22),
                                .white.opacity(0.08),
                                rim.opacity(0.22),
                                .white.opacity(0.08)
                            ],
                            center: .center
                        ),
                        lineWidth: 1.2
                    )
                    .blur(radius: 0.35)

                // Specular highlight (floats with tilt)
                LiquidBlob(t: t * 0.45 + 1.7, wobble: 0.014)
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.50), .white.opacity(0.12), .clear],
                            center: .init(x: 0.30 - tiltX * 0.14, y: 0.26 - tiltY * 0.14),
                            startRadius: size * 0.02,
                            endRadius: size * 0.28
                        )
                    )
                    .blendMode(.screen)

                // Bottom refraction ring (tinted)
                LiquidBlob(t: t * 0.40 + 0.9, wobble: 0.008)
                    .stroke(
                        RadialGradient(
                            colors: [core.opacity(0.45), .clear],
                            center: .center,
                            startRadius: size * 0.52,
                            endRadius: size * 0.8
                        ),
                        lineWidth: 1.1
                    )
                    .blur(radius: 1.1)

                // Pulse aura (breathing)
                LiquidBlob(t: t * 0.35 + 5.0, wobble: 0.008)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    .scaleEffect(breathe ? 1.03 : 0.985)
                    .blur(radius: breathe ? 1.2 : 1.8)
                    .animation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true), value: breathe)

                // Center “+” glyph (glassy)
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
                Circle()
                    .fill(.ultraThinMaterial.opacity(0.06))
                    .blur(radius: 6)
            )
            .shadow(color: core.opacity(0.30), radius: 16, x: 0, y: 9)
            .rotation3DEffect(.degrees(Double(tiltY * 7)), axis: (x: 1, y: 0, z: 0))
            .rotation3DEffect(.degrees(Double(-tiltX * 7)), axis: (x: 0, y: 1, z: 0))
            .offset(x: sin(t * 0.10) * 0.8, y: cos(t * 0.09) * 0.8) // gentle orbital drift
            // track hover WITHOUT stealing the button tap
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
                // liquid morph (shape)
                withAnimation(.linear(duration: 28).repeatForever(autoreverses: false)) {
                    t = 60
                }
                // color cycle blue↔violet↔blue (loop)
                withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
        }
        .accessibilityLabel("Invite friends")
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    // COLOR INTERPOLATION — Blue ↔ Violet ↔ Blue loop
    private func interpolatedColor(phase: CGFloat) -> Color {
        let t = (sin(phase * .pi * 2) + 1) / 2 // 0…1
        let blue   = SIMD3<Double>(0.20, 0.45, 1.00)
        let violet = SIMD3<Double>(0.55, 0.20, 0.85)
        let mix = blue * (1 - t) + violet * t
        return Color(red: mix.x, green: mix.y, blue: mix.z)
    }
}

// MARK: - LiquidBlob Shape (slow time multipliers = calmer motion)
fileprivate struct LiquidBlob: Shape {
    var t: CGFloat        // time phase (animatable)
    var wobble: CGFloat   // amplitude of edge perturbation

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let R = min(rect.width, rect.height) * 0.5

        var p = Path()
        let steps = 140
        let twoPi = CGFloat.pi * 2

        let k1: CGFloat = 0.25
        let k2: CGFloat = 0.18
        let k3: CGFloat = 0.12

        for i in 0..<steps {
            let a = (CGFloat(i) / CGFloat(steps)) * twoPi

            let r =
                R
                * (1
                   + wobble * 0.90 * sin(a * 3.0 + t * k1)
                   + wobble * 0.65 * sin(a * 5.0 - t * k2)
                   + wobble * 0.40 * sin(a * 9.0 + t * k3))

            let x = cx + r * cos(a)
            let y = cy + r * sin(a)

            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
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
        let c1 = UIColor(self)
        let c2 = UIColor(other)

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

// MARK: - Floating Invite Orb (uses FuturisticInviteOrb)
public struct InviteOrb: View {
    let userId: String?
    let circleSize: Int?        // pass when available; otherwise nil
    @State private var showShare = false
    @State private var showCoach = true // reappears per app relaunch (in-memory only)

    public init(userId: String?, circleSize: Int?) {
        self.userId = userId
        self.circleSize = circleSize
    }

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
            // Coaching bubble above orb
            if showCoach {
                CoachingBubble(text: nextTargetText) { showCoach = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .padding(.bottom, 120)
                    .padding(.trailing, 18)
            }

            FuturisticInviteOrb(size: 64) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                showShare = true
            }
            .sheet(isPresented: $showShare) {
                // We fetch the invite code and then present the native share sheet
                InviteShareSheet(userId: userId, circleSize: circleSize)
            }
        }
    }
}

// MARK: - Overlay wrapper
public struct InviteOrbOverlay<Content: View>: View {
    let userId: String?
    let circleSize: Int?
    let content: Content

    public init(userId: String?, circleSize: Int? = nil, @ViewBuilder content: () -> Content) {
        self.userId = userId
        self.circleSize = circleSize
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    InviteOrb(userId: userId, circleSize: circleSize)
                        .padding(.trailing, 18)
                        .padding(.bottom, 86)
                        .allowsHitTesting(true)
                }
            }
            .ignoresSafeArea(.keyboard)
        }
    }
}
