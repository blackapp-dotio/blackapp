import Foundation
import FirebaseAuth
import GoogleSignIn
import GoogleSignInSwift
import Firebase

class AuthViewModel: ObservableObject {
    @Published var user: User?

    init() {
        self.user = Auth.auth().currentUser
    }

    func signUp(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            self.user = result?.user
            completion(error)
        }
    }

    func signIn(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().signIn(withEmail: email, password: password) { result, error in
            self.user = result?.user
            completion(error)
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        self.user = nil
    }

    func signInWithGoogle(presentingVC: UIViewController, completion: @escaping (Error?) -> Void) {
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC) { result, error in
            if let error = error {
                completion(error)
                return
            }

            guard
                let user = result?.user,
                let idToken = user.idToken?.tokenString
            else {
                completion(NSError(domain: "GoogleSignIn", code: -1, userInfo: nil))
                return
            }

            let accessToken = user.accessToken.tokenString


            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)

            Auth.auth().signIn(with: credential) { result, error in
                self.user = result?.user
                completion(error)
            }
        }
    }
}
