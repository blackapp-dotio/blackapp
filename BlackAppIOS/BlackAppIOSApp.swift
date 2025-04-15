import SwiftUI
import Firebase

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        return true
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
