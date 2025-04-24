import Foundation
import FirebaseAuth
import GoogleSignIn
import Firebase

class AuthViewModel: ObservableObject {
    @Published var user: User?

    init() {
        self.user = Auth.auth().currentUser
    }

    // MARK: - Email Sign Up
    func signUp(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self.user = result.user
                }
                completion(error)
            }
        }
    }

    // MARK: - Email Sign In
    func signIn(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().signIn(withEmail: email, password: password) { result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self.user = result.user
                }
                completion(error)
            }
        }
    }

    // MARK: - Sign Out
    func signOut() {
        do {
            try Auth.auth().signOut()
            DispatchQueue.main.async {
                self.user = nil
            }
        } catch {
            print("Sign out failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Google Sign In
    func signInWithGoogle(presentingVC: UIViewController, completion: @escaping (Error?) -> Void) {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            completion(NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing Firebase Client ID"]))
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC) { result, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }

            guard let googleUser = result?.user,
                  let idToken = googleUser.idToken?.tokenString else {
                DispatchQueue.main.async {
                    completion(NSError(domain: "GoogleSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "Google Sign-In failed"]))
                }
                return
            }

            let accessToken = googleUser.accessToken.tokenString
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)

            Auth.auth().signIn(with: credential) { authResult, error in
                DispatchQueue.main.async {
                    if let user = authResult?.user {
                        self.user = user
                    }
                    completion(error)
                }
            }
        }
    }
}
