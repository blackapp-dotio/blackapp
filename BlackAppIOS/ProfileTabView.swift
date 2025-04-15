import SwiftUI
import FirebaseAuth

struct ProfileTabView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var showCreateBrand = false
    @State private var showEditAccount = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ✅ Profile Header
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(.blue)

                        VStack(alignment: .leading) {
                            Text(authVM.user?.email ?? "User Email")
                                .font(.headline)
                            Text("Manage your account and settings")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }

                    Divider()

                    // ✅ Account Settings Section
                    Section(header: Text("Account Settings").font(.title3).bold()) {
                        Button("Edit Account Details") {
                            showEditAccount = true
                        }

                        Button("Sign Out") {
                            authVM.signOut()
                        }
                        .foregroundColor(.red)
                    }

                    Divider()

                    // ✅ Brand Management Section
                    Section(header: Text("My Brands").font(.title3).bold()) {
                        Button("Create a Brand") {
                            showCreateBrand = true
                        }

                        // Placeholder brand list
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                // TODO: Replace with actual user brands
                                ForEach(0..<3) { _ in
                                    VStack {
                                        Image(systemName: "building.2.fill")
                                            .resizable()
                                            .frame(width: 50, height: 50)
                                            .foregroundColor(.purple)
                                        Text("Brand Name")
                                            .font(.caption)
                                    }
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(10)
                                }
                            }
                        }
                    }

                    Divider()

                    // ✅ Social Sync Section
                    Section(header: Text("Connected Platforms").font(.title3).bold()) {
                        Text("Meta: Synced")
                        Text("X: Not Synced")
                        // Add buttons for connect/disconnect later
                    }

                    Divider()

                    // ✅ User Wall Section
                    Section(header: Text("Your Wall").font(.title3).bold()) {
                        Text("This is where your personal posts live.")
                        // Placeholder for user posts
                        VStack(spacing: 12) {
                            ForEach(0..<2) { _ in
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 100)
                                    .overlay(Text("Post Content"))
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("My Profile")
            .sheet(isPresented: $showCreateBrand) {
                CreateBrandView()
            }
            .sheet(isPresented: $showEditAccount) {
                EditAccountView()
            }
        }
        .preferredColorScheme(.dark)
    }
}
