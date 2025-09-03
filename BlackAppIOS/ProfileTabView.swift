// ProfileTabView.swift — Social sync + star badge + AG Dashboard (hardcoded superadmin)

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

    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var profileImage: UIImage? = nil
    @State private var profileImageURL: String? = nil
    @State private var showImagePicker = false
    @State private var brands: [BrandModel] = []

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

    // ⭐️ Popularity (live)
    @State private var circleSize: Int = 0
    @State private var badgeTier: String = "white"   // default baseline
    @State private var showAllBadges: Bool = false

    // RTDB observers
    @State private var circleRef: DatabaseReference?
    @State private var circleHandle: DatabaseHandle?
    @State private var badgeRef: DatabaseReference?
    @State private var badgeHandle: DatabaseHandle?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                TopToolbarView(onLogoTap: {}, onSearchTap: {})
                    .padding(.horizontal)
                    .frame(height: 60)

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
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            fetchProfile()
            fetchBrands()
            checkIfAdminHardAndSoft()   // ← hardcoded + RTDB roles
            loadSyncedAccounts()
            startObservingPopularity()
        }
        .onDisappear {
            stopObservingPopularity()
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
                    saveProfile()
                    withAnimation { isEditingProfile = false }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
            } else {
                // 🟡 Name + star badge (always visible; defaults to white)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(name.isEmpty ? "Unnamed" : name)
                            .font(.title2)
                            .foregroundColor(.white)
                            .fontWeight(.bold)

                        let currentTier = effectiveBadgeTier(circleSize: circleSize, storedTier: badgeTier)

                        ProfileStarBadgeInline(tier: currentTier, circleSize: circleSize)
                            .onTapGesture {
                                withAnimation(.easeInOut) { showAllBadges.toggle() }
                            }
                    }

                    if showAllBadges {
                        ProfileStarBadgeProgressRow(circleSize: circleSize)
                            .transition(.opacity)
                    }
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

    // MARK: - Popularity Live Observers

    private func startObservingPopularity() {
        guard let uid = authVM.user?.uid else { return }
        // circleSize
        let cRef = Database.database().reference().child("users").child(uid).child("circleSize")
        circleRef = cRef
        circleHandle = cRef.observe(.value) { snap in
            if let n = snap.value as? NSNumber {
                circleSize = n.intValue
            } else if let n = snap.value as? Int {
                circleSize = n
            } else {
                circleSize = 0
            }
        }
        // badgeTier (optional; falls back to derived if missing)
        let bRef = Database.database().reference().child("users").child(uid).child("badgeTier")
        badgeRef = bRef
        badgeHandle = bRef.observe(.value) { snap in
            if let s = snap.value as? String, !s.isEmpty {
                badgeTier = s
            } else {
                badgeTier = "white"
            }
        }
    }

    private func stopObservingPopularity() {
        if let ref = circleRef, let handle = circleHandle { ref.removeObserver(withHandle: handle) }
        if let ref = badgeRef,  let handle = badgeHandle  { ref.removeObserver(withHandle: handle) }
        circleRef = nil; circleHandle = nil
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

    private func saveProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users").child(uid)

        if profileImage == nil {
            ref.observeSingleEvent(of: .value) { snapshot in
                var data: [String: Any] = ["name": name, "bio": bio]
                if let existingData = snapshot.value as? [String: Any],
                   let existingProfileURL = existingData["profileImageURL"] as? String {
                    data["profileImageURL"] = existingProfileURL
                }
                ref.updateChildValues(data)
            }
        } else {
            if let image = profileImage, let imageData = image.jpegData(compressionQuality: 0.8) {
                let storageRef = Storage.storage().reference().child("profile_images/\(uid).jpg")
                storageRef.putData(imageData) { _, error in
                    if let error = error {
                        print("❌ Upload failed: \(error.localizedDescription)")
                        return
                    }
                    storageRef.downloadURL { url, _ in
                        if let url = url {
                            let data: [String: Any] = [
                                "name": name,
                                "bio": bio,
                                "profileImageURL": url.absoluteString
                            ]
                            ref.updateChildValues(data)
                        }
                    }
                }
            }
        }
    }

    private func fetchProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            if let value = snapshot.value as? [String: Any] {
                self.name = value["name"] as? String ?? ""
                self.bio = value["bio"] as? String ?? ""
                self.profileImageURL = value["profileImageURL"] as? String
                if let n = value["circleSize"] as? Int { self.circleSize = n }
                if let s = value["badgeTier"] as? String, !s.isEmpty { self.badgeTier = s }
            }
        }
    }

    // MARK: - Admin Gate (hardcoded + RTDB)

    /// Sets `isAdmin` true if:
    /// 1) current user matches the hardcoded SUPERADMIN_UID, OR
    /// 2) user is present in /admins or /superadmin in RTDB.
    private func checkIfAdminHardAndSoft() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isAdmin = false
            return
        }

        // Hard override first
        if uid == SUPERADMIN_UID {
            isAdmin = true
            return
        }

        // Then fall back to RTDB roles
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
    let circleSize: Int

    @State private var pulse = false

    // Use whichever is higher: stored tier or derived-from-circleSize
    private var level: Int {
        max(tierOrder(tier), tierOrder(deriveTier(from: circleSize)))
    }

    // Pulse amplitude scales gently with level:
    // baseline ~±6%, max tier ~±22%
    private var scaleRange: ClosedRange<CGFloat> {
        let base: CGFloat = 0.06     // baseline amplitude
        let step: CGFloat = 0.02     // per-tier increase
        let amp = min(base + step * CGFloat(max(0, level)), 0.22)
        return (1.0 - amp)...(1.0 + amp)
    }

    // Softer ring at baseline, brighter as level rises
    private var ringOpacity: Double {
        level == 0 ? 0.18 : 0.35
    }

    var body: some View {
        ZStack {
            // Breathing ring behind star (always on, subtle at baseline)
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
                // Throb scale — always active, amplitude from scaleRange
                .scaleEffect(pulse ? scaleRange.upperBound : scaleRange.lowerBound)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                // Keep your smooth color/tier transition
                .animation(.easeInOut(duration: 0.25), value: tier)
                .accessibilityLabel(Text("\(tier.capitalized) popularity star, circle size \(circleSize)"))
        }
        .onAppear { pulse = true }
    }
}

