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
