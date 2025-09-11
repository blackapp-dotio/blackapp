import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UIKit   // ⬅️ for UIPasteboard

struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel

    // MARK: - UI State
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var username = ""
    @State private var errorMessage = ""
    @State private var showLogo = false
    @State private var isSignUpMode = false
    @State private var isWorking = false
    @State private var infoToast: String? = nil

    // Age-gating state
    @State private var dateOfBirth: Date = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var showAgeGateSheet = false
    private enum AgeGateContext: Equatable { case duringSignup, postSignInCapture }
    @State private var ageGateContext: AgeGateContext? = nil

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

                    // ⬇️ NEW: DOB (18+) during signup
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Date of Birth (18+)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        DatePicker("Date of Birth",
                                   selection: $dateOfBirth,
                                   in: ...Date(),
                                   displayedComponents: .date)
                            .datePickerStyle(.wheel)
                            .labelsHidden()

                        Text("You must be 18 or older to create an account.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
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
        // ⬇️ Age Gate sheet (post-sign-in capture if missing DOB)
        .sheet(isPresented: $showAgeGateSheet) {
            AgeGateSheet(
                dob: $dateOfBirth,
                onConfirm: { confirmAgeGateAfterSignIn() },
                onCancel: { cancelAgeGateAfterSignIn() }
            )
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
                // Enforce 18+ (and backfill DOB if missing)
                enforceAgeAfterAuth { allowed in
                    if allowed {
                        infoToast = "Signed in ✅"
                        InviteAutoLinker.linkInviterIfPresentAfterAuth { linked, msg in
                            if linked { infoToast = msg ?? "Invite linked 🎉" }
                        }
                    }
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
        // ⬇️ Enforce 18+ at sign-up
        guard is18Plus(dob: dateOfBirth) else {
            errorMessage = "You must be 18 or older to sign up."
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
                        // 3b) Finalize profile + send verification email
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

    private func reserveNames(usernameLower: String, nameLower: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)

        db.runTransaction({ (txn, errorPointer) -> Any? in
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

            txn.setData(["reservedAt": FieldValue.serverTimestamp(), "uid": ""], forDocument: usernamesRef)
            txn.setData(["reservedAt": FieldValue.serverTimestamp(), "uid": ""], forDocument: displayRef)
            return nil
        }) { _, error in
            if let error = error { completion(.failure(error)) }
            else { completion(.success(())) }
        }
    }

    private func rollbackReservations(usernameLower: String, nameLower: String, completion: @escaping () -> Void) {
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)
        let batch = db.batch()
        batch.deleteDocument(usernamesRef)
        batch.deleteDocument(displayRef)
        batch.commit { _ in completion() }
    }

    private func finalizeSignup(usernameLower: String, nameLower: String) {
        guard let user = Auth.auth().currentUser else {
            isWorking = false
            infoToast = "Signed up, but couldn’t finalize profile."
            return
        }
        let uid = user.uid

        let usersRef     = db.collection("users").document(uid)
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)

        // Store DOB + ageVerified18 at sign-up time (already validated 18+)
        let userPatch: [String: Any] = [
            "username": usernameLower,
            "usernameLower": usernameLower,
            "name": name,
            "nameLower": nameLower,
            "dob": Timestamp(date: dateOfBirth),
            "ageVerified18": true
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
                sendVerificationEmailIfNeeded()
                infoToast = "Signed up ✅ Check your email to verify"
                isSignUpMode = false

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

    // MARK: - Email verification

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

    // MARK: - 18+ Enforcement (sign-in & backfill)

    /// After a successful sign-in, ensure we either (a) have a DOB and it is 18+, or (b) collect DOB now.
    private func enforceAgeAfterAuth(completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(false)
            return
        }
        db.collection("users").document(uid).getDocument { snap, err in
            if let err = err {
                self.errorMessage = "Couldn’t load profile: \(err.localizedDescription)"
                try? Auth.auth().signOut()
                completion(false)
                return
            }
            let data = snap?.data() ?? [:]
            if let ts = data["dob"] as? Timestamp {
                let dob = ts.dateValue()
                if self.is18Plus(dob: dob) {
                    completion(true)
                } else {
                    self.errorMessage = "You must be 18 or older to use BlackApp."
                    try? Auth.auth().signOut()
                    completion(false)
                }
            } else {
                // Missing DOB — block with an age-gate sheet
                self.ageGateContext = .postSignInCapture
                self.dateOfBirth = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
                self.showAgeGateSheet = true
                completion(false)
            }
        }
    }

    /// Persist DOB + ageVerified18 on the user document.
    private func persistDOB(_ dob: Date, completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(false); return
        }
        let patch: [String: Any] = [
            "dob": Timestamp(date: dob),
            "ageVerified18": true
        ]
        db.collection("users").document(uid).setData(patch, merge: true) { err in
            if let err = err {
                self.errorMessage = "Couldn’t save DOB: \(err.localizedDescription)"
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    /// Strict 18+ check.
    private func is18Plus(dob: Date) -> Bool {
        let eighteenth = Calendar.current.date(byAdding: .year, value: 18, to: dob)!
        return Date() >= eighteenth
    }

    /// Called when user confirms DOB in the post-sign-in age gate.
    private func confirmAgeGateAfterSignIn() {
        guard ageGateContext == .postSignInCapture else { return }
        if is18Plus(dob: dateOfBirth) {
            persistDOB(dateOfBirth) { ok in
                if ok {
                    self.showAgeGateSheet = false
                    self.infoToast = "Age verified ✅"
                } else {
                    try? Auth.auth().signOut()
                    self.showAgeGateSheet = false
                }
            }
        } else {
            errorMessage = "You must be 18 or older to use BlackApp."
            try? Auth.auth().signOut()
            showAgeGateSheet = false
        }
    }

    /// If user cancels DOB capture, sign them out (cannot bypass).
    private func cancelAgeGateAfterSignIn() {
        try? Auth.auth().signOut()
        showAgeGateSheet = false
    }
}

// MARK: - Age Gate Sheet UI

private struct AgeGateSheet: View {
    @Binding var dob: Date
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Age Verification")
                    .font(.title2).bold()
                    .padding(.top)

                Text("You must be 18 or older to use BlackApp. Please enter your date of birth.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                DatePicker("Date of Birth",
                           selection: $dob,
                           in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding(.vertical)

                Button(action: onConfirm) {
                    Text("Confirm Age")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(role: .destructive, action: onCancel) {
                    Text("Sign Out")
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationBarHidden(true)
        }
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Invite auto-capture & post-auth linker (unchanged)

fileprivate enum InviteAutoLinker {
    private static let kCodeKey = "pending_invite_code"
    private static let kSavedAtKey = "pending_invite_saved_at"
    private static let ttlHours: Double = 48
    private static let regex = try! NSRegularExpression(pattern: #"BA-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{7}"#, options: [])

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

    static func linkInviterIfPresentAfterAuth(completion: ((Bool, String?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion?(false, nil); return
        }
        guard let code = freshCachedCode() else {
            completion?(false, nil); return
        }

        let fs = Firestore.firestore()
        let meRef = fs.collection("users").document(me)

        meRef.getDocument { meDoc, _ in
            if let meDoc, let data = meDoc.data(), data["referrer"] != nil {
                clearCache()
                completion?(false, "Invite already linked")
                return
            }

            fs.collection("inviteCodes").document(code).getDocument { snap, _ in
                guard let inviter = snap?.data()?["uid"] as? String, !inviter.isEmpty, inviter != me else {
                    clearCache()
                    completion?(false, "Invalid invite code")
                    return
                }

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
