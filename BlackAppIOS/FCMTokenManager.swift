import Firebase
import FirebaseMessaging
import FirebaseAuth

struct FCMTokenManager {
    static func syncFCMTokenToFirestore(forceToken: String? = nil, retryCount: Int = 0) {
        guard let user = Auth.auth().currentUser else {
            print("❌ No authenticated user for FCM token sync.")
            return
        }

        let maxRetries = 3

        let tokenHandler: (String?) -> Void = { token in
            guard let token = token else {
                print("⚠️ FCM token is nil (attempt \(retryCount + 1)/\(maxRetries)). Retrying...")
                if retryCount < maxRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        syncFCMTokenToFirestore(retryCount: retryCount + 1)
                    }
                } else {
                    print("❌ Max retry limit reached. FCM token sync failed.")
                }
                return
            }

            print("📡 Saving FCM token: \(token)")

            Firestore.firestore().collection("users").document(user.uid).setData([
                "fcmToken": token,
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true) { error in
                if let error = error {
                    print("❌ Failed to save FCM token: \(error.localizedDescription)")
                } else {
                    print("✅ FCM token successfully saved for user: \(user.uid)")
                }
            }
        }

        if let providedToken = forceToken {
            tokenHandler(providedToken)
        } else {
            Messaging.messaging().token { token, error in
                if let error = error {
                    print("❌ Error retrieving FCM token: \(error.localizedDescription)")
                    return
                }
                tokenHandler(token)
            }
        }
    }
}
