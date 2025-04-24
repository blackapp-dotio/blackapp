import SwiftUI
import FirebaseDatabase
import FirebaseAuth
import SDWebImageSwiftUI

struct ProfileTabView: View {
    @State private var name = ""
    @State private var bio = ""
    @State private var profileImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var brands: [BrandModel] = []
    @State private var showCreateBrand = false
    @State private var isAdmin = false
    @State private var showAGDashboard = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Admin button
                    HStack {
                        Spacer()
                        if isAdmin {
                            Button(action: { showAGDashboard = true }) {
                                Image("ag-global-logo")
                                    .resizable()
                                    .frame(width: 40, height: 40)
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Profile Info Section
                    VStack(spacing: 10) {
                        if let profileImage = profileImage {
                            Image(uiImage: profileImage)
                                .resizable()
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.4))
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.white)
                                )
                        }

                        Button("Edit Profile Picture") {
                            showImagePicker = true
                        }

                        TextField("Your Name", text: $name)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField("Short Bio", text: $bio)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.horizontal)

                    Divider()

                    // Brand Management Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Your Brands")
                                .font(.headline)
                            Spacer()
                            Button("Create a Brand") {
                                showCreateBrand = true
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(brands) { brand in
                                    VStack {
                                        if let url = URL(string: brand.logoURL ?? "") {
                                            WebImage(url: url)
                                                .resizable()
                                                .frame(width: 80, height: 80)
                                                .clipShape(Circle())
                                        } else {
                                            Circle()
                                                .fill(Color.gray)
                                                .frame(width: 80, height: 80)
                                        }

                                        Text(brand.name)
                                            .font(.caption)
                                            .foregroundColor(.white)
                                    }
                                    .onTapGesture {
                                        // Navigate to backend dashboard
                                        // Navigation logic for brand backend can be placed here
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Social Media Sync Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connected Accounts")
                            .font(.headline)

                        HStack(spacing: 16) {
                            ForEach(["facebook", "twitter", "instagram", "tiktok", "youtube"], id: \.self) { platform in
                                Image(platform)
                                    .resizable()
                                    .frame(width: 32, height: 32)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // User Wall Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Wall")
                            .font(.headline)
                        Text("This space will stream your posts from connected platforms.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.bottom, 4)

                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 120)
                            .overlay(
                                Text("Your social feed goes here.")
                                    .foregroundColor(.gray)
                            )
                    }
                    .padding(.horizontal)
                }
                .padding(.top)
            }
            .navigationTitle("Your Profile")
            .background(Color.black)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $profileImage)
            }
            .sheet(isPresented: $showCreateBrand) {
                CreateBrandView()
            }
            .sheet(isPresented: $showAGDashboard) {
                AGDashboardView()
            }
            .onAppear {
                checkAdminStatus()
                fetchUserBrands()
            }
        }
    }

    func checkAdminStatus() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("admins").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            isAdmin = snapshot.exists()
        }
    }

    func fetchUserBrands() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("brands")

        ref.observeSingleEvent(of: .value, with: { snapshot in
            var userBrands: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key),
                   brand.ownerId == uid {
                    userBrands.append(brand)
                }
            }
            DispatchQueue.main.async {
                self.brands = userBrands
            }
        })


    }
}
