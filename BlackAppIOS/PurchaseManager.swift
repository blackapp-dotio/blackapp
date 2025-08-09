import Foundation
import SwiftUI
import Firebase
import FirebaseDatabase

class PurchaseManager {
    static let shared = PurchaseManager()
    private init() {}

    /// Initiates checkout and logs intent for tracking
    func startCheckout(
        buyerId: String,
        sellerId: String,
        basePrice: Double,
        itemType: String,
        itemId: String,
        itemTitle: String,
        itemImageURL: String? = nil
    ) {
        let platformFee = basePrice * 0.02
        let totalWithFee = basePrice + platformFee

        // ✅ Corrected hosted page path
        let baseURL = "https://blackappios.web.app/index.html"
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "userId", value: buyerId),
            URLQueryItem(name: "sellerId", value: sellerId),
            URLQueryItem(name: "itemPrice", value: String(format: "%.2f", basePrice)), // ✅ correct param name
            URLQueryItem(name: "platformFee", value: String(format: "%.2f", platformFee)),
            URLQueryItem(name: "totalWithFee", value: String(format: "%.2f", totalWithFee)),
            URLQueryItem(name: "itemType", value: itemType),
            URLQueryItem(name: "itemId", value: itemId),
            URLQueryItem(name: "itemTitle", value: itemTitle)
        ]

        if let url = components.url {
            UIApplication.shared.open(url)
            logPurchaseIntent(
                buyerId: buyerId,
                itemId: itemId,
                itemTitle: itemTitle,
                itemImageURL: itemImageURL,
                type: itemType,
                amount: totalWithFee
            )
        } else {
            print("❌ Failed to build checkout URL.")
        }
    }

    /// Logs the purchase attempt for analytics & redundancy
    private func logPurchaseIntent(
        buyerId: String,
        itemId: String,
        itemTitle: String,
        itemImageURL: String?,
        type: String,
        amount: Double
    ) {
        let ref = Database.database().reference()
        let path = ref.child("purchaseIntents").child(buyerId).child(itemId)

        let log: [String: Any] = [
            "title": itemTitle,
            "type": type,
            "totalAmount": amount,
            "timestamp": Date().timeIntervalSince1970,
            "imageURL": itemImageURL ?? ""
        ]

        path.setValue(log) { error, _ in
            if let error = error {
                print("❌ Failed to log intent: \(error.localizedDescription)")
            } else {
                print("✅ Purchase intent logged for item \(itemId).")
            }
        }

        // Optionally save locally (for offline UX)
        /*
        UserDefaults.standard.set(itemTitle, forKey: "lastPurchaseTitle")
        UserDefaults.standard.set(amount, forKey: "lastPurchaseAmount")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastPurchaseTime")
        */
    }
}
