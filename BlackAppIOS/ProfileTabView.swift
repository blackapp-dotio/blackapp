// ProfileTabView.swift — Social sync + star badge + AG Dashboard (hardcoded superadmin)
// Star Power is driven ONLY by inviteCount (RTDB users/{uid}/inviteCount)

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import SDWebImageSwiftUI

// Hardcoded superadmin UID (still respects DB roles too)
private let SUPERADMIN_UID = "XszTTDbebpcYjiqYqgQPAlxWEs82"

struct ProfileTabView: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var showProfileValidationError = false
    @State private var profileValidationMessage = ""
    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var profileImage: UIImage? = nil
    @State private var profileImageURL: String? = nil
    @State private var showImagePicker = false
    @State private var brands: [BrandModel] = []
    // 💸 BlackAppMoney (Stripe Connect)
    @State private var showBlackAppMoney = false
    @State private var stripeAccountId: String = ""
    @State private var stripeConnected: Bool = false

    // Admin / superadmin gate for AGDashboard
    @State private var isAdmin = false

    @State private var isEditingProfile = false

    @State private var syncedAccounts: [SyncedAccount] = [
        SyncedAccount(platform: "Instagram", handle: nil),
        SyncedAccount(platform: "Twitter", handle: nil),
        SyncedAccount(platform: "Facebook", handle: nil),
        SyncedAccount(platform: "TikTok", handle: nil),
        SyncedAccount(platform: "YouTube", handle: nil)
    ]

    @State private var selectedPlatform: String? = nil
    @State private var handleInput: String = ""
    @State private var showInputPrompt = false

    // ⭐️ Star Power (LIVE) — inviteCount only
    @State private var inviteCount: Int = 0
    @State private var badgeTier: String = "white"   // optional; if missing, we derive from inviteCount
    @State private var showAllBadges: Bool = false

    // RTDB observers
    @State private var inviteRef: DatabaseReference?
    @State private var inviteHandle: DatabaseHandle?
    @State private var badgeRef: DatabaseReference?
    @State private var badgeHandle: DatabaseHandle?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
               /* TopToolbarView(onLogoTap: {}, onSearchTap: {})
                    .padding(.horizontal)
                    .frame(height: 60)
*/
                ScrollView {
                    VStack(spacing: 20) {
                        profileSection
                        createBrandSection
                        brandSection
                        socialPlatformSyncSection
                        userWallSection
                        signOutSection(authVM: authVM)
                    }
                    .padding(.bottom, 80)
                }
                .onTapGesture { hideKeyboard() }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if isAdmin {
                            NavigationLink(destination: AGDashboardView()) {
                                Image("ag-global-logo")
                                    .resizable()
                                    .renderingMode(.original)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .shadow(radius: 3)
                                    .accessibilityLabel("AG Dashboard")
                            }
                        }

                        // ⚙️ Settings button (posts .openSettings so MainTabView opens the Settings sheet)
                        Button {
                            NotificationCenter.default.post(name: .openSettings, object: nil)
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .imageScale(.large)
                                .foregroundColor(.white)
                                .accessibilityLabel("Settings")
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            fetchProfile()
            fetchBrands()
            checkIfAdminHardAndSoft()
            loadSyncedAccounts()
            startObservingStarPower()
        }
        .onDisappear {
            stopObservingStarPower()
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $profileImage)
        }
        .sheet(isPresented: $showInputPrompt) {
            VStack(spacing: 20) {
                Text("Enter your \(selectedPlatform ?? "") handle")
                    .font(.title3)
                    .padding(.top)

                TextField("@yourHandle", text: $handleInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Button("Save") {
                    if let selected = selectedPlatform,
                       let index = syncedAccounts.firstIndex(where: { $0.platform == selected }) {
                        syncedAccounts[index].handle = handleInput
                        saveHandleToFirebase(platform: selected, handle: handleInput)
                    }
                    showInputPrompt = false
                }
                .padding()
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    showInputPrompt = false
                }
                .foregroundColor(.red)
                .padding(.bottom)
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        VStack(spacing: 12) {
            // Avatar
            if let image = profileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(radius: 10)
            } else if let imageURL = profileImageURL, let url = URL(string: imageURL) {
                WebImage(url: url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(radius: 10)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .foregroundColor(.gray)
                    .shadow(radius: 10)
            }

            if isEditingProfile {
                Button("Change Profile Picture") {
                    showImagePicker = true
                }
                .font(.subheadline)
                .foregroundColor(.blue)

                TextField("Name", text: $name)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                TextEditor(text: $bio)
                    .frame(height: 100)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)

                Button("Save") {
                    validateAndSaveProfile()
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)

            } else {
                // 🟡 Name + star badge (inviteCount-driven)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(name.isEmpty ? "Unnamed" : name)
                            .font(.title2)
                            .foregroundColor(.white)
                            .fontWeight(.bold)

                        // Stored badgeTier is allowed, but inviteCount-derived tier always wins if higher
                        let currentTier = effectiveBadgeTier(inviteCount: inviteCount, storedTier: badgeTier)

                        ProfileStarBadgeInline(tier: currentTier, inviteCount: inviteCount)
                            .onTapGesture {
                                withAnimation(.easeInOut) { showAllBadges.toggle() }
                            }
                    }

                    if showAllBadges {
                        ProfileStarBadgeProgressRow(inviteCount: inviteCount)
                            .transition(.opacity)
                    }

                    // Optional: show the count (helpful for clarity; remove if you don’t want it)
                    Text("\(inviteCount) invites")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.top, 2)
                }

                Text(bio.isEmpty ? "No bio added yet." : bio)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Edit Profile") {
                    withAnimation { isEditingProfile = true }
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
        .padding(.top)
        .frame(maxWidth: .infinity)
    }

    private var createBrandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a Brand")
                .font(.headline)
                .foregroundColor(.white)
            NavigationLink(destination: CreateBrandView()) {
                Label("Start Here", systemImage: "plus.circle")
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
    }

    private var brandSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Your Brands")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            ForEach(brands) { brand in
                NavigationLink(destination: BrandDashboardView(brand: brand)) {
                    HStack {
                        if let logoURL = URL(string: brand.logoURL ?? "") {
                            WebImage(url: logoURL)
                                .resizable()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "building.2.crop.circle")
                                .resizable()
                                .frame(width: 40, height: 40)
                        }

                        Text(brand.name)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private var socialPlatformSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected Social Platforms")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 24) {
                ForEach(0..<syncedAccounts.count, id: \.self) { index in
                    let account = syncedAccounts[index]
                    Button(action: {
                        selectedPlatform = account.platform
                        handleInput = account.handle ?? ""
                        showInputPrompt = true
                    }) {
                        Image(systemName: account.iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .foregroundColor(account.isLinked ? .green : .gray)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.2)))
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var userWallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            UserWallView(userId: Auth.auth().currentUser?.uid ?? "")
        }
        .padding(.horizontal)
    }

    // MARK: - Star Power (InviteCount) Live Observers

    private func startObservingStarPower() {
        guard let uid = authVM.user?.uid else { return }

        let uref = Database.database().reference().child("users").child(uid)

        // inviteCount is the ONLY star power driver
        let iRef = uref.child("inviteCount")
        inviteRef = iRef
        inviteHandle = iRef.observe(.value) { snap in
            let val: Int = {
                if let n = snap.value as? NSNumber { return n.intValue }
                if let n = snap.value as? Int { return n }
                return 0
            }()
            DispatchQueue.main.async { self.inviteCount = val }
        }

        // badgeTier (optional; derived tier will win if higher)
        let bRef = uref.child("badgeTier")
        badgeRef = bRef
        badgeHandle = bRef.observe(.value) { snap in
            DispatchQueue.main.async {
                if let s = snap.value as? String, !s.isEmpty {
                    self.badgeTier = s
                } else {
                    self.badgeTier = "white"
                }
            }
        }
    }

    private func stopObservingStarPower() {
        if let ref = inviteRef, let handle = inviteHandle { ref.removeObserver(withHandle: handle) }
        if let ref = badgeRef,  let handle = badgeHandle  { ref.removeObserver(withHandle: handle) }
        inviteRef = nil; inviteHandle = nil
        badgeRef  = nil; badgeHandle  = nil
    }

    // MARK: - Profile CRUD / helpers

    private func saveHandleToFirebase(platform: String, handle: String) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users/\(userId)/syncedPlatforms/\(platform)")
        ref.setValue(["linked": true, "handle": handle])
    }

    private func loadSyncedAccounts() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users/\(userId)/syncedPlatforms")
        ref.observeSingleEvent(of: .value) { snapshot in
            for case let child as DataSnapshot in snapshot.children {
                let platform = child.key
                if let dict = child.value as? [String: Any],
                   let handle = dict["handle"] as? String,
                   let index = syncedAccounts.firstIndex(where: { $0.platform == platform }) {
                    syncedAccounts[index].handle = handle
                }
            }
        }
    }

    private func validateAndSaveProfile() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            profileValidationMessage = "Please add your name before saving your profile."
            showProfileValidationError = true
            return
        }

        // We must inspect existing photo from RTDB to decide if completely missing
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let rtdbRef = Database.database().reference().child("users").child(uid)

        rtdbRef.observeSingleEvent(of: .value) { snapshot in
            let existing = snapshot.value as? [String: Any] ?? [:]
            let existingPhoto = (existing["profileImageURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // If no existing photo AND no newly picked image => block
            if existingPhoto.isEmpty && profileImage == nil {
                profileValidationMessage = "Please add a profile picture before saving your profile."
                showProfileValidationError = true
                return
            }

            // If we reach here, validation passed → proceed with actual save
            saveProfile(existingSnapshot: existing, existingPhoto: existingPhoto)
            withAnimation { isEditingProfile = false }
        }
    }

    /// Actual save logic, now receives existing profile snapshot + photo URL.
    /// This is mostly your original saveProfile, just refactored a bit.
    private func saveProfile(existingSnapshot existing: [String: Any], existingPhoto: String?) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let rtdbRef = Database.database().reference().child("users").child(uid)
        let fsRef   = Firestore.firestore().collection("users").document(uid)

        let existingUsername = (existing["username"] as? String)

        let derivedFallback = self.deriveUsername(fromName: self.name, uid: uid)
        let baseUsername = (existingUsername?.isEmpty == false ? existingUsername! : derivedFallback)
        let cleanUsername = baseUsername.replacingOccurrences(of: " ", with: "")
        let nameLower = self.name.lowercased()
        let usernameLower = cleanUsername.lowercased()

        func finishWrite(using finalPhotoURL: String?) {
            var doc: [String: Any] = [
                "name": self.name,
                "bio": self.bio,
                "username": cleanUsername,
                "profileImageURL": finalPhotoURL ?? existingPhoto ?? "",
                "nameLower": nameLower,
                "usernameLower": usernameLower
            ]

            // Firestore (merge)
            fsRef.setData(doc, merge: true) { err in
                if let err = err { print("❌ Firestore profile update failed: \(err.localizedDescription)") }
            }

            // RTDB update
            rtdbRef.updateChildValues(doc) { error, _ in
                if let error = error {
                    print("❌ RTDB profile update failed: \(error.localizedDescription)")
                } else {
                    print("✅ Profile saved (RTDB + Firestore) with normalized fields.")
                }
            }
        }

        // Upload image only if you picked a new one; else reuse existing
        guard let image = self.profileImage else {
            finishWrite(using: existingPhoto)
            return
        }

        guard let data = image.jpegData(compressionQuality: 0.82) else {
            print("⚠️ Couldn’t encode JPEG; keeping previous photo.")
            finishWrite(using: existingPhoto)
            return
        }

        let storageRef = Storage.storage().reference().child("profile_images/\(uid).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"

        storageRef.putData(data, metadata: meta) { _, uploadError in
            if let uploadError = uploadError {
                print("❌ Avatar upload failed: \(uploadError.localizedDescription)")
                finishWrite(using: existingPhoto)
                return
            }
            storageRef.downloadURL { url, _ in
                finishWrite(using: url?.absoluteString ?? existingPhoto)
            }
        }
    }


    private func deriveUsername(fromName name: String, uid: String) -> String {
        if let email = Auth.auth().currentUser?.email,
           let handle = email.split(separator: "@").first, !handle.isEmpty {
            return String(handle)
        }
        let allowed = CharacterSet.alphanumerics
        let base = name.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined()
        if base.count >= 3 { return base }
        return (base.isEmpty ? "user" : base) + String(uid.suffix(6)).lowercased()
    }

    private func fetchProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                self.name = value["name"] as? String ?? ""
                self.bio = value["bio"] as? String ?? ""
                self.profileImageURL = value["profileImageURL"] as? String

                // ⭐️ inviteCount ONLY
                if let n = value["inviteCount"] as? Int {
                    self.inviteCount = n
                } else if let n = value["inviteCount"] as? NSNumber {
                    self.inviteCount = n.intValue
                } else {
                    self.inviteCount = 0
                }

                // badgeTier optional
                if let s = value["badgeTier"] as? String, !s.isEmpty {
                    self.badgeTier = s
                } else {
                    self.badgeTier = "white"
                }
            }
        }
    }

    // MARK: - Admin Gate (hardcoded + RTDB)

    private func checkIfAdminHardAndSoft() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isAdmin = false
            return
        }

        if uid == SUPERADMIN_UID {
            isAdmin = true
            return
        }

        let root = Database.database().reference()
        let adminsRef = root.child("admins").child(uid)
        let superRef  = root.child("superadmin").child(uid)

        adminsRef.observeSingleEvent(of: .value, with: { aSnap in
            if (aSnap.value as? Bool) == true {
                DispatchQueue.main.async { self.isAdmin = true }
                return
            }
            superRef.observeSingleEvent(of: .value, with: { sSnap in
                let ok = ((sSnap.value as? Bool) == true)
                DispatchQueue.main.async { self.isAdmin = ok }
            }, withCancel: { error in
                print("❌ superadmin check error: \(error.localizedDescription)")
            })
        }, withCancel: { error in
            print("❌ admins check error: \(error.localizedDescription)")
        })
    }
}

