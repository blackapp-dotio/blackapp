import SwiftUI
import Foundation


    
    struct ChatMessage: Identifiable {
        var id: String
        var text: String?
        var mediaURL: String?
        var type: String
        var isSender: Bool
        var documentId: String?
        var edited: Bool
        var likes: [String]
        var comments: [[String: String]]
        var reposts: [String]
        var senderName: String
    }
    
    
    // User Profile for Chats
    struct ChatUserProfile: Identifiable, Codable {
        let id: String
        let name: String
        let username: String
        var profileImageURL: String? // ✅ Add this
        var bio: String? = ""
    }
    
    
    
    // Chat Bubble Shape
struct WaterDropShape: Shape {
    var isSender: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 20)
        let tailSize: CGFloat = 10

        if isSender {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - 20))
            path.addLine(to: CGPoint(x: rect.maxX + tailSize, y: rect.maxY - 10))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 20))
            path.addLine(to: CGPoint(x: rect.minX - tailSize, y: rect.maxY - 10))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        return path
    }
}
// MARK: - Support Message Model
struct SupportMessage: Identifiable {
    let id: String
        let userId: String
        let text: String
        let timestamp: TimeInterval
        let name: String
        let email: String
        var status: String? = nil
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

