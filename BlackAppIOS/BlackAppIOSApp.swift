// BlackAppIOSApp.swift — Minimal, archive-safe setup
// Keeps: Firebase (Auth/DB/Firestore), App Check, FCM/APNs bridge,
// OneSignal, deep links, referral capture, Invite Orb, payment sheet.
// Adds: Actionable notifications + in-app center reply dialog + loud diagnostics.

import SwiftUI
import Combine
import UIKit

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

// MARK: - Notification Category & Action IDs
fileprivate enum PushUX {
    static let categoryChat = "CHAT_MESSAGE"
    static let actionReply  = "REPLY_ACTION"
    static let actionOpen   = "OPEN_ACTION"
    static let actionRead   = "MARK_READ_ACTION"
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        // --- App Check provider MUST be set BEFORE FirebaseApp.configure() ---
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, err in
            #if DEBUG
            print("🔐 requestAuthorization granted=\(granted) error=\(String(describing: err))")
            #endif
        }
        registerNotificationCategories()
        DispatchQueue.main.async { application.registerForRemoteNotifications() }
        Messaging.messaging().delegate = self

        // Print current push state + categories for diagnostics
        debugPrintPushState()

        // --- OneSignal (skip on Simulator to reduce noise) ---
        #if !targetEnvironment(simulator)
        OneSignal.initialize("69366bbb-2d87-44b1-921c-3fd2cba8effc", withLaunchOptions: launchOptions)

        // Optionally enable verbose logs if your SDK has this API
        // #if DEBUG
        // OneSignal.Debug.setLogLevel(.LL_VERBOSE)
        // #endif

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

    /// Register iOS notification actions and categories (text input reply, open, mark read)
    private func registerNotificationCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: PushUX.actionReply,
            title: "Reply",
            options: [], // inline; do not require unlock
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply"
        )

        let open = UNNotificationAction(
            identifier: PushUX.actionOpen,
            title: "Open",
            options: [.foreground]
        )

        let markRead = UNNotificationAction(
            identifier: PushUX.actionRead,
            title: "Mark Read",
            options: []
        )

        let chat = UNNotificationCategory(
            identifier: PushUX.categoryChat,
            actions: [reply, open, markRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([chat])
    }

    // MARK: - Diagnostics Helpers

    // Pretty-print APNs token
    private func hexDeviceToken(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    // Print authorization + registered categories
    private func debugPrintPushState() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status: String = {
                switch settings.authorizationStatus {
                case .notDetermined: return "notDetermined"
                case .denied:        return "denied"
                case .authorized:    return "authorized"
                case .provisional:   return "provisional"
                case .ephemeral:     return "ephemeral"
                @unknown default:    return "unknown"
                }
            }()
            print("🔐 Notification settings → status=\(status) alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) badge=\(settings.badgeSetting.rawValue)")
        }
        center.getNotificationCategories { cats in
            let list = cats.map { cat in
                let acts = cat.actions.map { $0.identifier }.joined(separator: ",")
                return "\(cat.identifier)[\(acts)]"
            }.joined(separator: " | ")
            print("🏷️ Registered categories → \(list)")
        }
    }

    // Google Sign-In URL handling
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // APNs <-> FCM bridge (stops “No APNS token” warnings on device)
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = hexDeviceToken(deviceToken)
        print("📲 APNs device token (hex, \(deviceToken.count) bytes): \(hex)")
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ APNs registration failed: \(error.localizedDescription)")
    }

    // FCM token refresh
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("🔗 FCM registration token: \(fcmToken ?? "nil")")
        if let apns = Messaging.messaging().apnsToken {
            print("🔗 FCM bridge sees APNs token (len=\(apns.count))")
        } else {
            print("⚠️ FCM bridge has no APNs token yet")
        }
    }

    // Foreground push presentation
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let c = notification.request.content
        let aps = (c.userInfo["aps"] as? [AnyHashable: Any]) ?? [:]
        let apnsCategory = (aps["category"] as? String) ?? "∅"

        #if DEBUG
        print("🔔 willPresent category=\(c.categoryIdentifier) aps.category=\(apnsCategory) title=\(c.title) body=\(c.body) userInfo=\(c.userInfo)")
        #endif

        // Treat as chat if category matches OR payload indicates chat
        let isChatish =
            (c.categoryIdentifier == PushUX.categoryChat) ||
            (c.userInfo["chatId"] != nil) ||
            (c.userInfo["groupId"] != nil) ||
            ((c.userInfo["type"] as? String) == "direct")

        if isChatish {
            // Suppress system UI in foreground, show our dialog
            completionHandler([])
            InAppDialogManager.shared.present(
                title: c.title,
                body: c.body,
                userInfo: c.userInfo
            )
        } else {
            // Non-chat pushes keep normal behavior
            completionHandler([.banner, .list, .sound])
        }
    }

    // Background/terminated receipt (logs APS + category when system wakes us)
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let aps = userInfo["aps"] as? [AnyHashable: Any] ?? [:]
        let cat = (aps["category"] as? String) ?? "∅"
        let alert = (aps["alert"] as? [String: Any]) ?? [:]
        let title = alert["title"] as? String ?? (userInfo["title"] as? String) ?? "∅"
        let body = alert["body"]  as? String ?? (userInfo["body"]  as? String) ?? "∅"
        print("📨 didReceiveRemoteNotification → category=\(cat) title=\(title) body=\(body) userInfo=\(userInfo)")
        completionHandler(.noData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case PushUX.actionReply:
            if let textResp = response as? UNTextInputNotificationResponse {
                QuickReplyHandler.shared.sendReply(userInfo: userInfo, text: textResp.userText) { _ in
                    completionHandler()
                }
                return
            }
        case PushUX.actionRead:
            QuickReplyHandler.shared.markRead(userInfo: userInfo) { _ in completionHandler() }
            return
        case PushUX.actionOpen, UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: NSNotification.Name("NotificationTapped"),
                                            object: nil,
                                            userInfo: userInfo)
            completionHandler()
            return
        default:
            break
        }

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

