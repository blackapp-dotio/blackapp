import SwiftUI
import FirebaseDatabase
import FirebaseAuth
import Foundation

struct UserProfile: Identifiable {
    let id: String
    let name: String
    let username: String
    var bio: String? = ""
    var profileImageURL: String? = ""
}

struct SearchView: View {
    @State private var searchText = ""
    @State private var allUsers: [UserProfile] = []
    @State private var allArticles: [RSSArticle] = []
    @State private var filteredUsers: [UserProfile] = []
    @State private var filteredArticles: [RSSArticle] = []

    @State private var selectedUser: UserProfile? = nil
    @State private var selectedUserBio: String = ""
    @State private var selectedUserProfileImageURL: String?
    @State private var isConnected: Bool = false

    var body: some View {
        NavigationView {
            VStack {
                // Search Bar
                TextField("Search for users or articles...", text: $searchText)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding()

                // Mini Profile Preview
                if let user = selectedUser {
                    VStack(spacing: 12) {
                        if let imageURL = selectedUserProfileImageURL, let url = URL(string: imageURL) {
                            AsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 100, height: 100)
                                .foregroundColor(.gray)
                        }

                        Text(user.name)
                            .foregroundColor(.white)
                            .font(.title2)

                        Text("@\(user.username)")
                            .foregroundColor(.gray)

                        if !selectedUserBio.isEmpty {
                            Text(selectedUserBio)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        Button(action: {
                            connectWithUser(user.id)
                        }) {
                            Text(isConnected ? "Connected" : "Connect")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(isConnected ? Color.green : Color.blue)
                                .cornerRadius(10)
                        }

                        Divider().background(Color.gray)
                    }
                    .padding(.vertical)
                }

                if searchText.isEmpty {
                    Spacer()
                    Text("Start typing to search...")
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    List {
                        if !filteredUsers.isEmpty {
                            Section(header: Text("Users")) {
                                ForEach(filteredUsers) { user in
                                    Button(action: {
                                        fetchUserProfile(user)
                                    }) {
                                        VStack(alignment: .leading) {
                                            Text(user.name)
                                                .foregroundColor(.white)
                                                .font(.headline)
                                            Text(user.username)
                                                .foregroundColor(.gray)
                                                .font(.subheadline)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }

                        if !filteredArticles.isEmpty {
                            Section(header: Text("Articles")) {
                                ForEach(filteredArticles) { article in
                                    VStack(alignment: .leading) {
                                        Text(article.title)
                                            .foregroundColor(.white)
                                            .font(.headline)
                                        Text(article.pubDate, style: .date)
                                            .foregroundColor(.gray)
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.black)
                }
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .preferredColorScheme(.dark)
            .onAppear {
                loadUsers()
                loadArticles()
            }
            .onChange(of: searchText) { _ in
                performSearch()
            }
            .navigationTitle("Search")
        }
    }

    func performSearch() {
        let query = searchText.lowercased()
        filteredUsers = allUsers.filter {
            $0.name.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
        filteredArticles = allArticles.filter {
            $0.title.lowercased().contains(query)
        }
    }

    func loadUsers() {
        let ref = Database.database().reference().child("users")
        ref.observeSingleEvent(of: .value) { snapshot in
            var loaded: [UserProfile] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let name = dict["name"] as? String,
                   let username = dict["username"] as? String {
                    loaded.append(UserProfile(id: child.key, name: name, username: username))
                }
            }
            self.allUsers = loaded
        }
    }

    func loadArticles() {
        // Placeholder for articles loading
        // Ideally, pass articles from GossipTabView.
    }

    // MARK: - Mini Profile Logic
    func fetchUserProfile(_ user: UserProfile) {
        let ref = Database.database().reference().child("users").child(user.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            if let dict = snapshot.value as? [String: Any] {
                self.selectedUser = user
                self.selectedUserBio = dict["bio"] as? String ?? ""
                self.selectedUserProfileImageURL = dict["profileImageURL"] as? String
                checkConnectionStatus(user.id)
            }
        }
    }

    func checkConnectionStatus(_ userId: String) {
        guard let currentUserID = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("connections").child(currentUserID).child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            isConnected = snapshot.exists()
        }
    }

    func connectWithUser(_ userId: String) {
        guard let currentUserID = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("connections").child(currentUserID).child(userId)

        ref.setValue(true) { error, _ in
            if error == nil {
                isConnected = true
            }
        }
    }
}
