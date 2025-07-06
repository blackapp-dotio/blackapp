import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import GoogleSignIn
import OneSignalFramework

class AuthViewModel: ObservableObject {
    @Published var user: User?

    init() {
        self.user = Auth.auth().currentUser
        migrateUsersFromRealtimeToFirestore()

        // ✅ Sync OneSignal Player ID if user is already signed in
        if Auth.auth().currentUser != nil {
            OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
        }
    }

    // MARK: - OneSignal Player ID Sync (Replaced with central manager)
    func updateOneSignalPlayerIdForCurrentUser() {
        OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
    }

    // MARK: - Email Sign Up
    func signUp(email: String, password: String, name: String, username: String, profileImageURL: String = "", completion: @escaping (Error?) -> Void) {
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            guard let result = result, error == nil else {
                DispatchQueue.main.async { completion(error) }
                return
            }

            let uid = result.user.uid
            self.user = result.user

            let userData: [String: Any] = [
                "name": name,
                "username": username,
                "profileImageURL": profileImageURL
            ]

            // Save to both databases
            Database.database().reference().child("users").child(uid).setValue(userData)
            Firestore.firestore().collection("users").document(uid).setData(userData)

            DispatchQueue.main.async {
                OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                completion(nil)
            }
        }
    }

    // MARK: - Email Sign In
    func signIn(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().signIn(withEmail: email, password: password) { result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self.user = result.user
                    OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
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

                        let uid = user.uid
                        let name = user.displayName ?? "Unnamed"
                        let username = user.email?.components(separatedBy: "@").first ?? uid.prefix(6).description
                        let profileImageURL = user.photoURL?.absoluteString ?? ""

                        let userData: [String: Any] = [
                            "name": name,
                            "username": username,
                            "profileImageURL": profileImageURL
                        ]

                        Database.database().reference().child("users").child(uid).setValue(userData)
                        Firestore.firestore().collection("users").document(uid).setData(userData)
                        OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                    }
                    completion(error)
                }
            }
        }
    }

    // MARK: - One-Time Migration Function
    func migrateUsersFromRealtimeToFirestore() {
        let realtimeRef = Database.database().reference().child("users")
        let firestoreRef = Firestore.firestore().collection("users")

        realtimeRef.observeSingleEvent(of: .value) { snapshot in
            guard snapshot.exists() else {
                print("❌ No users found in Realtime Database.")
                return
            }

            for case let child as DataSnapshot in snapshot.children {
                let uid = child.key
                guard let data = child.value as? [String: Any] else { continue }

                var userData: [String: Any] = [:]
                if let name = data["name"] as? String { userData["name"] = name }
                if let username = data["username"] as? String { userData["username"] = username }
                if let image = data["profileImageURL"] as? String { userData["profileImageURL"] = image }

                firestoreRef.document(uid).setData(userData) { error in
                    if let error = error {
                        print("❌ Failed to write user \(uid): \(error.localizedDescription)")
                    } else {
                        print("✅ Migrated user \(uid) to Firestore.")
                    }
                }
            }
        }
    }
}
