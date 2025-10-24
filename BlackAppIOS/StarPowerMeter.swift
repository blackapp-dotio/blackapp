import SwiftUI

// MARK: - Star Power Meter (stars + colors + pulse on current)
public struct StarPowerMeter: View {
    public let current: Int               // your current invite count
    public let levels: [Int]              // ascending thresholds, e.g. [0,5,10,20,...]

    // optional: customize the progress gradient to match your orb
    public var progressGradient: [Color] = [Color.blue, Color.purple]

    @State private var pulse = false

    public init(current: Int, levels: [Int], progressGradient: [Color] = [Color.blue, Color.purple]) {
        self.current = max(0, current)
        self.levels = levels.sorted()
        self.progressGradient = progressGradient
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let maxValue = Swift.max(levels.last ?? current, 1)
            let currentX = positionX(for: current, maxLevel: maxValue, width: width)
            let idxCurrent = currentLevelIndex(current: current, in: levels)

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 8)

                // Progress fill (left → current)
                Capsule()
                    .fill(LinearGradient(colors: progressGradient, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, currentX), height: 8)
                    .animation(.easeInOut(duration: 0.35), value: currentX)

                // Stars at each level threshold
                ForEach(Array(levels.enumerated()), id: \.offset) { i, threshold in
                    let x = positionX(for: threshold, maxLevel: maxValue, width: width)
                    let isCurrent = (i == idxCurrent)
                    let baseColor = starColor(for: i, total: Swift.max(1, levels.count))

                    Image(systemName: "star.fill")
                        .font(.system(size: isCurrent ? 16 : 13, weight: .bold))
                        .foregroundColor(baseColor)
                        .shadow(color: baseColor.opacity(0.55), radius: isCurrent ? 6 : 3, x: 0, y: 0)
                        .scaleEffect(isCurrent && pulse ? 1.15 : 1.0)
                        .animation(isCurrent ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                                   value: pulse)
                        .position(x: clamp(x, min: 0, max: width), y: 6) // vertically center on track
                        .accessibilityLabel("Level \(i + 1) at \(threshold) invites")
                }

                // Optional: a subtle current spark to show in-between progress
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .shadow(color: Color.white.opacity(0.6), radius: 3)
                    .offset(x: clamp(currentX, min: 0, max: width - 6) - 3, y: 0)
                    .opacity(levels.isEmpty ? 0 : 0.9)
            }
            .onAppear { pulse = true }
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }

    // MARK: helpers

    // ✅ Renamed parameter to avoid shadowing the global `max(…)` function
    private func positionX(for value: Int, maxLevel: Int, width: CGFloat) -> CGFloat {
        guard maxLevel > 0 else { return 0 }
        let clampedInt = Swift.min(maxLevel, Swift.max(0, value))
        return CGFloat(clampedInt) / CGFloat(maxLevel) * width
    }

    private func currentLevelIndex(current: Int, in levels: [Int]) -> Int {
        guard !levels.isEmpty else { return -1 }
        var idx = -1
        for (i, t) in levels.enumerated() where current >= t { idx = i }
        return idx
    }

    private func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, min), max)
    }

    // Smoothly sweep from blue → purple across levels (can be customized)
    private func starColor(for index: Int, total: Int) -> Color {
        guard total > 1 else { return progressGradient.first ?? .blue }
        let t = Double(index) / Double(total - 1)
        return mix(progressGradient.first ?? .blue, progressGradient.last ?? .purple, amount: t)
    }

    private func mix(_ a: Color, _ b: Color, amount: Double) -> Color {
        let a = UIColor(a), b = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(max(0, min(1, amount)))
        return Color(red: Double(ar + (br - ar) * f),
                     green: Double(ag + (bg - ag) * f),
                     blue: Double(ab + (bb - ab) * f),
                     opacity: Double(aa + (ba - aa) * f))
    }
}

// MARK: - Compact wrapper that prints the message + the meter
public struct NextTargetNotice: View {
    public let current: Int
    public let levels: [Int]

    public init(current: Int, levels: [Int]) {
        self.current = max(0, current)
        self.levels = levels.sorted()
    }

    public init(circleSize: Int?, levels: [Int]) {
        self.init(current: circleSize ?? 0, levels: levels)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.footnote)
                .foregroundColor(.white)
            StarPowerMeter(current: current, levels: levels)
        }
    }

    private var message: String {
        if let next = levels.first(where: { $0 > current }) {
            let remaining = max(0, next - current)
            return "Expand your circle by \(remaining) invites to rise to the next Star Power level."
        } else {
            return "You’ve reached the top Star Power level. 👑"
        }
    }
}
