import SwiftUI
import Firebase
import FirebaseAuth
import GoogleSignIn
import GoogleSignInSwift
import FirebaseMessaging
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        FirebaseApp.configure()
        Messaging.messaging().delegate = self

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("🔔 Push notification permission granted: \(granted)")
        }

        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("✅ FCM Token received (delegate): \(fcmToken ?? "nil")")

        guard let userId = Auth.auth().currentUser?.uid else {
            print("⚠️ No user signed in yet. Token not saved.")
            return
        }

        guard let fcmToken = fcmToken else {
            print("❌ Token is nil in delegate.")
            return
        }

        Firestore.firestore().collection("users").document(userId).setData([
            "fcmToken": fcmToken
        ], merge: true) { error in
            if let error = error {
                print("❌ Failed to save token via delegate: \(error.localizedDescription)")
            } else {
                print("✅ Token saved via delegate for user \(userId)")
            }
        }
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
        print("🔔 User tapped notification with payload: \(userInfo)")

        NotificationCenter.default.post(name: NSNotification.Name("NotificationTapped"), object: nil, userInfo: userInfo)
        completionHandler()
    }
}

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
                            updateFCMTokenIfNeeded()
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

// MARK: - Manual FCM Token Sync with Retry
func updateFCMTokenIfNeeded(retryCount: Int = 0) {
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
                    updateFCMTokenIfNeeded(retryCount: retryCount + 1)
                }
            }
            return
        }

        print("📡 Retrieved FCM token manually: \(token)")

        Firestore.firestore().collection("users").document(user.uid).setData(["fcmToken": token], merge: true) { error in
            if let error = error {
                print("❌ Failed to save FCM token manually: \(error.localizedDescription)")
            } else {
                print("✅ Manually synced FCM token to Firestore")
            }
        }
    }
}
