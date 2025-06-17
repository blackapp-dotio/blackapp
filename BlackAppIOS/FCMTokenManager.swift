import Firebase
import FirebaseMessaging
import FirebaseAuth

struct FCMTokenManager {
    static func syncFCMTokenToFirestore(retryCount: Int = 0) {
        guard let user = Auth.auth().currentUser else {
            print("❌ No authenticated user for FCM token sync.")
            return
        }

        Messaging.messaging().token { token, error in
            if let error = error {
                print("❌ Error retrieving FCM token: \(error.localizedDescription)")
                return
            }

            guard let token = token else {
                print("⚠️ FCM token is nil (attempt \(retryCount)). Retrying...")
                if retryCount < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        syncFCMTokenToFirestore(retryCount: retryCount + 1)
                    }
                }
                return
            }

            print("📡 Retrieved FCM token manually: \(token)")
            Firestore.firestore().collection("users").document(user.uid).setData(["fcmToken": token], merge: true) { error in
                if let error = error {
                    print("❌ Failed to save FCM token: \(error.localizedDescription)")
                } else {
                    print("✅ FCM token saved for user: \(user.uid)")
                }
            }
        }
    }
}
