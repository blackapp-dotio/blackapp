import SwiftUI
import Firebase
import FirebaseAuth
import GoogleSignIn
import GoogleSignInSwift
import OneSignalFramework

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Firebase setup
        FirebaseApp.configure()

        // OneSignal setup (SDK 3.x+)
        OneSignal.initialize("69366bbb-2d87-44b1-921c-3fd2cba8effc", withLaunchOptions: launchOptions)

        OneSignal.Notifications.requestPermission({ accepted in
            print("🔔 OneSignal permission accepted: \(accepted)")
        }, fallbackToSettings: true)

        // ✅ Deep link handler using NotificationCenter
        NotificationCenter.default.addObserver(forName: Notification.Name("ONESIGNAL_NOTIFICATION_OPENED"),
                                               object: nil,
                                               queue: .main) { notification in
            guard let data = notification.userInfo,
                  let additionalData = data["additionalData"] as? [String: Any] else {
                print("⚠️ No additionalData found in OneSignal notification payload.")
                return
            }

            let type = additionalData["type"] as? String ?? ""
            let senderId = additionalData["senderId"] as? String ?? ""
            let senderName = additionalData["senderName"] as? String ?? "Someone"
            let chatId = additionalData["chatId"] as? String

            print("🔔 Notification opened: type=\(type), chatId=\(chatId ?? "nil"), senderId=\(senderId)")

            // 🔴 Handle group-related chat/notification types
            if ["group", "group_comment", "group_like"].contains(type), let chatId = chatId {
                NotificationRouter.shared.selectedChatId = chatId

                // ✅ Mark chat as unread (to show red dot)
                if !NotificationRouter.shared.unreadChatIds.contains(chatId) {
                    NotificationRouter.shared.unreadChatIds.append(chatId)
                }
            }

            // 🧠 Direct chat fallback for backward compatibility
            if type == "direct", let chatId = chatId {
                NotificationRouter.shared.selectedChatId = chatId
                if !NotificationRouter.shared.unreadChatIds.contains(chatId) {
                    NotificationRouter.shared.unreadChatIds.append(chatId)
                }

                NotificationRouter.shared.selectedChatUser = ChatUserProfile(
                    id: senderId,
                    name: senderName,
                    username: "",
                    profileImageURL: nil
                )
            }

            // 🔗 Optional deep link
            if let deepLink = additionalData["deep_link"] as? String,
               let url = URL(string: deepLink) {
                print("🔗 Opening deep link: \(deepLink)")
                UIApplication.shared.open(url)
            }
        }

        return true
    }

    // Handle Google Sign-In redirect
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // Foreground notification handler
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Optional: native fallback
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("🔔 User tapped native notification: \(userInfo)")
        NotificationCenter.default.post(name: NSNotification.Name("NotificationTapped"), object: nil, userInfo: userInfo)
        completionHandler()
    }

    // MARK: - Main App

    @main
    struct BlackAppIOSApp: App {
        @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
        @StateObject var authVM = AuthViewModel()
        @State private var paymentSuccess = false

        var body: some Scene {
            WindowGroup {
                Group {
                    if authVM.user != nil {
                        MainTabView()
                            .environmentObject(authVM)
                            .onAppear {
                                print("👀 MainTabView appeared. Activating token sync monitor...")
                                _ = TokenSyncMonitor.shared
                            }
                            .onOpenURL { url in
                                if url.absoluteString == "blackappios://payment-success" {
                                    paymentSuccess = true
                                }
                            }
                            .sheet(isPresented: $paymentSuccess) {
                                VStack(spacing: 20) {
                                    Text("🎉 Payment Successful!")
                                        .font(.title)
                                        .foregroundColor(.green)

                                    Text("Thank you for your purchase.")
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.white)

                                    Button("Close") {
                                        paymentSuccess = false
                                    }
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .padding()
                                .background(Color.black)
                            }
                    } else {
                        LoginView()
                            .environmentObject(authVM)
                    }
                }
            }
        }
    }
}
