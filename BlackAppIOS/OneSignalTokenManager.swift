import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import OneSignalFramework

class OneSignalTokenManager {
    static let shared = OneSignalTokenManager()
    private init() {}

    private var hasSyncedThisSession = false

    func syncOneSignalUserIdToFirebase() {
        guard let user = Auth.auth().currentUser else {
            print("❌ [OneSignalSync] No authenticated user. Skipping sync.")
            return
        }

        guard let onesignalUserId = OneSignal.User.pushSubscription.id,
              !onesignalUserId.isEmpty else {
            print("⚠️ [OneSignalSync] OneSignal Player ID is not available yet. Will retry later.")
            return
        }

        guard !hasSyncedThisSession else {
            print("🔁 [OneSignalSync] Already synced this session. Skipping duplicate.")
            return
        }

        let uid = user.uid
        let updates = ["onesignalUserId": onesignalUserId]

        print("📦 [OneSignalSync] Starting token sync for user: \(uid)")
        print("🆔 [OneSignalSync] Player ID: \(onesignalUserId)")

        // Update Realtime DB
        Database.database().reference()
            .child("users")
            .child(uid)
            .updateChildValues(updates) { error, _ in
                if let error = error {
                    print("❌ [OneSignalSync] Failed to update Realtime DB: \(error.localizedDescription)")
                } else {
                    print("✅ [OneSignalSync] Token stored in Realtime DB")
                }
            }

        // Update Firestore
        Firestore.firestore()
            .collection("users")
            .document(uid)
            .setData(updates, merge: true) { error in
                if let error = error {
                    print("❌ [OneSignalSync] Failed to update Firestore: \(error.localizedDescription)")
                } else {
                    print("✅ [OneSignalSync] Token stored in Firestore")
                }
            }

        hasSyncedThisSession = true
        print("🎯 [OneSignalSync] Sync complete.")
    }
}
