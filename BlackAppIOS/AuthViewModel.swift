import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import FirebaseFunctions       // ✅ needed for the callable
import GoogleSignIn
import OneSignalFramework

class AuthViewModel: ObservableObject {
    @Published var user: User?
    @Published var currentUser: User?
    
    // Optional helper for use in views
    var currentUserId: String? { currentUser?.uid }

    // Cache Functions instance
    private let functions = Functions.functions()

    init() {
        self.user = Auth.auth().currentUser
        self.currentUser = Auth.auth().currentUser
        migrateUsersFromRealtimeToFirestore()

        // Listen for auth state changes
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.currentUser = user
                if let _ = user {
                    OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                    // ✅ Ensure defaults exist after any sign-in path
                    self.seedUserDefaultsIfNeeded()
                }
            }
        }
    }

    // MARK: - Sign Out
    func signOut() {
        do {
            try Auth.auth().signOut()
            DispatchQueue.main.async {
                self.user = nil
                self.currentUser = nil
            }
        } catch {
            print("❌ Sign out failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Email Sign Up
    func signUp(email: String,
                password: String,
                name: String,
                username: String,
                profileImageURL: String = "",
                completion: @escaping (Error?) -> Void)
    {
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            guard let result = result, error == nil else {
                DispatchQueue.main.async { completion(error) }
                return
            }
            
            let uid = result.user.uid
            self.user = result.user

            // Seed minimal profile in RTDB + Firestore (also include defaults—harmless if callable runs too)
            let userData: [String: Any] = [
                "name": name,
                "username": username,
                "profileImageURL": profileImageURL,
                "circleSize": 0,
                "badgeTier": "white"
            ]
            Database.database().reference().child("users").child(uid).updateChildValues(userData)
            Firestore.firestore().collection("users").document(uid).setData(userData, merge: true)

            DispatchQueue.main.async {
                self.currentUser = result.user
                OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                // ✅ Also call callable to guarantee defaults server-side
                self.seedUserDefaultsIfNeeded()
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
                    self.currentUser = result.user
                    OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                    // ✅ Ensure defaults
                    self.seedUserDefaultsIfNeeded()
                }
                completion(error)
            }
        }
    }

    // MARK: - Google Sign-In
    func signInWithGoogle(presentingVC: UIViewController, completion: @escaping (Error?) -> Void) {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            completion(NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing Firebase Client ID"]))
            return
        }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC) { result, error in
            if let error = error {
                DispatchQueue.main.async { completion(error) }
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
                        self.currentUser = user
                        
                        let uid = user.uid
                        let name = user.displayName ?? "Unnamed"
                        let username = user.email?.components(separatedBy: "@").first ?? String(uid.prefix(6))
                        let profileImageURL = user.photoURL?.absoluteString ?? ""
                        
                        let userData: [String: Any] = [
                            "name": name,
                            "username": username,
                            "profileImageURL": profileImageURL,
                            "circleSize": 0,
                            "badgeTier": "white"
                        ]
                        Database.database().reference().child("users").child(uid).updateChildValues(userData)
                        Firestore.firestore().collection("users").document(uid).setData(userData, merge: true)

                        OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
                        // ✅ Ensure defaults on server too
                        self.seedUserDefaultsIfNeeded()
                    }
                    completion(error)
                }
            }
        }
    }

    // MARK: - Callable: ensureUserDefaults
    /// Calls the Cloud Function `ensureUserDefaults` to guarantee `circleSize` and `badgeTier` exist server-side.
    private func seedUserDefaultsIfNeeded() {
        guard Auth.auth().currentUser != nil else { return }
        functions.httpsCallable("ensureUserDefaults").call { result, error in
            if let error = error {
                print("❌ ensureUserDefaults error: \(error.localizedDescription)")
                return
            }
            if let dict = result?.data as? [String: Any] {
                print("✅ ensureUserDefaults:", dict)
            }
        }
    }

    // MARK: - Realtime to Firestore Migration (unchanged)
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
                if let circle = data["circleSize"] as? Int { userData["circleSize"] = circle }
                if let badge = data["badgeTier"] as? String { userData["badgeTier"] = badge }

                firestoreRef.document(uid).setData(userData, merge: true) { error in
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