// MARK: - Star Badge UI (Profile-prefixed to avoid collisions elsewhere)

private struct ProfileStarBadgeInline: View {
    let tier: String
    let inviteCount: Int

    @State private var pulse = false

    // Use whichever is higher: stored tier or derived-from-inviteCount
    private var level: Int {
        max(tierOrder(tier), tierOrder(deriveTier(from: inviteCount)))
    }

    private var scaleRange: ClosedRange<CGFloat> {
        let base: CGFloat = 0.06
        let step: CGFloat = 0.02
        let amp = min(base + step * CGFloat(max(0, level)), 0.22)
        return (1.0 - amp)...(1.0 + amp)
    }

    private var ringOpacity: Double {
        level == 0 ? 0.18 : 0.35
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(colorForTier(tier).opacity(ringOpacity), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.6 : 1.0)
                .opacity(pulse ? 0.0 : 1.0)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)

            Image(systemName: "star.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(colorForTier(tier))
                .shadow(color: .white.opacity(0.25), radius: 3)
                .scaleEffect(pulse ? scaleRange.upperBound : scaleRange.lowerBound)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                .animation(.easeInOut(duration: 0.25), value: tier)
                .accessibilityLabel(Text("\(tier.capitalized) popularity star, invites \(inviteCount)"))
        }
        .onAppear { pulse = true }
    }
}

