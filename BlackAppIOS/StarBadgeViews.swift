// StarBadgeViews.swift (or wherever you keep the star badge)
import SwiftUI

struct StarBadgeInline: View {
    let circleSize: Int
    @State private var pulse = false
    @State private var showAll = false

    var body: some View {
        Button {
            showAll = true
        } label: {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LinearGradient(colors: starFillColors(for: circleSize),
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Image(systemName: "star.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.20))
                        .blendMode(.screen)
                        .offset(x: -0.5, y: -0.8)
                )
                .shadow(color: starGlow(for: circleSize).opacity(0.36), radius: 6, x: 0, y: 1)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
                .accessibilityLabel("Popularity badge")
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .sheet(isPresented: $showAll) {
            BadgeProgressSheet(circleSize: circleSize)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Color logic
    private let tiers: [Int] = [0, 5, 10, 20, 40, 80, 160, 320] // doubles; 0 = white, >max = black

    private func starFillColors(for size: Int) -> [Color] {
        let idx = tierIndex(for: size)
        switch idx {
        case 0:   return [.white, .white.opacity(0.9)]                                   // 0 → white
        case 1:   return [Color.red, Color.orange]                                       // 5
        case 2:   return [Color.orange, Color.yellow]                                    // 10
        case 3:   return [Color.yellow, Color.green]                                     // 20
        case 4:   return [Color.green, Color.blue]                                       // 40
        case 5:   return [Color.blue, Color.indigo]                                      // 80
        case 6:   return [Color.indigo, Color.purple]                                    // 160
        case 7:   return [Color.purple, Color(red: 0.6, green: 0, blue: 0.9)]           // 320+ (violet)
        default:  return [Color.black, Color.black]                                      // ultimate (beyond top tier) = solid black
        }
    }

    private func starGlow(for size: Int) -> Color {
        let idx = tierIndex(for: size)
        switch idx {
        case 0: return .white
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .blue
        case 6: return .indigo
        case 7: return .purple
        default: return .black
        }
    }

    private func tierIndex(for size: Int) -> Int {
        // 0 -> index 0 (white). max in tiers -> last rainbow color; beyond -> black.
        for i in 0..<tiers.count {
            if size < tiers[i] { return max(0, i - 1) }
        }
        // size >= last tier; still show violet for last exact tier, black beyond.
        return size > (tiers.last ?? 320) ? Int.max : tiers.count - 1
    }
}

// Minimal “all badges” sheet
struct BadgeProgressSheet: View {
    let circleSize: Int
    private let thresholds: [Int] = [0, 5, 10, 20, 40, 80, 160, 320, 640] // add 640 as the first “black” suggestion

    var body: some View {
        VStack(spacing: 16) {
            Text("Your Popularity Badges")
                .font(.headline)
                .foregroundColor(.white)
            Text("Richness of your circle: \(circleSize)")
                .foregroundColor(.white.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(thresholds, id: \.self) { t in
                        VStack(spacing: 6) {
                            StarBadgeInline(circleSize: t) // reuse for visual consistency
                                .frame(width: 22, height: 22)
                            Text(t == 0 ? "New" : "\(t)+")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal)
            }

            Text(nextTargetText)
                .font(.subheadline)
                .foregroundColor(.white)
                .padding(.top, 4)

            Spacer(minLength: 6)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var nextTargetText: String {
        if circleSize == 0 { return "Invite your first 5 to earn your red badge." }
        if circleSize >= 640 { return "You’re at the top. Ultimate black badge unlocked." }
        // find next power-of-two target
        let targets = [5, 10, 20, 40, 80, 160, 320, 640]
        if let next = targets.first(where: { $0 > circleSize }) {
            return "Next target: \(next). Invite \(next - circleSize) more."
        }
        return "Keep growing your circle."
    }
}
