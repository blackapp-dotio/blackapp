import SwiftUI
import Firebase
import Combine
import FirebaseMessaging
import FirebaseAuth

struct MainTabView: View {
    @ObservedObject var router = NotificationRouter.shared

    var body: some View {
        ZStack {
            // 🔁 Navigate to chat when a push is tapped
            NavigationLink(
                destination: router.selectedChatUser.map { DirectChatRoomView(recipient: $0) },
                isActive: Binding(
                    get: { router.selectedChatUser != nil },
                    set: { newValue in
                        if !newValue { router.selectedChatUser = nil }
                    }
                )
            ) {
                EmptyView()
            }
            .hidden()

            // 🧭 Tab view
            TabView {
                GossipTabView()
                    .tabItem { Label("Gossip", systemImage: "quote.bubble") }

                EventTabView()
                    .tabItem { Label("Events", systemImage: "calendar") }

                ExploreTabView()
                    .tabItem { Image(systemName: "globe"); Text("Explore") }

                ChatTabView()
                    .tabItem { Label("Chat", systemImage: "message") }

                ProfileTabView()
                    .tabItem { Image(systemName: "person.crop.circle"); Text("Profile") }
            }
            .accentColor(.blue)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("👀 MainTabView appeared. Delayed FCM sync triggered")
                    FCMTokenManager.syncFCMTokenToFirestore()
                    _ = TokenSyncMonitor.shared
                    TokenSyncMonitor.shared.startRecurringCheck(every: 3600)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                print("🔄 App re-entered foreground. Syncing FCM token...")
                syncPushNotificationToken()
                _ = TokenSyncMonitor.shared
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NotificationTapped"))) { notif in
                if let userInfo = notif.userInfo,
                   let senderId = userInfo["senderId"] as? String {
                    print("📬 Notification tapped for senderId: \(senderId)")
                    fetchUserProfile(uid: senderId) { profile in
                        if let profile = profile {
                            router.selectedChatUser = profile
                        } else {
                            print("❌ No user found for senderId \(senderId)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Token Sync

    func syncPushNotificationToken() {
        print("🟡 syncPushNotificationToken() triggered")
        guard let userId = Auth.auth().currentUser?.uid else { return }

        Messaging.messaging().token { token, error in
            if let error = error {
                print("❌ Failed to retrieve FCM token: \(error.localizedDescription)")
                return
            }

            guard let token = token else {
                print("❌ Retrieved FCM token is nil")
                return
            }

            let ref = Firestore.firestore().collection("users").document(userId)
            ref.setData([
                "fcmToken": token,
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true) { error in
                if let error = error {
                    print("❌ Error saving FCM token: \(error.localizedDescription)")
                } else {
                    print("✅ FCM token saved to Firestore")
                }
            }
        }
    }

    // MARK: - Lookup User Profile

    func fetchUserProfile(uid: String, completion: @escaping (ChatUserProfile?) -> Void) {
        let ref = Firestore.firestore().collection("users").document(uid)
        ref.getDocument { doc, err in
            if let data = doc?.data(),
               let name = data["name"] as? String {
                let username = data["username"] as? String ?? ""
                let image = data["profileImageURL"] as? String
                completion(ChatUserProfile(id: uid, name: name, username: username, profileImageURL: image))
            } else {
                completion(nil)
            }
        }
    }
}
