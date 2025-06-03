// GossipTabView.swift — Optimized version with reaction buttons, chunked feed loading, and timestamp sorting

import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import WebKit
import FeedKit

struct UserPost: Identifiable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let userId: String
    var imageURL: String?

    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct GossipTabView: View {
    @State private var rssArticles: [RSSArticle] = []
    @State private var userPosts: [UserPost] = []
    @State private var combinedFeed: [AnyIdentifiablePost] = []
    @State private var newPostText: String = ""
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var isLoading = true
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?

    private let rssFeedURLs = [
        "https://rss.app/feeds/a0BC3EgcQ2gi6jt9.xml",
        "https://rss.app/feeds/MDlghVUX5yvecvRG.xml",
        "https://www.okayafrica.com/music/rss/",
        "https://celebrity.nine.com.au/rss",
        "https://www.allabouttrh.com/feed/",
        "https://bckonline.com/feed/",
        "https://balleralert.com/feed/",
        "https://www.buzzfeed.com/celebrity.xml",
        "https://sahiphopmag.co.za/feed/",
        "https://tooxclusive.com/feed/",
        "https://theshaderoom.com/latest-tea/feed/",
        "https://afro.com/section/arts-entertainment/feed/"
    ]

    var body: some View {
        VStack {
            TopToolbarView(onLogoTap: reloadContent, onSearchTap: {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    let searchView = UIHostingController(rootView: SearchView())
                    rootVC.present(searchView, animated: true)
                }
            })

            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    ZStack(alignment: .topLeading) {
                        if newPostText.isEmpty {
                            Text("What's the gist?")
                                .foregroundColor(.white)
                                .padding(.top, 14)
                                .padding(.leading, 5)
                        }

                        TextEditor(text: $newPostText)
                            .frame(height: 60)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .scrollContentBackground(.hidden)
                            .background(Color.black)
                    }
                    .padding(.horizontal)

                    VStack {
                        Button(action: { showImagePicker = true }) {
                            Image(systemName: "photo.on.rectangle")
                                .padding(8)
                                .background(Color.gray)
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }

                        Button(action: postToFirebase) {
                            Image(systemName: "paperplane.fill")
                                .padding(8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.trailing)
                }

                if isLoading {
                    ProgressView("Loading Gist...")
                        .padding()
                } else {
                    List(combinedFeed.sorted(by: { $0.timestamp > $1.timestamp })) { item in
                        item.view($selectedURL, $showWebView)
                    }
                    .listStyle(.plain)
                }
            }
            .onAppear { reloadContent() }
            .sheet(isPresented: $showWebView) {
                if let url = selectedURL {
                    WebView(url: url)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedImage)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    func postToFirebase() {
        guard !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let userId = Auth.auth().currentUser?.uid else { return }

        let ref = Database.database().reference().child("posts").childByAutoId()
        let postId = ref.key ?? UUID().uuidString
        let timestamp = Date().timeIntervalSince1970

        func savePost(with imageURL: String?) {
            let post = [
                "text": newPostText,
                "timestamp": timestamp,
                "userId": userId,
                "imageURL": imageURL ?? ""
            ] as [String: Any]

            ref.setValue(post) { error, _ in
                if let error = error {
                    print("❌ Failed to save post: \(error.localizedDescription)")
                } else {
                    print("✅ Post saved: \(postId)")
                    fetchUserPosts()
                }
            }

            newPostText = ""
            selectedImage = nil
        }

        if let image = selectedImage, let imageData = image.jpegData(compressionQuality: 0.8) {
            let storageRef = Storage.storage().reference().child("post_images/\(postId).jpg")
            storageRef.putData(imageData) { _, error in
                if error == nil {
                    storageRef.downloadURL { url, _ in
                        savePost(with: url?.absoluteString)
                    }
                }
            }
        } else {
            savePost(with: nil)
        }
    }

    func fetchUserPosts() {
        let ref = Database.database().reference().child("posts")
        ref.observeSingleEvent(of: .value) { snapshot in
            var loaded: [UserPost] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let text = dict["text"] as? String,
                   let timestamp = dict["timestamp"] as? TimeInterval,
                   let userId = dict["userId"] as? String {
                    let imageURL = dict["imageURL"] as? String
                    loaded.append(UserPost(id: child.key, text: text, timestamp: timestamp, userId: userId, imageURL: imageURL))
                }
            }
            self.userPosts = loaded
            mergeContent()
            print("✅ Loaded user posts: \(loaded.count)")
        }
    }

    func fetchFeedsInChunks(chunkSize: Int = 3) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for chunk in chunks {
                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in chunk {
                        group.addTask { await fetchFeed(urlString: url) }
                    }
                    for await result in group {
                        await MainActor.run {
                            self.rssArticles.append(contentsOf: result)
                            mergeContent()
                        }
                    }
                }
            }
            await MainActor.run { self.isLoading = false }
        }
    }

    func mergeContent() {
        let rss = rssArticles.map { article in
            AnyIdentifiablePost(timestamp: article.pubDate.timeIntervalSince1970, id: article.title) {
                VStack(alignment: .leading) {
                    RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                   /* HStack(spacing: 20) {
                        Button(action: {
                            print("👍 Like tapped for article: \(article.title)")
                            // Optionally store in local state or Firebase
                        }) {
                            Label("Like", systemImage: "hand.thumbsup")
                        }

                        Button(action: {
                            print("💬 Comment tapped for article: \(article.title)")
                            // In the future: open a comment modal
                        }) {
                            Label("Comment", systemImage: "bubble.right")
                        }

                        Button(action: {
                            if let url = URL(string: article.link) {
                                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                                UIApplication.shared.windows.first?.rootViewController?.present(activityVC, animated: true)
                            }
                        }) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } */
                    .font(.caption)
                    .foregroundColor(.gray)

                }
            }
        }

        let user = userPosts.map { post in
            AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.text)
                        .foregroundColor(.white)
                        .padding(.vertical, 4)

                    if let imageURL = post.imageURL, let url = URL(string: imageURL) {
                        AsyncImage(url: url) { image in
                            image.resizable()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxHeight: 200)
                        .cornerRadius(10)
                    }

                    Text(post.dateFormatted)
                        .font(.caption)
                        .foregroundColor(.gray)

                   /* HStack(spacing: 20) {
                        Button(action: {
                            let ref = Database.database().reference().child("likes").child(post.id)
                            let userId = Auth.auth().currentUser?.uid ?? "anonymous"
                            ref.child(userId).setValue(true)
                            print("✅ Liked post \(post.id)")
                        }) {
                            Label("Like", systemImage: "hand.thumbsup")
                        }

                        Button(action: {
                            print("💬 Comment tapped for \(post.id)")
                            // Present a comment modal or input UI in future
                        }) {
                            Label("Comment", systemImage: "bubble.right")
                        }

                        Button(action: {
                            let activityVC = UIActivityViewController(activityItems: [post.text], applicationActivities: nil)
                            UIApplication.shared.windows.first?.rootViewController?.present(activityVC, animated: true)
                        }) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } */
                    .font(.caption)
                    .foregroundColor(.gray)

                }
                .padding(.vertical, 6)
                .listRowBackground(Color.black)
            }
        }

        self.combinedFeed = (user + rss).sorted { $0.timestamp > $1.timestamp }
    }

    func reloadContent() {
        rssArticles.removeAll()
        userPosts.removeAll()
        combinedFeed.removeAll()
        isLoading = true
        fetchFeedsInChunks()
        fetchUserPosts()
    }

    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let items = feed.rssFeed?.items ?? []
                return items.prefix(3).compactMap {
                    guard let title = $0.title,
                          let link = $0.link,
                          let description = $0.description?.strippedHTML(),
                          let pubDate = $0.pubDate else { return nil }
                    let imageURL = extractImageURL(from: $0)
                    return RSSArticle(title: title, link: link, description: description, pubDate: pubDate, imageURL: imageURL)
                }.filter { $0.imageURL != nil }
            case .failure(let error):
                print("❌ Failed to parse feed: \(error)")
                return []
            }
        } catch {
            print("❌ Failed to fetch feed: \(error.localizedDescription)")
            return []
        }
    }

    func extractImageURL(from item: RSSFeedItem) -> URL? {
        if let mediaURL = item.media?.mediaContents?.first?.attributes?.url {
            return URL(string: mediaURL)
        }
        if let desc = item.description,
           let imgTagRange = desc.range(of: "<img[^>]+src=\\\"([^\\\"]+)\\\"", options: .regularExpression),
           let match = desc[imgTagRange].range(of: "src=\\\"([^\\\"]+)\\\"", options: .regularExpression),
           let urlRange = desc[match].range(of: #"(?<=src=\")[^\"]+"#, options: .regularExpression) {
            return URL(string: String(desc[match][urlRange]))
        }
        return nil
    }
}

struct AnyIdentifiablePost: Identifiable {
    let timestamp: TimeInterval
    let id: String
    let view: (_ selectedURL: Binding<URL?>, _ showWebView: Binding<Bool>) -> AnyView

    init<T: View>(timestamp: TimeInterval, id: String, @ViewBuilder view: @escaping () -> T) {
        self.timestamp = timestamp
        self.id = id
        self.view = { _, _ in AnyView(view()) }
    }
}
