// ProfileTabView.swift — Full working version with admin portal, toolbar, brand creation, and platform logos

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import SDWebImageSwiftUI

struct ProfileTabView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var profileImage: UIImage? = nil
    @State private var profileImageURL: String? = nil
    @State private var showImagePicker = false
    @State private var brands: [BrandModel] = []
    @State private var isAdmin = false

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
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(selectedImage: $profileImage)
        }
    }

    private var profileSection: some View {
        VStack(spacing: 10) {
            if let imageURL = profileImageURL, let url = URL(string: imageURL) {
                WebImage(url: url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .foregroundColor(.gray)
            }

            Button("Change Profile Picture") {
                showImagePicker = true
            }
            .foregroundColor(.blue)

            TextField("Name", text: $name)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)

            TextEditor(text: $bio)
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))
                .padding(.horizontal)

            Button("Save Profile") {
                saveProfile()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom)
        }
        .padding(.top)
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
                Image(systemName: "f.cursive")
                Image(systemName: "x.squareroot")
                Image(systemName: "camera.circle")
                Image(systemName: "music.note")
                Image(systemName: "play.rectangle.fill")
            }
            .font(.title2)
            .foregroundColor(.white)
        }
        .padding(.horizontal)
    }

    private var userWallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Wall")
                .font(.headline)
                .foregroundColor(.white)
            Text("Coming soon: synced social posts from your connected accounts")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.horizontal)
    }

    private func saveProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users").child(uid)
        var data: [String: Any] = ["name": name, "bio": bio]

        if let image = profileImage, let imageData = image.jpegData(compressionQuality: 0.8) {
            let storageRef = Storage.storage().reference().child("profile_images/\(uid).jpg")
            storageRef.putData(imageData) { _, error in
                guard error == nil else { return }
                storageRef.downloadURL { url, _ in
                    if let url = url {
                        data["profileImageURL"] = url.absoluteString
                        ref.setValue(data)
                    }
                }
            }
        } else {
            ref.setValue(data)
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
        ref.observeSingleEvent(of: .value) { snapshot in
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
        if uid == "XszTTDbebpcYjiqYqgQPAlxWEs82" { // Hardcoded for now
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



