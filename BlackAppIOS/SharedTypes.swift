import Foundation
import FirebaseDatabase


struct RSSArticle: Identifiable, Codable {
    let id = UUID()
    let title: String
    let link: String
    let description: String
    let pubDate: Date
    let imageURL: URL? // ← Make this optional
    let videoURL: URL? // ✅ Add this line
}



extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/*extension String {
    func strippedHTML() -> String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        return attributedString?.string ?? self
    }
}*/

// SharedTypes.swift
import Foundation

struct PurchaseModel: Identifiable {
    var id: String
    var userId: String
    var eventId: String
    var eventTitle: String
    var eventImagePath: String
    var quantity: Int
    var type: String  // "ticket" or "table"
    var totalAmount: Double
    var timestamp: TimeInterval

    static func from(snapshot: DataSnapshot) -> PurchaseModel? {
        guard let value = snapshot.value as? [String: Any],
              let userId = value["userId"] as? String,
              let eventId = value["eventId"] as? String,
              let eventTitle = value["eventTitle"] as? String,
              let eventImagePath = value["eventImagePath"] as? String,
              let quantity = value["quantity"] as? Int,
              let type = value["type"] as? String,
              let totalAmount = value["totalAmount"] as? Double,
              let timestamp = value["timestamp"] as? TimeInterval else {
            return nil
        }

        return PurchaseModel(
            id: snapshot.key,
            userId: userId,
            eventId: eventId,
            eventTitle: eventTitle,
            eventImagePath: eventImagePath,
            quantity: quantity,
            type: type,
            totalAmount: totalAmount,
            timestamp: timestamp
        )
    }
}
import SwiftUI
import UIKit

/// Global, reusable share sheet for the whole app.
/// Use: .sheet(isPresented: $showShare) { ActivityView(activityItems: [...]) }
public struct ActivityView: UIViewControllerRepresentable {
    public let activityItems: [Any]
    public var applicationActivities: [UIActivity]? = nil

    public init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        // Filter out optionals just in case you pass nil URLs etc.
        let items = activityItems.compactMap { $0 }
        return UIActivityViewController(activityItems: items, applicationActivities: applicationActivities)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


import SwiftUI

// Reusable neon gradient + pulse for Nightlife entry points
public struct NightlifeGlowButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.9), Color.blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.purple.opacity(0.6), radius: 18, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// Card-style “mini app” icon for Explore
public struct NightlifeMiniAppIcon: View {
    public init() {}
    @State private var pulse = false

    public var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple, Color.blue],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.purple.opacity(pulse ? 0.7 : 0.25), radius: pulse ? 20 : 6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            pulse.toggle()
                        }
                    }

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }

            Text("Nightlife")
                .font(.headline)
                .foregroundColor(.white)

            Text("Tables • Tickets • Guestlist")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(Color(.secondarySystemBackground).opacity(0.25))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.purple.opacity(0.35), radius: 14, x: 0, y: 8)
    }
}
