import Foundation
import FirebaseDatabase

struct Brand: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let logoURL: String?
    let userId: String
    let approved: Bool
    let timestamp: TimeInterval

    static func from(snapshot: DataSnapshot) -> Brand? {
        guard let dict = snapshot.value as? [String: Any],
              let name = dict["name"] as? String,
              let description = dict["description"] as? String,
              let userId = dict["userId"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }

        let logoURL = dict["logoURL"] as? String
        let approved = dict["approved"] as? Bool ?? false

        return Brand(
            id: snapshot.key,
            name: name,
            description: description,
            logoURL: logoURL,
            userId: userId,
            approved: approved,
            timestamp: timestamp
        )
    }
}
