// BlackAppIOSApp.swift — Updated with: RTDB caching + hot-path sync, global Invite Orb overlay,
// referral capture (deep links & universal links), and post-login referral consumption.
// Refactored to avoid SwiftUI type-checker blowups.

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase   // RTDB caching / keepSynced
import FirebaseFunctions  // <- needed for ReferralManager callable func
import GoogleSignIn
import GoogleSignInSwift
import OneSignalFramework

// MARK: - AppDelegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Firebase setup
        FirebaseApp.configure()

        // ✅ Local persistence + background sync for hot paths
        // Must be set BEFORE any Database reference is used elsewhere in the app.
        Database.database().isPersistenceEnabled = true
        let hotPaths = ["events", "nights", "reservations", "posts", "feed", "venues"]
        hotPaths.forEach { Database.database().reference(withPath: $0).keepSynced(true) }

        // ✅ Bigger HTTP cache (helps flyers/thumbnails and general web loads)
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB RAM
            diskCapacity:   512 * 1024 * 1024   // 512 MB disk
        )

        // OneSignal setup (SDK 3.x+)
        OneSignal.initialize("69366bbb-2d87-44b1-921c-3fd2cba8effc", withLaunchOptions: launchOptions)

        // 🔁 Re-prompt for push notification permissions if not yet granted
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    OneSignal.Notifications.requestPermission({ accepted in
                        print("🔁 Re-prompted push permission: \(accepted)")
                    }, fallbackToSettings: true)
                }
            }
        }

        // Deep link + OneSignal handler
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

            if ["group", "group_comment", "group_like"].contains(type), let chatId = chatId {
                NotificationRouter.shared.selectedChatId = chatId
                if !NotificationRouter.shared.unreadChatIds.contains(chatId) {
                    NotificationRouter.shared.unreadChatIds.append(chatId)
                }
            }

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

            if let deepLink = additionalData["deep_link"] as? String,
               let url = URL(string: deepLink) {
                print("🔗 Opening deep link: \(deepLink)")
                UIApplication.shared.open(url)
            }
        }

        return true
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("🔔 User tapped native notification: \(userInfo)")
        NotificationCenter.default.post(name: NSNotification.Name("NotificationTapped"), object: nil, userInfo: userInfo)
        completionHandler()
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let openEventFromDeepLink = Notification.Name("OpenEventFromDeepLink")
}

// MARK: - Private helpers (referral capture)
fileprivate func storePendingReferrer(from url: URL) {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let ref = comps.queryItems?.first(where: { $0.name.lowercased() == "ref" })?.value,
          !ref.isEmpty else { return }
    UserDefaults.standard.set(ref, forKey: "pendingReferrerUid")
    print("🔗 Stored pending referrer: \(ref)")
}



// MARK: - A small container view to avoid type-checker blowups
private struct AuthedContainerView: View {
    @ObservedObject var authVM: AuthViewModel
    @Binding var paymentSuccess: Bool

    var body: some View {
        // NOTE: circleSize isn’t on your User model yet — pass nil for now.
        InviteOrbOverlay(userId: authVM.user?.uid, circleSize: nil) {
            content
        }
        // If auth flips to signed-in while app is running, try to consume pending referral.
        .onChange(of: authVM.user?.uid) { newUid in
            if let uid = newUid {
                ReferralManager.consumePendingReferralIfAny(currentUserId: uid)
            }
        }
    }

    // Split the heavy modifier chain out as a computed var; simpler = faster type-check.
    @ViewBuilder
    private var content: some View {
        MainTabView()
            .environmentObject(authVM)
            .onAppear {
                print("👀 MainTabView appeared. Activating token sync monitor...")
                _ = TokenSyncMonitor.shared
                if let uid = Auth.auth().currentUser?.uid {
                    ReferralManager.consumePendingReferralIfAny(currentUserId: uid)
                }
            }
            // Handle custom-scheme deep links
            .onOpenURL { url in
                print("🔗 App opened via URL: \(url.absoluteString)")
                // Capture referral for ?ref=...
                storePendingReferrer(from: url)

                if url.absoluteString == "blackappios://payment-success" {
                    paymentSuccess = true
                }

                if url.scheme == "blackappios", url.host == "event" {
                    let eventId = url.lastPathComponent
                    NotificationCenter.default.post(
                        name: .openEventFromDeepLink,
                        object: nil,
                        userInfo: ["eventId": eventId]
                    )
                }
            }
            // Handle Universal Links (https://blackapp.app/...)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    print("🌐 Universal Link: \(url.absoluteString)")
                    storePendingReferrer(from: url)
                }
            }
            .sheet(isPresented: $paymentSuccess) {
                PaymentSuccessSheet(paymentSuccess: $paymentSuccess)
            }
    }
}

// Extracted sheet into a tiny view to further help the compiler
private struct PaymentSuccessSheet: View {
    @Binding var paymentSuccess: Bool
    var body: some View {
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
}

// MARK: - Main App Entry
@main
struct BlackAppIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var authVM = AuthViewModel()
    @State private var paymentSuccess = false

    var body: some Scene {
        WindowGroup {
            Group {
                if authVM.user != nil {
                    AuthedContainerView(authVM: authVM, paymentSuccess: $paymentSuccess)
                } else {
                    LoginView()
                        .environmentObject(authVM)
                }
            }
        }
    }
}
