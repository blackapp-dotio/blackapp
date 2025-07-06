import Foundation
import Firebase
import FirebaseMessaging
import FirebaseAuth
import Combine
import SwiftUI

final class TokenSyncMonitor: ObservableObject {
    static let shared = TokenSyncMonitor()

    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { _ in
                print("🔁 App entered foreground. Checking FCM token...")
                self.validateFCMTokenStored()
            }
            .store(in: &cancellables)

        Auth.auth().addStateDidChangeListener { _, user in
            if user != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("👤 User logged in. Triggering delayed FCM sync.")
                    FCMTokenManager.syncFCMTokenToFirestore()
                }
            }
        }
    }

    func validateFCMTokenStored() {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❌ No authenticated user during token validation")
            return
        }

        Firestore.firestore().collection("users").document(userId).getDocument { doc, error in
            if let error = error {
                print("❌ Firestore token check failed: \(error.localizedDescription)")
                return
            }

            let storedToken = doc?.data()?["fcmToken"] as? String
            Messaging.messaging().token { currentToken, error in
                if let error = error {
                    print("❌ Failed to retrieve current FCM token: \(error.localizedDescription)")
                    return
                }

                guard let currentToken = currentToken else {
                    print("⚠️ Current FCM token is nil during validation")
                    return
                }

                if storedToken != currentToken {
                    print("⚠️ Token mismatch or missing. Re-syncing...")
                    FCMTokenManager.syncFCMTokenToFirestore(forceToken: currentToken)
                } else {
                    print("✅ FCM token is consistent")
                }
            }
        }
    }

    func manualTokenCheck() {
        print("🛠 Manual FCM token sync triggered.")
        FCMTokenManager.syncFCMTokenToFirestore()
    }

    func startRecurringCheck(every interval: TimeInterval = 300) {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            print("⏱ Scheduled FCM token consistency check")
            self.validateFCMTokenStored()
        }
    }

    func stopRecurringCheck() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
