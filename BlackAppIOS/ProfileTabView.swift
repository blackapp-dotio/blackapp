// ProfileTabView.swift — Fully integrated with social platform sync

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import SDWebImageSwiftUI

// No SyncedAccount definition here to avoid redeclaration conflict

struct ProfileTabView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var profileImage: UIImage? = nil
    @State private var profileImageURL: String? = nil
    @State private var showImagePicker = false
    @State private var brands: [BrandModel] = []
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
                .onTapGesture {
                    hideKeyboard()
                }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isAdmin {
                        NavigationLink(destination: AGDashboardView()) {
                            Image("ag-global-logo")
                                .resizable()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .onAppear {
            fetchProfile()
            fetchBrands()
            checkIfAdmin()
            loadSyncedAccounts()
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

    private var profileSection: some View {
        VStack(spacing: 12) {
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
                    withAnimation {
                        isEditingProfile = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
            } else {
                Text(name.isEmpty ? "Unnamed" : name)
                    .font(.title2)
                    .foregroundColor(.white)
                    .fontWeight(.bold)

                Text(bio.isEmpty ? "No bio added yet." : bio)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Edit Profile") {
                    withAnimation {
                        isEditingProfile = true
                    }
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
            UserWallView(userId: Auth.auth().currentUser?.uid ?? ""
)
        }
        .padding(.horizontal)
    }


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

                ref.setValue(data)
            }
        } else {
            if let image = profileImage, let imageData = image.jpegData(compressionQuality: 0.8) {
                let storageRef = Storage.storage().reference().child("profile_images/\(uid).jpg")
                storageRef.putData(imageData) { metadata, error in
                    if let error = error {
                        print("❌ Upload failed: \(error.localizedDescription)")
                        return
                    }
                    storageRef.downloadURL { url, error in
                        if let url = url {
                            let data: [String: Any] = [
                                "name": name,
                                "bio": bio,
                                "profileImageURL": url.absoluteString
                            ]
                            ref.setValue(data)
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
                name = value["name"] as? String ?? ""
                bio = value["bio"] as? String ?? ""
                profileImageURL = value["profileImageURL"] as? String
            }
        }
    }

    private func fetchBrands() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("brands")
        ref.observe(.value) { snapshot in
            var userBrands: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key),
                   brand.ownerId == uid {
                    userBrands.append(brand)
                }
            }
            self.brands = userBrands
        }
    }

    private func checkIfAdmin() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if uid == "XszTTDbebpcYjiqYqgQPAlxWEs82" {
            self.isAdmin = true
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
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