private struct ProfileStarBadgeProgressRow: View {
    let circleSize: Int
    private var tiers: [(String, Int)] {
        [("white",0),("red",5),("orange",10),("yellow",20),("green",40),("blue",80),("indigo",160),("violet",320),("black",640)]
    }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(tiers, id: \.0) { (name, threshold) in
                let achieved = circleSize >= threshold
                Image(systemName: achieved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(colorForTier(name).opacity(achieved ? 1 : 0.35))
            }
        }
        .padding(.top, 2)
    }
}


// MARK: - Badge helpers

fileprivate func effectiveBadgeTier(circleSize: Int, storedTier: String) -> String {
    let normalized = storedTier.lowercased()
    if normalized.isEmpty { return deriveTier(from: circleSize) }
    let derived = deriveTier(from: circleSize)
    return max(tierOrder(normalized), tierOrder(derived)) == tierOrder(derived) ? derived : normalized
}
fileprivate func deriveTier(from circleSize: Int) -> String {
    if circleSize >= 640 { return "black" }
    if circleSize >= 320 { return "violet" }
    if circleSize >= 160 { return "indigo" }
    if circleSize >= 80  { return "blue" }
    if circleSize >= 40  { return "green" }
    if circleSize >= 20  { return "yellow" }
    if circleSize >= 10  { return "orange" }
    if circleSize >= 5   { return "red" }
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
                // Prefer brand.ownerId; fall back to userId if needed
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
