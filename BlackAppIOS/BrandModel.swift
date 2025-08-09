import Foundation

struct BrandModel: Identifiable, Codable {
    var id: String
    var name: String
    var description: String?
    var logoURL: String?
    var ownerId: String
    var approved: Bool
    var suspended: Bool
    var configuredTools: [String] = []  // ✅ Field for enabled tools

    static func from(dict: [String: Any], id: String) -> BrandModel? {
        var tools: [String] = []

        if let toolsEnabled = dict["toolsEnabled"] as? [String: Any] {
            for (key, value) in toolsEnabled {
                if let isEnabled = value as? Bool, isEnabled {
                    tools.append(key)
                }
            }
        }

        return BrandModel(
            id: id,
            name: dict["name"] as? String ?? "",
            description: dict["description"] as? String,
            logoURL: dict["logoURL"] as? String,
            ownerId: dict["ownerId"] as? String ?? "",
            approved: dict["approved"] as? Bool ?? false,
            suspended: dict["suspended"] as? Bool ?? false,
            configuredTools: tools
        )
    }

    func toDict() -> [String: Any] {
        let dict: [String: Any] = [
            "name": name,
            "description": description ?? "",
            "logoURL": logoURL ?? "",
            "ownerId": ownerId,
            "approved": approved,
            "suspended": suspended,
            "configuredTools": configuredTools  // ✅ Save tools to Firebase
        ]
        print("📤 Saving BrandModel to Firebase: \(dict)")
        return dict
    }
}