private struct ProfileStarBadgeProgressRow: View {
    let inviteCount: Int
    private var tiers: [(String, Int)] {
        [("white",0),("red",5),("orange",10),("yellow",20),("green",40),("blue",80),("indigo",160),("violet",320),("black",640)]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tiers, id: \.0) { (name, threshold) in
                let achieved = inviteCount >= threshold
                Image(systemName: achieved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(colorForTier(name).opacity(achieved ? 1 : 0.35))
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Badge helpers (inviteCount-only)

fileprivate func effectiveBadgeTier(inviteCount: Int, storedTier: String) -> String {
    let normalized = storedTier.lowercased()
    let derived = deriveTier(from: inviteCount)
    if normalized.isEmpty { return derived }
    return max(tierOrder(normalized), tierOrder(derived)) == tierOrder(derived) ? derived : normalized
}

fileprivate func deriveTier(from inviteCount: Int) -> String {
    if inviteCount >= 640 { return "black" }
    if inviteCount >= 320 { return "violet" }
    if inviteCount >= 160 { return "indigo" }
    if inviteCount >= 80  { return "blue" }
    if inviteCount >= 40  { return "green" }
    if inviteCount >= 20  { return "yellow" }
    if inviteCount >= 10  { return "orange" }
    if inviteCount >= 5   { return "red" }
    return "white"
}

fileprivate func colorForTier(_ tier: String) -> Color {
    switch tier.lowercased() {
    case "white": return .white
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "indigo": return .indigo
    case "violet": return .purple
    case "black": return .black
    default: return .gray
    }
}

fileprivate func tierOrder(_ tier: String) -> Int {
    switch tier.lowercased() {
    case "white": return 0
    case "red": return 1
    case "orange": return 2
    case "yellow": return 3
    case "green": return 4
    case "blue": return 5
    case "indigo": return 6
    case "violet": return 7
    case "black": return 8
    default: return -1
    }
}

// MARK: - RTDB helpers (brands)

extension ProfileTabView {
    private func fetchBrands() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value, with: { snapshot in
            var userBrands: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                guard
                    let dict = child.value as? [String: Any],
                    let brand = BrandModel.from(dict: dict, id: child.key)
                else { continue }
                let owner = brand.ownerId.isEmpty ? (dict["userId"] as? String ?? "") : brand.ownerId
                if owner == uid { userBrands.append(brand) }
            }
            DispatchQueue.main.async { self.brands = userBrands }
        }, withCancel: { error in
            print("❌ fetchBrands error: \(error.localizedDescription)")
        })
    }
}

// MARK: - Misc helpers

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private func signOutSection(authVM: AuthViewModel) -> some View {
    VStack(spacing: 16) {
        Button(action: {
            do {
                try Auth.auth().signOut()
                authVM.signOut()
            } catch {
                print("❌ Sign out failed: \(error.localizedDescription)")
            }
        }) {
            Text("Sign Out")
                .fontWeight(.bold)
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .cornerRadius(12)
        }
    }
    .padding(.horizontal)
    .padding(.bottom, 40)
}
