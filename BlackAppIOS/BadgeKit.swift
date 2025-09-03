import SwiftUI

// MARK: - Popularity tiers (multiples of 2 starting at 5)
// 5,10,20,40,80,160,320, then 640 => BLACK (ultimate)
public enum BadgeTier: Int, CaseIterable, Identifiable {
    case red = 5, orange = 10, yellow = 20, green = 40, blue = 80, indigo = 160, violet = 320, black = 640
    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .violet: return "Violet"
        case .black: return "Black (Ultimate)"
        }
    }

    public var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .indigo: return Color.indigo
        case .violet: return Color.purple
        case .black: return .black
        }
    }

    /// The invite count threshold for this tier.
    public var threshold: Int { rawValue }

    /// Next tier after this one (nil if Black).
    public var next: BadgeTier? {
        switch self {
        case .red: return .orange
        case .orange: return .yellow
        case .yellow: return .green
        case .green: return .blue
        case .blue: return .indigo
        case .indigo: return .violet
        case .violet: return .black
        case .black: return nil
        }
    }

    /// Compute tier from accepted-invite count.
    public static func tier(for circleSize: Int) -> BadgeTier? {
        // return the highest tier whose threshold <= circleSize
        let tiers = Self.allCases.sorted { $0.threshold < $1.threshold }
        return tiers.reversed().first(where: { circleSize >= $0.threshold })
    }

    /// Next target (threshold) given current circle size.
    public static func nextTarget(after circleSize: Int) -> Int? {
        let tiers = Self.allCases.sorted { $0.threshold < $1.threshold }
        return tiers.first(where: { $0.threshold > circleSize })?.threshold
    }
}

public struct BadgeProgress {
    public let tier: BadgeTier?
    public let nextTarget: Int?
    public let remaining: Int?

    public init(circleSize: Int) {
        self.tier = BadgeTier.tier(for: circleSize)
        self.nextTarget = BadgeTier.nextTarget(after: circleSize)
        if let next = nextTarget {
            self.remaining = max(0, next - circleSize)
        } else {
            self.remaining = nil
        }
    }
}
