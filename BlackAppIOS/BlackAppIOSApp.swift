import SwiftUI
import Firebase
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
        print("✅ FCM Token: \(fcmToken ?? "nil")")
        // Optional: Store this token in Firestore under the user's profile
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
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
