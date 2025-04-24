import SwiftUI
import GoogleSignInSwift
import FirebaseAuth

struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var showLogo = false

    var body: some View {
        VStack(spacing: 20) {
            if showLogo {
                Image("blackapp_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .opacity(showLogo ? 1 : 0)
                    .animation(.easeIn(duration: 1.0), value: showLogo)
            }

            TextField("Email", text: $email)
                .autocapitalization(.none)
                .keyboardType(.emailAddress)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

            SecureField("Password", text: $password)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Sign In") {
                    authVM.signIn(email: email, password: password) { error in
                        if let error = error {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Sign Up") {
                    authVM.signUp(email: email, password: password) { error in
                        if let error = error {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            Divider().padding(.vertical)

            GoogleSignInButton {
                if let rootVC = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                    .first?.rootViewController {

                    authVM.signInWithGoogle(presentingVC: rootVC) { error in
                        if let error = error {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .frame(height: 44)
        }
        .padding()
        .onAppear {
            showLogo = true
        }
    }
}
