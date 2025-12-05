import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn
import OneSignalFramework

final class AuthViewModel: ObservableObject {
    @Published var user: User?
    @Published var currentUser: User?

    var currentUserId: String? { currentUser?.uid }

    private let functions = Functions.functions()

    // MARK: - Init
    init() {
        self.user = Auth.auth().currentUser
        self.currentUser = Auth.auth().currentUser

        // If app cold-starts while already signed in, bind OneSignal immediately
        if let uid = Auth.auth().currentUser?.uid {
            bindOneSignalExternalId(uid: uid)
            OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()
        }

        // 🔄 Listen for auth changes
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            DispatchQueue.main.async {
                self.user = user
                self.currentUser = user

                guard let user else {
                    // User signed out
                    self.unbindOneSignalExternalId()
                    return
                }

                // Push tokens → server (your existing helper)
                OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()

                // Map Firebase UID to OneSignal external user id
                self.bindOneSignalExternalId(uid: user.uid)

                // 1) Ensure minimal defaults (CF)
                self.seedUserDefaultsIfNeeded()

                // 2) Ensure profile exists & normalized in both DBs (fast search)
                Task { await self.ensureCurrentUserProfileMirroredAndNormalized(user) }
            }
        }
    }

    // MARK: - Public Auth APIs

    func signOut() {
        do {
            try Auth.auth().signOut()
            // Unbind OneSignal external id on logout
            unbindOneSignalExternalId()

            DispatchQueue.main.async {
                self.user = nil
                self.currentUser = nil
            }
        } catch {
            print("❌ Sign out failed: \(error.localizedDescription)")
        }
    }

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

            let fbUser = result.user
            self.user = fbUser
            self.currentUser = fbUser

            // Map UID → OneSignal + sync token doc
            self.bindOneSignalExternalId(uid: fbUser.uid)
            OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()

            Task {
                // Upsert normalized profile to both DBs
                await self.upsertProfileForCurrentUser(
                    name: name,
                    username: username,
                    profileImageURL: profileImageURL
                )

                // Defaults
                self.seedUserDefaultsIfNeeded()

                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func signIn(email: String, password: String, completion: @escaping (Error?) -> Void) {
        Auth.auth().signIn(withEmail: email, password: password) { result, error in
            DispatchQueue.main.async {
                if let user = result?.user {
                    self.user = user
                    self.currentUser = user

                    // Map UID → OneSignal + sync token doc
                    self.bindOneSignalExternalId(uid: user.uid)
                    OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()

                    self.seedUserDefaultsIfNeeded()
                    Task { await self.ensureCurrentUserProfileMirroredAndNormalized(user) }
                }
                completion(error)
            }
        }
    }

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
                if let error = error {
                    DispatchQueue.main.async { completion(error) }
                    return
                }

                guard let fbUser = authResult?.user else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                DispatchQueue.main.async {
                    self.user = fbUser
                    self.currentUser = fbUser
                }

                // Map UID → OneSignal + sync token doc
                self.bindOneSignalExternalId(uid: fbUser.uid)
                OneSignalTokenManager.shared.syncOneSignalUserIdToFirebase()

                // Build best-effort profile from Google
                let uid = fbUser.uid
                let name = fbUser.displayName ?? "User"
                let emailHandle = fbUser.email?.components(separatedBy: "@").first ?? String(uid.prefix(6))
                let usernameRaw = emailHandle.isEmpty ? String(uid.prefix(6)) : emailHandle
                let profileImageURL = fbUser.photoURL?.absoluteString ?? ""

                Task {
                    await self.upsertProfileForCurrentUser(
                        name: name,
                        username: usernameRaw,
                        profileImageURL: profileImageURL
                    )

                    self.seedUserDefaultsIfNeeded()
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }

    // MARK: - OneSignal mapping

    /// Binds Firebase UID to OneSignal external user id (required for include_external_user_ids)
    private func bindOneSignalExternalId(uid: String) {
        // OneSignal SDK v5+
        OneSignal.login(uid)
        // Optional: useful tags for segmentation/diagnostics
        #if DEBUG
        OneSignal.User.addTags(["env": "debug"])
        #else
        OneSignal.User.addTags(["env": "prod"])
        #endif
        print("🔗 OneSignal.login → \(uid)")
    }

    /// Unbinds on sign out
    private func unbindOneSignalExternalId() {
        OneSignal.logout()
        print("🔗 OneSignal.logout")
    }

    // MARK: - Write/Normalize Helpers

    /// Ensures the current user has a normalized profile in both RTDB and Firestore.
    private func ensureCurrentUserProfileMirroredAndNormalized(_ fbUser: User) async {
        // Try to read a minimal profile; if missing or not normalized, upsert.
        let (name, username, photo) = await readBestEffortCurrentProfile(uid: fbUser.uid)
        await upsertProfileForCurrentUser(
            name: name ?? (fbUser.displayName ?? "User"),
            username: username ?? (fbUser.email?.components(separatedBy: "@").first ?? String(fbUser.uid.prefix(6))),
            profileImageURL: photo ?? fbUser.photoURL?.absoluteString ?? ""
        )
    }

    /// Upserts to RTDB and Firestore with normalized, indexed fields.
    private func upsertProfileForCurrentUser(name: String,
                                             username: String,
                                             profileImageURL: String) async
    {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        // Derive clean username & normalized search fields
        let cleanUsername = username.replacingOccurrences(of: " ", with: "")
        let nameLower = name.lowercased()
        let usernameLower = cleanUsername.lowercased()

        // Merge payload (safe defaults)
        var payload: [String: Any] = [
            "name": name,
            "username": cleanUsername,
            "profileImageURL": profileImageURL,
            // defaults if absent server-side; CF will also enforce
            "circleSize": FieldValue.increment(Int64(0)), // Firestore no-op for merge
            "badgeTier": "white",
            // normalized searchable fields
            "nameLower": nameLower,
            "usernameLower": usernameLower
        ]

        // RTDB write
        let rtdbRef = Database.database().reference(withPath: "users/\(uid)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // RTDB lacks FieldValue.increment. Strip it.
            var rtdbPayload = payload
            rtdbPayload["circleSize"] = (rtdbPayload["circleSize"] as? Int) ?? 0
            rtdbRef.updateChildValues(rtdbPayload) { _, _ in cont.resume() }
        }

        // Firestore write (merge)
        let fsRef = Firestore.firestore().collection("users").document(uid)
        do {
            try await fsRef.setData(payload, merge: true)
        } catch {
            print("❌ Firestore user upsert failed: \(error.localizedDescription)")
        }
    }

    /// Reads a minimal profile from RTDB first (hot cache), falling back to Firestore.
    private func readBestEffortCurrentProfile(uid: String) async -> (String?, String?, String?) {
        // RTDB
        let r = Database.database().reference(withPath: "users/\(uid)")
        let rtdb: [String: Any]? = await withCheckedContinuation { cont in
            r.observeSingleEvent(of: .value) { snap in
                cont.resume(returning: snap.value as? [String: Any])
            }
        }
        if let d = rtdb {
            let name = (d["name"] as? String) ?? (d["displayName"] as? String)
            let username = (d["username"] as? String) ?? (d["handle"] as? String)
            let photo = (d["profileImageURL"] as? String) ?? (d["photoURL"] as? String)
            return (name, username, photo)
        }

        // Firestore
        do {
            let doc = try await Firestore.firestore().collection("users").document(uid).getDocument()
            let d = doc.data() ?? [:]
            let name = (d["name"] as? String) ?? (d["displayName"] as? String)
            let username = (d["username"] as? String) ?? (d["handle"] as? String)
            let photo = (d["profileImageURL"] as? String) ?? (d["photoURL"] as? String)
            return (name, username, photo)
        } catch {
            print("⚠️ Firestore get user failed: \(error.localizedDescription)")
            return (nil, nil, nil)
        }
    }

    // MARK: - Cloud Function: ensure defaults exist
    private func seedUserDefaultsIfNeeded() {
        guard Auth.auth().currentUser != nil else { return }
        functions.httpsCallable("ensureUserDefaults").call { result, error in
            if let error { print("❌ ensureUserDefaults error: \(error.localizedDescription)") }
            if let dict = result?.data as? [String: Any] {
                print("✅ ensureUserDefaults:", dict)
            }
        }
    }
}
