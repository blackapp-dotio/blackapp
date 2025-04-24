import SwiftUI
import FeedKit
import WebKit
import FirebaseDatabase
import FirebaseAuth

struct GossipTabView: View {
    @State private var rssArticles: [RSSArticle] = []
    @State private var userPosts: [UserPost] = []
    @State private var newPostText: String = ""
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var isLoading = true

    let rssFeedURLs = [
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
        "https://afro.com/section/arts-entertainment/feed/",
    ]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading) {
                HStack {
                    Spacer()
                    Image("blackapp_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                    Spacer()
                }

                HStack(alignment: .top) {
                    TextEditor(text: $newPostText)
                        .frame(height: 60)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .background(Color.black)
                        .padding(.horizontal)

                    Button(action: postToFirebase) {
                        Image(systemName: "paperplane.fill")
                            .padding(12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                    .padding(.trailing)
                }

                if isLoading {
                    ProgressView("Loading Gist...")
                        .padding()
                } else {
                    List {
                        ForEach(userPosts.sorted { $0.timestamp > $1.timestamp }) { post in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.text)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 4)
                                Text(post.dateFormatted)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Color.black)
                        }

                        ForEach(rssArticles) { article in
                            RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                                .listRowBackground(Color.black)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Gossip")
            .background(Color.black)
            .onAppear {
                fetchFeedsInChunks()
                fetchUserPosts()
            }
            .sheet(isPresented: $showWebView) {
                if let url = selectedURL {
                    WebView(url: url)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    func postToFirebase() {
        guard !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let userId = Auth.auth().currentUser?.uid else { return }

        let ref = Database.database().reference().child("posts").childByAutoId()
        let post = [
            "text": newPostText,
            "timestamp": Date().timeIntervalSince1970,
            "userId": userId
        ] as [String: Any]

        ref.setValue(post)
        newPostText = ""
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
                    loaded.append(UserPost(id: child.key, text: text, timestamp: timestamp, userId: userId))
                }
            }
            self.userPosts = loaded
        }
    }

    func fetchFeedsInChunks(chunkSize: Int = 2) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for chunk in chunks {
                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in chunk {
                        group.addTask {
                            return await fetchFeed(urlString: url)
                        }
                    }
                    for await result in group {
                        let filtered = result.filter { $0.imageURL != nil }
                        await MainActor.run {
                            self.rssArticles.append(contentsOf: filtered)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }

    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else { return [] }
        let parser = FeedParser(URL: url)
        let result = parser.parse()
        switch result {
        case .success(let feed):
            let items = feed.rssFeed?.items ?? []
            return items.prefix(2).compactMap {
                guard let title = $0.title,
                      let link = $0.link,
                      let description = $0.description?.strippedHTML(),
                      let pubDate = $0.pubDate else { return nil }

                let imageURL = extractImageURL(from: $0)
                return RSSArticle(title: title, link: link, description: description, pubDate: pubDate, imageURL: imageURL)
            }
        default: return []
        }
    }

    func extractImageURL(from item: RSSFeedItem) -> URL? {
        if let mediaURL = item.media?.mediaContents?.first?.attributes?.url {
            return URL(string: mediaURL)
        }

        if let desc = item.description,
           let imgTagRange = desc.range(of: "<img[^>]+src=\"([^\"]+)\"", options: .regularExpression),
           let match = desc[imgTagRange].range(of: "src=\"([^\"]+)\"", options: .regularExpression),
           let urlRange = desc[match].range(of: #"(?<=src=\")[^\"]+"#, options: .regularExpression) {
            return URL(string: String(desc[match][urlRange]))
        }

        return nil
    }
}

// MARK: - Post Model
struct UserPost: Identifiable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let userId: String

    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
