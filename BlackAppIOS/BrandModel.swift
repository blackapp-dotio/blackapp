struct BrandModel: Identifiable {
    var id: String
    var name: String
    var ownerId: String
    var logoURL: String?
    var approved: Bool
    var description: String?// ✅ NEW
    var suspended: Bool // ✅ Add this line
    
    static func from(dict: [String: Any], id: String) -> BrandModel? {
        guard let name = dict["name"] as? String,
              let ownerId = dict["ownerId"] as? String else {
            return nil
        }

        let logoURL = dict["logoURL"] as? String
        let approved = dict["approved"] as? Bool ?? false
        let description = dict["description"] as? String  // ✅ NEW
        let suspended = dict["suspended"] as? Bool ?? false // ✅ Safely unwrap

        return BrandModel(
            id: id,
            name: name,
            ownerId: ownerId,
            logoURL: logoURL,
            approved: approved,
            description: description,  // ✅ NEW
            suspended: suspended        )
    }
}
