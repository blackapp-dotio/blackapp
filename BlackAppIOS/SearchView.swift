import SwiftUI
import FirebaseDatabase

struct SearchView: View {
    @State private var searchText = ""
    @State private var allUsers: [UserProfile] = []
    @State private var allArticles: [RSSArticle] = []
    @State private var filteredUsers: [UserProfile] = []
    @State private var filteredArticles: [RSSArticle] = []

    var body: some View {
        VStack {
            // Search Bar
            TextField("Search for users or articles...", text: $searchText)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding()

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
    }

    func performSearch() {
        let lowercasedQuery = searchText.lowercased()

        filteredUsers = allUsers.filter {
            $0.name.lowercased().contains(lowercasedQuery) ||
            $0.username.lowercased().contains(lowercasedQuery)
        }

        filteredArticles = allArticles.filter {
            $0.title.lowercased().contains(lowercasedQuery)
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
        // This assumes you are loading articles from elsewhere.
        // For now, it just uses whatever articles are already pulled into the app.
        // Ideally, we should pass `rssArticles` from GossipTabView when opening SearchView.
    }
}

// MARK: - Models

struct UserProfile: Identifiable {
    let id: String
    let name: String
    let username: String
}
