import Foundation

struct BrandModel: Identifiable {
    let id: String
    let name: String
    let ownerId: String
    let logoURL: String
    let approved: Bool
    let timestamp: TimeInterval
    let description: String

    // Optional: You can add description, category, etc. as needed

    static func from(dict: [String: Any], id: String) -> BrandModel? {
        guard let name = dict["name"] as? String,
              let ownerId = dict["ownerId"] as? String,
              let logoURL = dict["logoURL"] as? String,
              let approved = dict["approved"] as? Bool,
              let timestamp = dict["timestamp"] as? TimeInterval,
              let description = dict["description"] as? String else {
            return nil
        }

        return BrandModel(id: id, name: name, ownerId: ownerId, logoURL: logoURL, approved: approved, timestamp: timestamp, description: description)
    }
}
