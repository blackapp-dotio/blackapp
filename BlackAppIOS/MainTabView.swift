import SwiftUI
import Firebase
import FirebaseMessaging
import FirebaseAuth

struct MainTabView: View {
    var body: some View {
        TabView {
            GossipTabView()
                .tabItem {
                    Label("Gossip", systemImage: "quote.bubble")
                }

            EventTabView()
                .tabItem {
                    Label("Events", systemImage: "calendar")
                }

            ExploreTabView()
                .tabItem {
                    Image(systemName: "globe")
                    Text("Explore")
                }

            ChatTabView()
                .tabItem {
                    Label("Chat", systemImage: "message")
                }

            ProfileTabView()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("Profile")
                }
        }
        .accentColor(.blue)
        .onAppear {
            syncPushNotificationToken()
        }
    }
}

// MARK: - Push Notification Token Sync

func syncPushNotificationToken() {
    print("🟡 syncPushNotificationToken() triggered")

    guard let userId = Auth.auth().currentUser?.uid else {
        print("❌ No authenticated user found")
        return
    }

    Messaging.messaging().token { token, error in
        if let error = error {
            print("❌ Failed to retrieve FCM token: \(error.localizedDescription)")
            return
        }

        guard let token = token else {
            print("❌ Retrieved FCM token is nil")
            return
        }

        print("📡 FCM token fetched: \(token)")

        let ref = Firestore.firestore().collection("users").document(userId)
        ref.setData(["fcmToken": token], merge: true) { error in
            if let error = error {
                print("❌ Error saving FCM token to Firestore: \(error.localizedDescription)")
            } else {
                print("✅ FCM token successfully saved to Firestore")
            }
        }
    }
}
