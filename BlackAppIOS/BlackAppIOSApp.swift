// BlackAppIOSApp.swift — Stable base + App Check that works on Simulator & Devices
// Keeps: RTDB caching/keepSynced, OneSignal, deep links, referral capture,
// Invite Orb overlay, payment success sheet, etc.  Optimized for launch speed.

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase            // RTDB caching / keepSynced
import FirebaseFunctions
import FirebaseAppCheck            // ✅ App Check providers
import FirebaseFirestore           // ✅ Firestore settings/persistence
import GoogleSignIn
import GoogleSignInSwift
import OneSignalFramework
import UserNotifications

// MARK: - AppDelegate
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // ✅ App Check provider factory MUST be set BEFORE FirebaseApp.configure()
        // Simulator & all DEBUG builds -> Debug provider (easy dev)
        // Release on device -> App Attest (preferred) else DeviceCheck
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())

        print("🛡️ App Check: Debug provider (DEBUG build)")
        #else
        if AppAttestProvider.isSupported() {
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
            print("🛡️ App Check: App Attest provider")
        } else {
            AppCheck.setAppCheckProviderFactory(DeviceCheckProviderFactory())
            print("🛡️ App Check: DeviceCheck provider (fallback)")
        }
        #endif

        // Firebase
        FirebaseApp.configure()

        // ✅ Firestore: local persistence & bigger cache for snappy suggestive search
        let fs = Firestore.firestore()
        let fsSettings = fs.settings
        fsSettings.isPersistenceEnabled = true
        // cacheSizeBytes unlimited avoids churn when users scroll around a lot
        fsSettings.cacheSizeBytes = FirestoreCacheSizeUnlimited
        fs.settings = fsSettings

        // ✅ RTDB: local persistence + hot-path keepSynced
        Database.database().isPersistenceEnabled = true

        // Keep hot paths synchronized in background so UI is instant when opened.
        // Includes users & brands to accelerate the Search preview modal.
        let hotPaths = [
            "events", "nights", "reservations", "posts", "feed", "venues",
            "users",            // ✅ Search suggestions, avatars, circleSize
            "brands"            // ✅ Preview modal brand strip
        ]
        hotPaths.forEach { Database.database().reference(withPath: $0).keepSynced(true) }

        // ❌ Remove duplicate URLCache tuning here — it’s installed earlier in App.init()
        // (PerfBootstrap.installURLCache in @main) to ensure it applies to all sessions.

        // OneSignal setup (SDK 3.x+)
        #if !targetEnvironment(simulator)
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
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ONESIGNAL_NOTIFICATION_OPENED"),
            object: nil,
            queue: .main
        ) { notification in
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
        #else
        print("📵 OneSignal disabled on Simulator to avoid network churn")
        #endif

        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey : Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // Push presentation
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
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

    // ✅ Phase-1 perf bootstrap: enlarge URLCache early (before any networking)
    init() {
        PerfBootstrap.installURLCache(memMB: 128, diskMB: 512)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authVM.user != nil {
                    AuthedContainerView(authVM: authVM, paymentSuccess: $paymentSuccess)
                        .environmentObject(authVM) // harmless: keeps AuthVM available to subviews
                } else {
                    LoginView()
                        .environmentObject(authVM)
                }
            }
        }
    }
}
