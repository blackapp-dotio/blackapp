import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UIKit   // ⬅️ added for UIPasteboard

struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel
    
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var username = ""
    @State private var errorMessage = ""
    @State private var showLogo = false
    @State private var isSignUpMode = false
    @State private var isWorking = false
    @State private var infoToast: String? = nil
    
    private let db = Firestore.firestore()
    
    var body: some View {
        VStack(spacing: 16) {
            if showLogo {
                Image("blackapp_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .opacity(showLogo ? 1 : 0)
                    .animation(.easeIn(duration: 1.0), value: showLogo)
            }
            
            Group {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                
                SecureField("Password", text: $password)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                
                if !isSignUpMode {
                    Button("Forgot password?") { sendPasswordReset() }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.bottom, 4)
                }
            }
            
            if isSignUpMode {
                Group {
                    TextField("Full Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                    
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                    
                    Text("Usernames are unique. Only letters & numbers; we’ll lowercase it.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack {
                Button(isSignUpMode ? "Back to Sign In" : "Sign Up") {
                    if isSignUpMode {
                        startSignUp()
                    } else {
                        isSignUpMode = true
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                
                if !isSignUpMode {
                    Button {
                        startSignIn()
                    } label: {
                        HStack {
                            if isWorking { ProgressView().tint(.white) }
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                }
            }
            
            Divider().padding(.vertical, 8)
            
            // (Google sign-in button left commented in your original file)
        }
        .padding()
        .onAppear {
            showLogo = true
            // ⬅️ NEW: auto-capture invite code from clipboard at screen appear
            InviteAutoLinker.primeInviteCodeCapture()
        }
        .overlay(alignment: .top) {
            if let toast = infoToast {
                Text(toast)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { infoToast = nil }
                    }
            }
        }
    }
    
    // MARK: - Auth flows
    
    private func startSignIn() {
        errorMessage = ""
        guard validateEmailAndPassword() else { return }
        isWorking = true
        authVM.signIn(email: email, password: password) { error in
            isWorking = false
            if let error = error {
                errorMessage = error.localizedDescription
            } else {
                infoToast = "Signed in ✅"
                // ⬅️ NEW: after auth, resolve + link inviter if a code is cached
                InviteAutoLinker.linkInviterIfPresentAfterAuth { linked, msg in
                    if linked { infoToast = msg ?? "Invite linked 🎉" }
                }
            }
        }
    }
    
    private func startSignUp() {
        errorMessage = ""
        guard validateEmailAndPassword() else { return }
        
        // Basic name/username validation
        let cleanUsername = normalizeUsername(username)
        let cleanNameLower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter your full name."
            return
        }
        guard !cleanUsername.isEmpty else {
            errorMessage = "Username must have at least 3 letters or numbers."
            return
        }
        
        isWorking = true
        
        // 1) Reserve username + display name atomically (non-throwing txn)
        reserveNames(usernameLower: cleanUsername, nameLower: cleanNameLower) { result in
            switch result {
            case .failure(let err):
                isWorking = false
                errorMessage = err.localizedDescription
            case .success:
                // 2) Proceed with sign-up
                authVM.signUp(email: email, password: password, name: name, username: cleanUsername) { error in
                    if let error = error {
                        // 3a) Rollback reservations on failure
                        rollbackReservations(usernameLower: cleanUsername, nameLower: cleanNameLower) {
                            isWorking = false
                            errorMessage = error.localizedDescription
                        }
                    } else {
                        // 3b) Finalize: stamp user doc + reservations with uid and send verification email
                        finalizeSignup(usernameLower: cleanUsername, nameLower: cleanNameLower)
                    }
                }
            }
        }
    }
    
    // MARK: - Forgot password
    
    private func sendPasswordReset() {
        errorMessage = ""
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmed) else {
            errorMessage = "Enter a valid email to reset your password."
            return
        }
        Auth.auth().sendPasswordReset(withEmail: trimmed) { err in
            if let err = err {
                errorMessage = err.localizedDescription
            } else {
                infoToast = "Password reset email sent 📬"
            }
        }
    }
    
    // MARK: - Reservations (Firestore)
    
    /// Create `usernames/{usernameLower}` and `displaynames/{nameLower}` if they don't exist (atomic).
    private func reserveNames(usernameLower: String, nameLower: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)
        
        db.runTransaction({ (txn, errorPointer) -> Any? in
            // Fetch docs
            do {
                let uDoc = try txn.getDocument(usernamesRef)
                if uDoc.exists {
                    let err = NSError(domain: "signup", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Username is taken. Try another."])
                    errorPointer?.pointee = err
                    return nil
                }
                let nDoc = try txn.getDocument(displayRef)
                if nDoc.exists {
                    let err = NSError(domain: "signup", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Display name is taken. Try another."])
                    errorPointer?.pointee = err
                    return nil
                }
            } catch let fetchError as NSError {
                errorPointer?.pointee = fetchError
                return nil
            }
            
            // Reserve both
            txn.setData(["reservedAt": FieldValue.serverTimestamp(), "uid": ""], forDocument: usernamesRef)
            txn.setData(["reservedAt": FieldValue.serverTimestamp(), "uid": ""], forDocument: displayRef)
            return nil
        }) { _, error in
            if let error = error { completion(.failure(error)) }
            else { completion(.success(())) }
        }
    }
    
    /// Delete both reservations if sign-up fails.
    private func rollbackReservations(usernameLower: String, nameLower: String, completion: @escaping () -> Void) {
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)
        let batch = db.batch()
        batch.deleteDocument(usernamesRef)
        batch.deleteDocument(displayRef)
        batch.commit { _ in completion() }
    }
    
    /// On success, stamp user doc and fill reservations with real uid. Also send verification email if needed.
    private func finalizeSignup(usernameLower: String, nameLower: String) {
        guard let user = Auth.auth().currentUser else {
            isWorking = false
            infoToast = "Signed up, but couldn’t finalize profile."
            return
        }
        let uid = user.uid
        
        let usersRef = db.collection("users").document(uid)
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)
        
        let userPatch: [String: Any] = [
            "username": usernameLower,
            "usernameLower": usernameLower,
            "name": name,
            "nameLower": nameLower
        ]
        
        let batch = db.batch()
        batch.setData(userPatch, forDocument: usersRef, merge: true)
        batch.setData(["uid": uid], forDocument: usernamesRef, merge: true)
        batch.setData(["uid": uid], forDocument: displayRef, merge: true)
        batch.commit { err in
            isWorking = false
            if let err = err {
                errorMessage = "Profile finalize failed: \(err.localizedDescription)"
            } else {
                // Send email verification (non-blocking)
                sendVerificationEmailIfNeeded()
                infoToast = "Signed up ✅ Check your email to verify"
                isSignUpMode = false

                // ⬅️ NEW: after sign-up completes, resolve + link inviter if cached
                InviteAutoLinker.linkInviterIfPresentAfterAuth { linked, msg in
                    if linked { infoToast = msg ?? "Invite linked 🎉" }
                }
            }
        }
    }
    
    // MARK: - Validation & helpers
    
    private func validateEmailAndPassword() -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isValidEmail(trimmedEmail) {
            errorMessage = "Please enter a valid email address."
            return false
        }
        if password.count < 6 {
            errorMessage = "Password must be at least 6 characters."
            return false
        }
        return true
    }
    
    private func normalizeUsername(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
        let cleaned = lowered.unicodeScalars.filter { allowed.contains($0) }
        let s = String(String.UnicodeScalarView(cleaned))
        return s.count >= 3 ? s : ""
    }
    
    private func isValidEmail(_ str: String) -> Bool {
        let pattern = #"^\S+@\S+\.\S+$"#
        return str.range(of: pattern, options: .regularExpression) != nil
    }
    
    // MARK: - Email verification (with ActionCodeSettings + logs)
    
    private func sendVerificationEmailIfNeeded() {
        guard let user = Auth.auth().currentUser else {
            print("🔔 sendVerificationEmailIfNeeded: no current user")
            return
        }
        guard !user.isEmailVerified else {
            print("🔔 sendVerificationEmailIfNeeded: already verified")
            return
        }
        
        Auth.auth().useAppLanguage()
        
        let acs = makeActionCodeSettings()
        let emailLog = user.email ?? "(no email)"
        
        user.sendEmailVerification(with: acs) { error in
            if let error = error {
                print("❌ sendEmailVerification failed for \(emailLog): \(error.localizedDescription)")
                errorMessage = "Couldn’t send verification email: \(error.localizedDescription)"
            } else {
                print("✅ Verification email sent to \(emailLog)")
                infoToast = "Verification email sent 📬"
            }
        }
    }
    
    private func makeActionCodeSettings() -> ActionCodeSettings {
        let acs = ActionCodeSettings()
        acs.url = URL(string: "https://blackappios.web.app/verify")
        acs.handleCodeInApp = false
        if let bundleId = Bundle.main.bundleIdentifier {
            acs.setIOSBundleID(bundleId)
        }
        return acs
    }
}

// MARK: - Invite auto-capture & post-auth linker (NEW)
fileprivate enum InviteAutoLinker {
    // Storage keys
    private static let kCodeKey = "pending_invite_code"
    private static let kSavedAtKey = "pending_invite_saved_at"
    // Accept codes copied within this TTL (hours)
    private static let ttlHours: Double = 48
    // Strict code format used by your Functions: BA- + 7 chars (no 0/1/O/I)
    private static let regex = try! NSRegularExpression(pattern: #"BA-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{7}"#, options: [])
    
    /// Capture an invite code from the clipboard and cache it with a timestamp.
    static func primeInviteCodeCapture() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let full = text as NSString
        if let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: full.length)) {
            let code = full.substring(with: m.range)
            let ud = UserDefaults.standard
            if ud.string(forKey: kCodeKey) != code {
                ud.set(code, forKey: kCodeKey)
                ud.set(Date().timeIntervalSince1970, forKey: kSavedAtKey)
                ud.synchronize()
                print("🔗 [Invite] cached code \(code)")
            }
        }
    }
    
    /// If a fresh code is cached and user is authed, resolve to inviter and set users/{me}.referrer.
    static func linkInviterIfPresentAfterAuth(completion: ((Bool, String?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion?(false, nil); return
        }
        guard let code = freshCachedCode() else {
            completion?(false, nil); return
        }
        
        let fs = Firestore.firestore()
        let meRef = fs.collection("users").document(me)
        
        // Check if referrer already set; if yes, just clear cache and exit.
        meRef.getDocument { meDoc, _ in
            if let meDoc, let data = meDoc.data(), data["referrer"] != nil {
                clearCache()
                completion?(false, "Invite already linked")
                return
            }
            
            // Resolve code -> inviter uid
            fs.collection("inviteCodes").document(code).getDocument { snap, _ in
                guard let inviter = snap?.data()?["uid"] as? String, !inviter.isEmpty, inviter != me else {
                    clearCache()
                    completion?(false, "Invalid invite code")
                    return
                }
                
                // Write referrer (Cloud Function will take it from here)
                meRef.setData(["referrer": inviter], merge: true) { err in
                    if let err = err {
                        print("❌ [Invite] failed to set referrer: \(err.localizedDescription)")
                        completion?(false, "Couldn’t link invite")
                    } else {
                        clearCache()
                        print("✅ [Invite] linked referrer \(inviter)")
                        completion?(true, "Invite linked 🎉")
                    }
                }
            }
        }
    }
    
    // Helpers
    private static func freshCachedCode() -> String? {
        let ud = UserDefaults.standard
        guard let code = ud.string(forKey: kCodeKey), !code.isEmpty else { return nil }
        let savedAt = ud.double(forKey: kSavedAtKey)
        guard savedAt > 0 else { return code }
        let ageHrs = (Date().timeIntervalSince1970 - savedAt) / 3600.0
        if ageHrs <= ttlHours { return code }
        clearCache()
        return nil
    }
    
    private static func clearCache() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: kCodeKey)
        ud.removeObject(forKey: kSavedAtKey)
        ud.synchronize()
    }
}
