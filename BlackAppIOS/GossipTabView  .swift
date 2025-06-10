import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import WebKit
import FeedKit

// MARK: - UserPost Model with Comments

struct UserPost: Identifiable {
    let id: String
    var text: String
    let timestamp: TimeInterval
    let userId: String
    var imageURL: String?
    var isLikedByCurrentUser: Bool = false
    var comments: [Comment] = []

    struct Comment: Identifiable {
        let id: String
        let userId: String
        let text: String
        let timestamp: TimeInterval
    }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

// MARK: - Wrapper for Mixed RSS + Post Feed

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

// MARK: - GossipTabView

struct GossipTabView: View {
    // Post-related state
    @State private var rssArticles: [RSSArticle] = []
    @State private var userPosts: [UserPost] = []
    @State private var combinedFeed: [AnyIdentifiablePost] = []
    @State private var newPostText: String = ""
    @State private var editingPostId: String? = nil
    @State private var selectedImage: UIImage? = nil

    // UI state
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var showImagePicker = false
    @State private var isLoading = true
    @State private var commentTargetPost: UserPost? = nil
    @State private var commentText: String = ""

    // RSS URLs
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
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let root = scene.windows.first?.rootViewController else { return }
                root.present(UIHostingController(rootView: SearchView()), animated: true)
            })

            VStack(alignment: .leading, spacing: 12) {
                // Text field with placeholder
                ZStack(alignment: .topLeading) {
                    if newPostText.isEmpty {
                        Text(editingPostId == nil ? "What's the gist?" : "Editing post...")
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 14)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $newPostText)
                        .frame(height: 60)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .foregroundColor(.white)
                        .background(Color.black)
                }
                .padding(.horizontal)

                // Image preview if selected
                if let img = selectedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(8)
                        .padding(.horizontal)
                }

                // Buttons: Camera + Post
                HStack(spacing: 20) {
                    Button(action: { showImagePicker = true }) {
                        Image(systemName: "photo.on.rectangle")
                            .padding(8)
                            .background(Color.gray)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }

                    Button(action: {
                        if let id = editingPostId {
                            updatePost(id)
                        } else {
                            postToFirebase()
                        }
                    }) {
                        Image(systemName: "paperplane.fill")
                            .padding(8)
                            .background(editingPostId == nil ? Color.blue : Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)

                Divider().background(Color.gray)

                // Feed listing
                if isLoading {
                    ProgressView("Loading...").padding()
                } else {
                    List(combinedFeed.sorted(by: { $0.timestamp > $1.timestamp })) { item in
                        item.view($selectedURL, $showWebView)
                    }
                    .listStyle(.plain)
                }
            }
            .onAppear(perform: reloadContent)
            .sheet(isPresented: $showWebView) {
                if let url = selectedURL {
                    WebView(url: url)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedImage)
            }
            .sheet(item: $commentTargetPost) { post in
                VStack {
                    Text("Comment").font(.headline).padding(.top)
                    TextField("Your comment...", text: $commentText)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                        .foregroundColor(.white)
                    Button("Post Comment") { postComment(to: post) }
                        .padding()
                    Spacer()
                }
                .padding()
                .background(Color.black)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: - CRUD + Comments + Likes + Share

    func reloadContent() {
        rssArticles = []
        userPosts = []
        combinedFeed = []
        isLoading = true
        fetchFeedsInChunks()
        fetchUserPosts()
    }

    func postToFirebase() {
        guard !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let ref = Database.database().reference().child("posts").childByAutoId()
        let id = ref.key ?? UUID().uuidString
        let ts = Date().timeIntervalSince1970

        func save(_ imgURL: String?) {
            ref.setValue([
                "text": newPostText,
                "timestamp": ts,
                "userId": uid,
                "imageURL": imgURL ?? ""
            ])
            resetPostFields()
        }

        if let img = selectedImage?.jpegData(compressionQuality: 0.8) {
            let sref = Storage.storage().reference().child("post_images/\(id).jpg")
            sref.putData(img, metadata: nil) { _, _ in
                sref.downloadURL { url, _ in
                    save(url?.absoluteString)
                }
            }
        } else {
            save(nil)
        }
    }

    func updatePost(_ id: String) {
        let ref = Database.database().reference().child("posts").child(id)
        ref.updateChildValues(["text": newPostText]) { _, _ in
            resetPostFields()
        }
    }

    func resetPostFields() {
        newPostText = ""
        selectedImage = nil
        editingPostId = nil
        fetchUserPosts()
    }

    func deletePost(_ post: UserPost) {
        Database.database().reference()
            .child("posts").child(post.id)
            .removeValue { _, _ in
                fetchUserPosts()
            }
    }

    func postComment(to post: UserPost) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("comments").child(post.id).childByAutoId()
        ref.setValue([
            "userId": uid,
            "text": commentText,
            "timestamp": Date().timeIntervalSince1970
        ]) { _, _ in
            resetPostFields()
        }
    }

    func toggleLike(for id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let r = Database.database().reference()
            .child("likes").child(id).child(uid)
        r.observeSingleEvent(of: .value) { snap in
            if snap.exists() {
                r.removeValue { _, _ in fetchUserPosts() }
            } else {
                r.setValue(true) { _, _ in fetchUserPosts() }
            }
        }
    }

    func sharePost(_ post: UserPost) {
        guard let root = UIApplication.shared.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [post.text], applicationActivities: nil), animated: true)
    }

    func shareArticle(_ article: RSSArticle) {
        guard let url = URL(string: article.link),
              let root = UIApplication.shared.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    // MARK: - Fetch User Posts + Likes + Comments

    func fetchUserPosts() {
        let pRef = Database.database().reference().child("posts")
        let lRef = Database.database().reference().child("likes")
        let cRef = Database.database().reference().child("comments")
        guard let uid = Auth.auth().currentUser?.uid else { return }

        pRef.observeSingleEvent(of: .value) { snap in
            var arr: [UserPost] = []
            for case let cs as DataSnapshot in snap.children {
                if let d = cs.value as? [String: Any],
                   let t = d["text"] as? String,
                   let ts = d["timestamp"] as? TimeInterval,
                   let u = d["userId"] as? String {
                    arr.append(UserPost(
                        id: cs.key,
                        text: t,
                        timestamp: ts,
                        userId: u,
                        imageURL: d["imageURL"] as? String))
                }
            }
            lRef.observeSingleEvent(of: .value) { lsnap in
                var liked: Set<String> = []
                for case let ps as DataSnapshot in lsnap.children {
                    if ps.hasChild(uid) {
                        liked.insert(ps.key)
                    }
                }
                cRef.observeSingleEvent(of: .value) { csnap in
                    var cm: [String: [UserPost.Comment]] = [:]
                    for case let pSnap as DataSnapshot in csnap.children {
                        var comments: [UserPost.Comment] = []
                        for case let cSnap as DataSnapshot in pSnap.children {
                            if let cd = cSnap.value as? [String: Any],
                               let u = cd["userId"] as? String,
                               let t = cd["text"] as? String,
                               let tm = cd["timestamp"] as? TimeInterval {
                                comments.append(UserPost.Comment(id: cSnap.key, userId: u, text: t, timestamp: tm))
                            }
                        }
                        cm[pSnap.key] = comments
                    }
                    for i in arr.indices {
                        let p = arr[i].id
                        arr[i].isLikedByCurrentUser = liked.contains(p)
                        arr[i].comments = cm[p] ?? []
                    }
                    userPosts = arr
                    mergeContent()
                }
            }
        }
    }

    // MARK: - Fetch RSS Articles with Media Only

    func fetchFeedsInChunks(chunkSize: Int = 3) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for c in chunks {
                await withTaskGroup(of: [RSSArticle].self) { g in
                    for url in c {
                        g.addTask { await fetchFeed(urlString: url) }
                    }
                    for await items in g {
                        await MainActor.run {
                            rssArticles.append(contentsOf: items)
                            mergeContent()
                        }
                    }
                }
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }

    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let feed = try FeedParser(data: data).parse()
            guard case .success(let f) = feed else { return [] }
            let items = f.rssFeed?.items ?? []
            return items.prefix(3).compactMap { item in
                guard let title = item.title,
                      let link = item.link,
                      let desc = item.description?.strippedHTML(),
                      let pub = item.pubDate else { return nil }
                let str = item.enclosure?.attributes?.url ?? extractImageURL(from: item.description ?? "")
                guard let imgUrl = str.flatMap(URL.init) else { return nil }
                return RSSArticle(title: title, link: link, description: desc, pubDate: pub, imageURL: imgUrl)
            }
        } catch {
            return []
        }
    }

    func extractImageURL(from html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let m = re.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
              m.numberOfRanges > 1
        else { return nil }
        return (html as NSString).substring(with: m.range(at: 1))
    }

    // MARK: - Combine and Render Posts

    func mergeContent() {
        let rss = rssArticles.map { article in
            AnyIdentifiablePost(timestamp: article.pubDate.timeIntervalSince1970, id: article.title) {
                VStack(alignment: .leading) {
                    RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                    HStack(spacing: 20) {
                        Button(action: { shareArticle(article) }) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }

        let users = userPosts.map { post in
            AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(post.text)
                        .foregroundColor(.white)
                        .padding(.vertical, 4)

                    if let img = post.imageURL, let url = URL(string: img) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxHeight: 200)
                        .cornerRadius(10)
                    }

                    Text(post.dateFormatted)
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack(spacing: 20) {
                        Button(action: { toggleLike(for: post.id) }) {
                            Image(systemName: "hand.thumbsup")
                                .foregroundColor(post.isLikedByCurrentUser ? .blue : .gray)
                        }

                        Button(action: { commentTargetPost = post }) {
                            Image(systemName: "bubble.right")
                                .foregroundColor(.gray)
                        }

                        Button(action: { sharePost(post) }) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.gray)
                        }

                        if post.userId == Auth.auth().currentUser?.uid {
                            Button(action: {
                                newPostText = post.text
                                editingPostId = post.id
                            }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.yellow)
                            }
                            Button(action: { deletePost(post) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.top, 4)

                    if !post.comments.isEmpty {
                        ForEach(post.comments) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.text)
                                    .font(.caption)
                                    .foregroundColor(.white)
                                Text(Date(timeIntervalSince1970: c.timestamp), style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }

        combinedFeed = (users + rss).sorted(by: { $0.timestamp > $1.timestamp })
    }
}
