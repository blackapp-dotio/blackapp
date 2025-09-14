// BlackAppIOSApp.swift — Minimal, archive-safe setup
// Keeps: Firebase (Auth/DB/Firestore), App Check, FCM/APNs bridge,
// OneSignal, deep links, referral capture, Invite Orb, payment sheet.

import SwiftUI

// Firebase
import FirebaseCore            // FirebaseApp.configure()
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import FirebaseAppCheck        // App Check (Debug + DeviceCheck)
import FirebaseMessaging       // FCM/APNs bridge

// SSO / Push / System
import GoogleSignIn
import OneSignalFramework
import UserNotifications

// MARK: - AppDelegate
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        // --- App Check provider MUST be set BEFORE FirebaseApp.configure() ---
        #if DEBUG
        // Simulator & debug builds: Debug provider (easy dev; requires console debug token)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        // Release builds: Use DeviceCheck provider (no extra Apple frameworks needed)
        AppCheck.setAppCheckProviderFactory(DeviceCheckProviderFactory())
        #endif

        // --- Firebase core ---
        FirebaseApp.configure()

        // --- Firestore local persistence & larger cache ---
        let fs = Firestore.firestore()
        var fsSettings = fs.settings
        fsSettings.isPersistenceEnabled = true
        fsSettings.cacheSizeBytes = FirestoreCacheSizeUnlimited
        fs.settings = fsSettings

        // --- RTDB persistence & keepSynced hot paths ---
        Database.database().isPersistenceEnabled = true
        ["events","nights","reservations","posts","feed","venues","users","brands"]
            .forEach { Database.database().reference(withPath: $0).keepSynced(true) }

        // --- Push / FCM wiring (safe on Simulator) ---
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        DispatchQueue.main.async { application.registerForRemoteNotifications() }
        Messaging.messaging().delegate = self

        // --- OneSignal (skip on Simulator to reduce noise) ---
        #if !targetEnvironment(simulator)
        OneSignal.initialize("69366bbb-2d87-44b1-921c-3fd2cba8effc", withLaunchOptions: launchOptions)

        // Optional soft re-prompt if not granted
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus != .authorized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    OneSignal.Notifications.requestPermission({ accepted in
                        print("🔁 Push permission prompt result: \(accepted)")
                    }, fallbackToSettings: true)
                }
            }
        }

        // Handle OneSignal deep link payloads (if you use them)
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ONESIGNAL_NOTIFICATION_OPENED"),
            object: nil,
            queue: .main
        ) { note in
            guard let data = note.userInfo,
                  let extra = data["additionalData"] as? [String: Any] else { return }

            let type      = extra["type"] as? String ?? ""
            let senderId  = extra["senderId"] as? String ?? ""
            let sender    = extra["senderName"] as? String ?? "Someone"
            let chatId    = extra["chatId"] as? String

            print("🔔 OneSignal opened: type=\(type) chatId=\(chatId ?? "nil") sender=\(senderId)")

            if ["group","group_comment","group_like"].contains(type), let chatId {
                NotificationRouter.shared.selectedChatId = chatId
                if !NotificationRouter.shared.unreadChatIds.contains(chatId) {
                    NotificationRouter.shared.unreadChatIds.append(chatId)
                }
            }

            if type == "direct", let chatId {
                NotificationRouter.shared.selectedChatId = chatId
                if !NotificationRouter.shared.unreadChatIds.contains(chatId) {
                    NotificationRouter.shared.unreadChatIds.append(chatId)
                }
                NotificationRouter.shared.selectedChatUser = ChatUserProfile(
                    id: senderId, name: sender, username: "", profileImageURL: nil
                )
            }

            if let deep = extra["deep_link"] as? String, let url = URL(string: deep) {
                UIApplication.shared.open(url)
            }
        }
        #else
        print("📵 OneSignal disabled on Simulator")
        #endif

        return true
    }

    // Google Sign-In URL handling
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // APNs <-> FCM bridge (stops “No APNS token” warnings on device)
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ APNs registration failed: \(error.localizedDescription)")
    }

    // FCM token refresh
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("🔗 FCM token: \(fcmToken ?? "nil")")
        // Optionally: send to backend or save in RTDB
    }

    // Foreground push presentation
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("🔔 Native notification tapped: \(userInfo)")
        NotificationCenter.default.post(name: NSNotification.Name("NotificationTapped"),
                                        object: nil,
                                        userInfo: userInfo)
        completionHandler()
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let openEventFromDeepLink = Notification.Name("OpenEventFromDeepLink")
}

// MARK: - Referral helper
fileprivate func storePendingReferrer(from url: URL) {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let ref = comps.queryItems?.first(where: { $0.name.lowercased() == "ref" })?.value,
          !ref.isEmpty else { return }
    UserDefaults.standard.set(ref, forKey: "pendingReferrerUid")
    print("🔗 Stored pending referrer: \(ref)")
}

// MARK: - Overlay wrapper (pins the orb bottom-right over any content)
public struct InviteOrbOverlay<Content: View>: View {
    public let userId: String?
    public let circleSize: Int?
    public let content: Content

    public init(userId: String?, circleSize: Int? = nil, @ViewBuilder content: () -> Content) {
        self.userId = userId
        self.circleSize = circleSize
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    // Uses your InviteOrb (defined in your other file)
                    InviteOrb(userId: userId, circleSize: circleSize)
                        .padding(.trailing, 18)
                        .padding(.bottom, 86)
                        .allowsHitTesting(true)
                }
            }
            .ignoresSafeArea(.keyboard)
        }
    }
}

// MARK: - Authed container
private struct AuthedContainerView: View {
    @ObservedObject var authVM: AuthViewModel
    @Binding var paymentSuccess: Bool

    var body: some View {
        InviteOrbOverlay(userId: authVM.user?.uid, circleSize: nil) { content }
            .onChange(of: authVM.user?.uid) { newUid in
                if let uid = newUid {
                    ReferralManager.consumePendingReferralIfAny(currentUserId: uid)
                }
            }
    }

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
            // Custom scheme deep links
            .onOpenURL { url in
                print("🔗 App opened via URL: \(url.absoluteString)")
                storePendingReferrer(from: url)
                if url.absoluteString == "blackappios://payment-success" { paymentSuccess = true }
                if url.scheme == "blackappios", url.host == "event" {
                    let eventId = url.lastPathComponent
                    NotificationCenter.default.post(
                        name: .openEventFromDeepLink, object: nil, userInfo: ["eventId": eventId]
                    )
                }
            }
            // Universal links
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

// MARK: - Payment sheet
private struct PaymentSuccessSheet: View {
    @Binding var paymentSuccess: Bool
    var body: some View {
        VStack(spacing: 20) {
            Text("🎉 Payment Successful!").font(.title).foregroundColor(.green)
            Text("Thank you for your purchase.").multilineTextAlignment(.center).foregroundColor(.white)
            Button("Close") { paymentSuccess = false }
                .padding().background(Color.blue).foregroundColor(.white).cornerRadius(10)
        }
        .padding().background(Color.black)
    }
}

// MARK: - App Entry
@main
struct BlackAppIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var authVM = AuthViewModel()
    @State private var paymentSuccess = false

    init() {
        // If you rely on this, keep it; otherwise you can remove to go even leaner.
        PerfBootstrap.installURLCache(memMB: 128, diskMB: 512)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authVM.user != nil {
                    AuthedContainerView(authVM: authVM, paymentSuccess: $paymentSuccess)
                        .environmentObject(authVM)
                } else {
                    LoginView().environmentObject(authVM)
                }
            }
        }
    }
}