// MARK: - In-app center dialog for foreground pushes
struct InAppDialog: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let userInfo: [AnyHashable: Any]
}

final class InAppDialogManager: ObservableObject {
    static let shared = InAppDialogManager()
    @Published var item: InAppDialog?
    private init() {}

    func present(title: String, body: String, userInfo: [AnyHashable: Any]) {
        DispatchQueue.main.async {
            self.item = InAppDialog(title: title, body: body, userInfo: userInfo)
        }
    }
    func dismiss() { item = nil }
}

// MARK: - Orb palette (match the Invite Orb look)
fileprivate enum OrbPalette {
    static let blue   = Color(red: 0.20, green: 0.45, blue: 1.00)
    static let violet = Color(red: 0.55, green: 0.20, blue: 0.85)
}

// MARK: - Logo mark (top-left “stamp”)
// Looks for an asset named "BlackAppMark", "AppLogo", or "blackapp_logo".
// Falls back to a system symbol if not found.
fileprivate struct LogoMark: View {
    var size: CGFloat = 26

    var body: some View {
        if let ui = Self.loadLogo() {
            Image(uiImage: ui)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        } else {
            Image(systemName: "seal.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        }
    }

    private static func loadLogo() -> UIImage? {
        for name in ["BlackAppMark", "AppLogo", "blackapp_logo"] {
            if let img = UIImage(named: name) { return img }
        }
        return nil
    }
}

// MARK: - Glass panel with glowing rim (lightweight & compiler-friendly)
fileprivate struct FuturisticGlassPanel<Content: View>: View {
    let content: Content
    @State private var pulse = false

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        // Keep expressions simple for fast type-checking
        let baseFill = Color.black.opacity(0.82)
        let rim = AngularGradient(
            gradient: Gradient(colors: [
                OrbPalette.blue.opacity(0.85),
                .white.opacity(0.25),
                OrbPalette.violet.opacity(0.85),
                .white.opacity(0.25),
                OrbPalette.blue.opacity(0.85)
            ]),
            center: .center
        )

        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(baseFill)
                .overlay(
                    // thin inner highlight for glassy look
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(
                    // animated glowing rim
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(rim, lineWidth: pulse ? 1.8 : 1.1)
                        .blur(radius: pulse ? 0.9 : 1.4)
                        .opacity(0.9)
                )
                .shadow(color: OrbPalette.blue.opacity(pulse ? 0.28 : 0.18), radius: pulse ? 22 : 14, x: 0, y: 10)
                .shadow(color: OrbPalette.violet.opacity(pulse ? 0.28 : 0.18), radius: pulse ? 22 : 14, x: 0, y: 10)
                .background(
                    // faint gradient wash under the glass
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(
                            colors: [OrbPalette.blue.opacity(0.18), OrbPalette.violet.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .blur(radius: 24)
                )

            content
                .padding(16)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}

// MARK: - Orb-style translucent CTA buttons
fileprivate struct FuturisticCTAButton: View {
    enum Role { case primary, secondary }
    let title: String
    let systemImage: String?
    let role: Role
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, role: Role = .primary, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let name = systemImage {
                    Image(systemName: name).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(minWidth: 92)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: OrbPalette.blue.opacity(role == .primary ? 0.25 : 0.12), radius: 10, x: 0, y: 6)
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        Group {
            switch role {
            case .primary:
                LinearGradient(
                    colors: [
                        OrbPalette.blue.opacity(0.34),
                        OrbPalette.violet.opacity(0.34)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .secondary:
                Color.white.opacity(0.06)
            }
        }
        .background(.ultraThinMaterial.opacity(role == .primary ? 0.10 : 0.06))
    }

    private var border: Color {
        role == .primary ? Color.white.opacity(0.16) : Color.white.opacity(0.12)
    }
}

// MARK: - Updated In-App Notification Dialog (with logo + orb styling)
struct InAppNotificationDialog: View {
    @ObservedObject var manager = InAppDialogManager.shared
    @State private var replyText = ""

    var body: some View {
        Group {
            if let item = manager.item {
                ZStack {
                    // Dim the background; tap outside to dismiss
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { manager.dismiss() }

                    FuturisticGlassPanel {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 14) {
                                // Title & body
                                VStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.headline.weight(.semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                    Text(item.body)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.85))
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                                .padding(.top, 6)

                                // Reply field
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                                    .overlay(
                                        TextField("Reply…", text: $replyText)
                                            .textInputAutocapitalization(.sentences)
                                            .disableAutocorrection(false)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                    )
                                    .frame(height: 44)

                                // Actions
                                HStack(spacing: 10) {
                                    FuturisticCTAButton("Dismiss", systemImage: "xmark", role: .secondary) {
                                        manager.dismiss()
                                    }
                                    Spacer(minLength: 8)
                                    FuturisticCTAButton("Send", systemImage: "paperplane.fill", role: .primary) {
                                        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !text.isEmpty else { return }
                                        QuickReplyHandler.shared.sendReply(userInfo: item.userInfo, text: text) { _ in
                                            manager.dismiss()
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: 360)

                            // Logo stamp (top-left inside the panel)
                            LogoMark(size: 24)
                                .padding(8)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: manager.item != nil)
    }
}


// MARK: - Quick reply -> RTDB helper (adjust paths to your schema)
final class QuickReplyHandler {
    static let shared = QuickReplyHandler()
    private init() {}

    /// userInfo from push should include `chatId` OR `groupId` etc.
    func sendReply(userInfo: [AnyHashable: Any], text: String, completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(false); return }

        if let chatId = (userInfo["chatId"] as? String), !chatId.isEmpty {
            let ref = Database.database().reference()
                .child("directChats").child(chatId).child("messages").childByAutoId()

            let payload: [String: Any] = [
                "senderId": uid,
                "text": text,
                "timestamp": Date().timeIntervalSince1970,
                "type": "text",
                "seen": false
            ]
            ref.setValue(payload) { err, _ in completion(err == nil) }
            return
        }

        if let groupId = (userInfo["groupId"] as? String), !groupId.isEmpty {
            let ref = Database.database().reference()
                .child("groups").child(groupId).child("messages").childByAutoId()

            let payload: [String: Any] = [
                "senderId": uid,
                "text": text,
                "timestamp": Date().timeIntervalSince1970,
                "type": "text",
                "likes": 0
            ]
            ref.setValue(payload) { err, _ in completion(err == nil) }
            return
        }

        completion(false)
    }

    func markRead(userInfo: [AnyHashable: Any], completion: @escaping (Bool) -> Void) {
        // Implement if you maintain unread counters (e.g., /readReceipts/{chatId}/{uid}=timestamp)
        completion(true)
    }
}

// MARK: - Authed container
private struct AuthedContainerView: View {
    @ObservedObject var authVM: AuthViewModel
    @Binding var paymentSuccess: Bool

    // Split out to keep the type checker happy
    @ViewBuilder
    private var mainStack: some View {
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

    var body: some View {
        // Keep the view tree simple to avoid type-checker blowups
        InviteOrbOverlay(userId: authVM.user?.uid, circleSize: nil) {
            mainStack
        }
        .overlay(InAppNotificationDialog())
        .onChange(of: authVM.user?.uid) { newUid in
            if let uid = newUid {
                ReferralManager.consumePendingReferralIfAny(currentUserId: uid)
            }
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
import SwiftUI
import FirebaseAuth

@main
struct BlackAppIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var authVM = AuthViewModel()
    @State private var paymentSuccess = false

    init() {
        // Keep your existing performance bootstrap
        PerfBootstrap.installURLCache(memMB: 128, diskMB: 512)
        // ⛔️ Do NOT call FirebaseApp.configure() here
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authVM.user != nil {
                    AuthedContainerView(authVM: authVM, paymentSuccess: $paymentSuccess)
                        .environmentObject(authVM)
                } else {
                    LoginView()
                        .environmentObject(authVM)
                }
            }
            // Forward phone-auth callback URLs to Firebase Auth
            .onOpenURL { url in
                if Auth.auth().canHandle(url) { return }
                // Handle other deep links here if needed
            }
        }
    }
}

