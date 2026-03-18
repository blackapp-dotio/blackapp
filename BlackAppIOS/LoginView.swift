import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import UIKit   // ⬅️ for UIPasteboard

struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel

    // MARK: - Modes
    private enum AuthMode: String, CaseIterable { case email = "Email", phone = "Phone" }
    @State private var mode: AuthMode = .email

    // MARK: - Email UI State
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var username = ""

    // MARK: - Phone UI State
    @State private var countryCode = "+1"
    @State private var phone = ""
    @State private var smsCode = ""
    @State private var verificationID: String?
    @State private var codeSent = false

    // MARK: - General UI State
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

    // Post-phone first-signin profile completion
    @State private var showCompleteProfileSheet = false
    @State private var cpName = ""
    @State private var cpUsername = ""
    @State private var cpError: String?

    // MARK: - EULA / Guidelines acceptance
    @State private var acceptedEULA_v1 = false
    private let eulaVersion = 1
    private let termsURL = URL(string: "https://blackapp.io/terms")!
    private let communityURL = URL(string: "https://blackapp.io/community")!

    private let db = Firestore.firestore()

    // MARK: - Body (scrollable + pinned action bar)
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    if showLogo {
                        Image("blackapp_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .opacity(showLogo ? 1 : 0)
                            .animation(.easeIn(duration: 1.0), value: showLogo)
                    }

                    // Mode toggle
                    Picker("", selection: $mode) {
                        ForEach(AuthMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .email {
                        emailForm
                    } else {
                        phoneForm
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if mode == .email {
                        Divider().padding(.vertical, 8)
                    }
                }
                .padding()
                // extra bottom space so content isn't hidden behind the pinned action bar
                .padding(.bottom, 140)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            showLogo = true
            //InviteAutoLinker.primeInviteCodeCapture()
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
        // ⬇️ Complete Profile sheet (first phone sign-in without name/username)
        .sheet(isPresented: $showCompleteProfileSheet) {
            CompleteProfileSheet(
                name: $cpName,
                username: $cpUsername,
                errorText: $cpError,
                onSave: { finalizePhoneFirstProfile() },
                onCancel: {
                    // if they cancel, sign out (cannot use app without profile)
                    try? Auth.auth().signOut()
                    showCompleteProfileSheet = false
                }
            )
        }
        // ⬇️ Pin the action row at the bottom so it never gets covered
        .safeAreaInset(edge: .bottom) {
            Group {
                if mode == .email {
                    emailActionBarPinned
                } else {
                    phoneActionBarPinned
                }
            }
            .background(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: -2)
        }
    }

    // MARK: - Email UI

    private var emailForm: some View {
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

            if isSignUpMode {
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

                // ⬇️ DOB (18+) during signup
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

                // ⬇️ EULA/Guidelines acceptance (required for signup)
                EULAAcceptanceBlock(
                    accepted: $acceptedEULA_v1,
                    termsURL: termsURL,
                    communityURL: communityURL
                )
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Phone UI

    private var phoneForm: some View {
        Group {
            HStack(spacing: 10) {
                TextField("+1", text: $countryCode)
                    .keyboardType(.phonePad)
                    .frame(width: 64)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)

                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
            }

            if codeSent {
                TextField("6-digit code", text: $smsCode)
                    .keyboardType(.numberPad)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
            }

            // ⬇️ Always show acceptance for phone auth (account may be created on first verify)
            EULAAcceptanceBlock(
                accepted: $acceptedEULA_v1,
                termsURL: termsURL,
                communityURL: communityURL
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Pinned action bars (bottom)

    private var emailActionBarPinned: some View {
        HStack(spacing: 12) {
            if isSignUpMode {
                Button("Back") { isSignUpMode = false }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
            } else {
                Button("Sign Up") { isSignUpMode = true }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
            }

            Spacer(minLength: 8)

            if isSignUpMode {
                Button {
                    startSignUp()
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Create Account")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || !acceptedEULA_v1)
            } else {
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
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var phoneActionBarPinned: some View {
        HStack {
            Button {
                if codeSent {
                    verifySMSCode()
                } else {
                    sendSMSCode()
                }
            } label: {
                HStack {
                    if isWorking { ProgressView().tint(.white) }
                    Text(codeSent ? "Verify & Sign In" : "Send Code")
                }
            }
            .buttonStyle(.borderedProminent)
            // ⬇️ Gate ONLY the verify step on acceptance (account creation happens at verify)
            .disabled(isWorking || !canProceedPhone || (codeSent && !acceptedEULA_v1))
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var canProceedPhone: Bool {
        let e164 = normalizePhone(countryCode: countryCode, number: phone)
        if !codeSent { return !e164.isEmpty }
        return !smsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Phone Auth Flow

    private func sendSMSCode() {
        errorMessage = ""
        let e164 = normalizePhone(countryCode: countryCode, number: phone)
        guard !e164.isEmpty else {
            errorMessage = "Enter a valid phone number."
            return
        }
        isWorking = true
        PhoneAuthProvider.provider().verifyPhoneNumber(e164, uiDelegate: nil) { verificationID, error in
            isWorking = false
            if let error = error {
                errorMessage = error.localizedDescription
                codeSent = false
            } else if let verificationID = verificationID {
                self.verificationID = verificationID
                self.codeSent = true
                self.infoToast = "Code sent to \(e164)"
            } else {
                errorMessage = "Failed to request code."
            }
        }
    }

    private func verifySMSCode() {
        errorMessage = ""
        guard let verID = verificationID else {
            errorMessage = "Missing verification. Tap ‘Send Code’ again."
            return
        }
        let code = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "Enter the SMS code."
            return
        }
        guard acceptedEULA_v1 else {
            errorMessage = "Please agree to the Terms and Guidelines to continue."
            return
        }
        isWorking = true
        let credential = PhoneAuthProvider.provider().credential(withVerificationID: verID, verificationCode: code)
        Auth.auth().signIn(with: credential) { _, err in
            if let err = err {
                isWorking = false
                errorMessage = err.localizedMessageOrDefault()
                return
            }

            // Mark phone account appropriately (exempt from email verification if phone-only)
            self.markPhoneVerifiedAccount {
                // Persist EULA acceptance immediately after the very first sign-in
                self.persistEULAAcceptanceIfNeeded(version: self.eulaVersion) {
                    // Continue bootstrap
                    self.isWorking = false
                    self.postPhoneSignInBootstrap()
                }
            }
        }
    }

    private func postPhoneSignInBootstrap() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let userRef = db.collection("users").document(uid)
        userRef.getDocument { snap, err in
            if let err = err {
                self.errorMessage = "Couldn’t load profile: \(err.localizedDescription)"
                try? Auth.auth().signOut()
                return
            }
            let data = snap?.data() ?? [:]
            let hasName = (data["name"] as? String)?.isEmpty == false
            let hasUsername = (data["username"] as? String)?.isEmpty == false
            let hasDOB = (data["dob"] as? Timestamp) != nil

            if !hasName || !hasUsername {
                // Collect name + username first
                self.cpName = ""
                self.cpUsername = ""
                self.showCompleteProfileSheet = true
            } else if !hasDOB {
                // Missing DOB — age gate
                self.ageGateContext = .postSignInCapture
                self.dateOfBirth = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
                self.showAgeGateSheet = true
            } else {
                // All good; run invite linker and toast
                self.infoToast = "Signed in ✅"
                InviteAutoLinker.linkInviterIfPresentAfterAuth { linked, msg in
                    if linked { self.infoToast = msg ?? "Invite linked 🎉" }
                }
            }
        }
    }

    private func finalizePhoneFirstProfile() {
        cpError = nil
        let cleanUsername = normalizeUsername(cpUsername)
        let trimmedName = cpName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { cpError = "Please enter your full name."; return }
        guard !cleanUsername.isEmpty else { cpError = "Username must have at least 3 letters or numbers."; return }

        isWorking = true
        let lowerName = trimmedName.lowercased()
        reserveNames(usernameLower: cleanUsername, nameLower: lowerName) { result in
            switch result {
            case .failure(let err):
                isWorking = false
                cpError = err.localizedDescription
            case .success:
                self.applyFirstPhoneProfile(name: trimmedName, usernameLower: cleanUsername, nameLower: lowerName)
            }
        }
    }

    private func applyFirstPhoneProfile(name: String, usernameLower: String, nameLower: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let usersRef     = db.collection("users").document(uid)
        let usernamesRef = db.collection("usernames").document(usernameLower)
        let displayRef   = db.collection("displaynames").document(nameLower)

        let batch = db.batch()
        batch.setData([
            "name": name,
            "nameLower": nameLower,
            "username": usernameLower,
            "usernameLower": usernameLower
        ], forDocument: usersRef, merge: true)
        batch.setData(["uid": uid], forDocument: usernamesRef, merge: true)
        batch.setData(["uid": uid], forDocument: displayRef, merge: true)

        batch.commit { err in
            self.isWorking = false
            if let err = err {
                self.cpError = "Couldn’t save profile: \(err.localizedDescription)"
            } else {
                self.showCompleteProfileSheet = false
                // Next: age gate if needed
                self.enforceAgeAfterAuth { allowed in
                    if allowed {
                        self.infoToast = "Signed in ✅"
                        InviteAutoLinker.linkInviterIfPresentAfterAuth { linked, msg in
                            if linked { self.infoToast = msg ?? "Invite linked 🎉" }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Email flows

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

        // Must accept EULA/Guidelines before account creation
        guard acceptedEULA_v1 else {
            errorMessage = "Please agree to the Terms and Guidelines to continue."
            return
        }

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
                authVM.signUp(email: self.email, password: self.password, name: self.name, username: cleanUsername) { error in
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

        // Store DOB + ageVerified18 + EULA acceptance at sign-up time
        let userPatch: [String: Any] = [
            "username": usernameLower,
            "usernameLower": usernameLower,
            "name": name,
            "nameLower": nameLower,
            "dob": Timestamp(date: dateOfBirth),
            "ageVerified18": true,
            "acceptedEULA_v1": true,
            "acceptedEULA_version": eulaVersion,
            "acceptedEULA_at": FieldValue.serverTimestamp(),
            "acceptedEULA_termsURL": termsURL.absoluteString,
            "acceptedEULA_guidelinesURL": communityURL.absoluteString,
            // Email flow defaults — email verification required
            "requiresEmailVerification": true,
            "emailVerificationExempt": false,
            "authProviders.email": true
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

    private func normalizePhone(countryCode: String, number: String) -> String {
        // naive E.164 normalizer: strips non-digits except leading +
        var cc = countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cc.hasPrefix("+") { cc = "+" + cc.replacingOccurrences(of: "+", with: "") }
        n = n.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return (cc + n)
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

    // MARK: - EULA persistence helper (phone-first signups)

    /// Ensures EULA acceptance is written to Firestore immediately after first sign-in (phone flow).
    private func persistEULAAcceptanceIfNeeded(version: Int, completion: @escaping () -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(); return }
        let userRef = db.collection("users").document(uid)
        userRef.getDocument { snap, _ in
            let already = (snap?.data()?["acceptedEULA_v1"] as? Bool) == true
            guard !already else { completion(); return }
            let patch: [String: Any] = [
                "acceptedEULA_v1": true,
                "acceptedEULA_version": version,
                "acceptedEULA_at": FieldValue.serverTimestamp(),
                "acceptedEULA_termsURL": termsURL.absoluteString,
                "acceptedEULA_guidelinesURL": communityURL.absoluteString
            ]
            userRef.setData(patch, merge: true) { _ in completion() }
        }
    }

    /// For phone-auth accounts, set email verification exemption appropriately.
    /// If the account is phone-only (no email/password provider), mark as exempt.
    /// If they also have email/password provider, require email verification.
    private func markPhoneVerifiedAccount(_ done: (() -> Void)? = nil) {
        guard let user = Auth.auth().currentUser else { done?(); return }
        let providers = user.providerData.map { $0.providerID }
        let hasEmailProvider = providers.contains("password") || providers.contains("email")
        let uid = user.uid

        var patch: [String: Any] = [
            "authProviders.phone": true
        ]

        if hasEmailProvider {
            patch["requiresEmailVerification"] = true
            patch["emailVerificationExempt"] = false
        } else {
            patch["requiresEmailVerification"] = false
            patch["emailVerificationExempt"] = true
        }

        db.collection("users").document(uid).setData(patch, merge: true) { _ in done?() }
    }
}

// MARK: - EULA/Guidelines block

private struct EULAAcceptanceBlock: View {
    @Binding var accepted: Bool
    let termsURL: URL
    let communityURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $accepted) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("I have read and agree to the Terms of Service and Community Guidelines.")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("BlackApp has zero tolerance for objectionable content or abusive users.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 16) {
                Link("View Terms", destination: termsURL)
                Link("Community Guidelines", destination: communityURL)
            }
            .font(.footnote)
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Age Gate Sheet UI (unchanged)

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

// MARK: - Complete Profile Sheet (for first phone sign-in)

private struct CompleteProfileSheet: View {
    @Binding var name: String
    @Binding var username: String
    @Binding var errorText: String?

    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Profile")) {
                    TextField("Full Name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)

                    Text("Usernames are unique. Only letters & numbers; we’ll lowercase it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let e = errorText, !e.isEmpty {
                    Section {
                        Text(e).foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: onSave) {
                        Text("Save")
                    }
                    Button(role: .destructive, action: onCancel) {
                        Text("Cancel")
                    }
                }
            }
            .navigationTitle("Complete Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Invite auto-capture & post-auth linker (unchanged)

/*fileprivate enum InviteAutoLinker {

    // Store inviter UID captured from invite link
    private static let kInviterKey = "pending_inviter_uid"
    private static let kSavedAtKey = "pending_inviter_saved_at"
    private static let ttlHours: Double = 72

    // Call this when app opens from: https://blackapp.io/invite?ref=<uid>
    static func captureInviterUidFromURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let ref = comps.queryItems?.first(where: { $0.name.lowercased() == "ref" })?.value ?? ""
        let inviterUid = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inviterUid.isEmpty else { return }

        let ud = UserDefaults.standard
        ud.set(inviterUid, forKey: kInviterKey)
        ud.set(Date().timeIntervalSince1970, forKey: kSavedAtKey)
        ud.synchronize()
        print("🔗 [Invite] cached inviterUid \(inviterUid)")
    }

    // After auth, attribute invite via Cloud Function (idempotent on backend)
    static func linkInviterIfPresentAfterAuth(completion: ((Bool, String?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else { completion?(false, nil); return }
        guard let inviterUid = freshCachedInviterUid(), !inviterUid.isEmpty else {
            completion?(false, nil)
            return
        }
        if inviterUid == me {
            clearCache()
            completion?(false, "Invite ignored (self-referral)")
            return
        }

        // Get Firebase ID token (required by your Cloud Function)
        Auth.auth().currentUser?.getIDTokenForcingRefresh(true) { token, err in
            if let err = err {
                print("❌ [Invite] failed to get ID token: \(err.localizedDescription)")
                completion?(false, "Invite link found but couldn’t authenticate.")
                return
            }
            guard let token = token, !token.isEmpty else {
                completion?(false, "Invite link found but token missing.")
                return
            }

            guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/claimInviteReferral") else {
                completion?(false, "Invalid invite endpoint.")
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["inviterUid": inviterUid]

            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                completion?(false, "Couldn’t encode invite request.")
                return
            }

            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error = error {
                    print("❌ [Invite] claimInviteReferral network error:", error.localizedDescription)
                    completion?(false, "Invite link found but network failed.")
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    completion?(false, "Invite link found but response invalid.")
                    return
                }

                guard let data = data else {
                    completion?(false, "Invite link found but no response data.")
                    return
                }

                let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]

                if http.statusCode == 200, (json?["ok"] as? Bool) == true {
                    let already = (json?["alreadyClaimed"] as? Bool) == true
                    clearCache()
                    completion?(true, already ? "Invite already linked ✅" : "Invite linked 🎉")
                } else {
                    let msg = (json?["error"] as? String) ?? "Invite claim failed."
                    print("❌ [Invite] claimInviteReferral failed:", http.statusCode, msg)
                    completion?(false, msg)
                }
            }.resume()
        }
    }

    private static func freshCachedInviterUid() -> String? {
        let ud = UserDefaults.standard
        guard let inviter = ud.string(forKey: kInviterKey), !inviter.isEmpty else { return nil }
        let savedAt = ud.double(forKey: kSavedAtKey)
        guard savedAt > 0 else { return inviter }
        let ageHrs = (Date().timeIntervalSince1970 - savedAt) / 3600.0
        if ageHrs <= ttlHours { return inviter }
        clearCache()
        return nil
    }

    private static func clearCache() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: kInviterKey)
        ud.removeObject(forKey: kSavedAtKey)
        ud.synchronize()
    }
}
*/
// MARK: - Small convenience
fileprivate extension Error {
    func localizedMessageOrDefault() -> String {
        let msg = (self as NSError).userInfo[NSLocalizedDescriptionKey] as? String
        return msg?.isEmpty == false ? msg! : self.localizedDescription
    }
}
