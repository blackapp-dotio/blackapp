import SwiftUI


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
}


    // User Profile for Chats
struct ChatUserProfile: Identifiable, Codable {
    let id: String
    let name: String
    let username: String
    var profileImageURL: String? // ✅ Add this
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

