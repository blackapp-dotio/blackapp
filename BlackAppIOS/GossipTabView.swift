import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import WebKit
import FeedKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - UserPost Model with Comments

struct UserPost: Identifiable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let userId: String
    var mediaURL: String?
    var mediaType: String? // "image", "video"
    var isLikedByCurrentUser: Bool = false
    var comments: [Comment] = []
    var videoURL: URL?

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

// MARK: - Wrapper for Mixed RSS + Post Feed (TOP-LEVEL)

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

// MARK: - Cache DTOs (Codable) — safe to persist

private struct CachedUserPost: Codable {
    struct Cmt: Codable { let id: String; let userId: String; let text: String; let timestamp: TimeInterval }
    let id: String, text: String, timestamp: TimeInterval, userId: String
    let mediaURL: String?, mediaType: String?
    let isLikedByCurrentUser: Bool
    let comments: [Cmt]
}

private struct CachedRSSArticle: Codable {
    let title: String
    let link: String
    let description: String
    let pubDate: TimeInterval
    let imageURL: String?
    let videoURL: String?
}

// MARK: - GossipTabView (TOP-LEVEL)

struct GossipTabView: View {
    // MARK: Post-related state
    @State private var rssArticles: [RSSArticle] = []
    @State private var userPosts: [UserPost] = []
    @State private var combinedFeed: [AnyIdentifiablePost] = []
    @State private var newPostText: String = ""
    @State private var editingPostId: String? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var selectedVideoURL: URL? = nil
    @State private var selectedMediaType: ImagePicker.MediaType? = nil // .image or .video
    @State private var trendingTags: [String] = []
    @State private var showAllTags = false
    @State private var selectedTagFilter: String? = nil
    @FocusState private var composerFocused: Bool

    // MARK: UI state
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var showImagePicker = false
    @State private var isLoading = true
    @State private var commentTargetPost: UserPost? = nil
    @State private var commentText: String = ""
    @State private var userProfiles: [String: (name: String, imageURL: String?)] = [:]
    @State private var isUploading: Bool = false
    @State private var posting: Bool = false

    // MARK: Infinite scroll (append in batches of 5)
    @State private var loadingMore: Bool = false
    @State private var visibleCount: Int = 5
    private let batchSize: Int = 5
    private let throttler = Throttler()

    // MARK: Cache locations
    private var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first! }
    private var postsCacheURL: URL { cacheDir.appendingPathComponent("gossip_user_posts.json") }
    private var rssCacheURL: URL { cacheDir.appendingPathComponent("gossip_rss_articles.json") }

    // MARK: Optional proxy (safe to ignore on iOS)
    private let proxyBase = "https://us-central1-wakandan-app.cloudfunctions.net/api/proxy?url="
    private func proxiedImageURL(_ imageUrl: String?) -> URL? {
        guard let raw = imageUrl, !raw.isEmpty else { return nil }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: proxyBase + encoded)
    }

    // MARK: RSS URLs (merged + de-duped)
    private let rssFeedURLs: [String] = [
        "https://swayafrica.com/category/Entertainment/feed/",
        "https://rss.app/feeds/MDlghVUX5yvecvRG.xml",
        "https://rss.app/feeds/wlHd9RRJ1VuDYpHX.xml/",
        "https://blackculture.com/news/rss/category/arts_and_entertainment",
        "https://media.rss.com/afrosinthediaspora/feed.xml",
        "https://digitalcollections.sit.edu/african_diaspora_research/announcements.html",
        "https://theshaderoom.com/latest-tea/feed/",
        "https://rss.app/feeds/hXAXAKLk6J0sbRX0.xml",
        "https://rss.app/feeds/a0BC3EgcQ2gi6jt9.xml",
        "https://www.pulse.ng/entertainment/rss",
        "https://www.theafricanmirror.africa/arts-and-entertainment/feed/",
        "https://www.africanexponent.com/rss/entertainment",
        "https://www.okayafrica.com/music/rss/",
        "https://celebrity.nine.com.au/rss",
        "https://www.allabouttrh.com/feed/",
        "https://bckonline.com/feed/",
        "https://balleralert.com/feed/",
        "https://rss.app/feeds/nsmT2WdQXSlshmcy.xml",
        "https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml",
        "https://rss.app/feeds/Vgjdsm6FBHT3mj4G.xml",
        "https://www.buzzfeed.com/celebrity.xml",
        "https://rss.app/feeds/3zTVOBAND5ezpD5g.xml",
        "https://sahiphopmag.co.za/feed/",
        "https://naijavibes.com/feed/",
        "https://tooxclusive.com/feed/",
        "https://www.ghanacelebrities.com/feed/",
        "https://theblackmedia.org/feed/",
        "https://afro.com/section/arts-entertainment/feed/",
        "https://globalgrind.com/category/entertainment/feed/",
        "https://www.thesouthafrican.com/culture/entertainment/",
        "https://rss.app/feeds/keM7mXLp4OlutaGg.xml",
        "https://rss.app/feeds/KwsTlmbvwXiY4YX6.xml",
        "https://rss.app/feeds/fQ6cY8V57Sk5ayox.xml"
    ]
    .reduce(into: [String]()) { acc, u in if !acc.contains(u) { acc.append(u) } }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView(
                onLogoTap: { reloadContent() },
                onSearchTap: {
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let root = scene.windows.first?.rootViewController else { return }
                    root.present(UIHostingController(rootView: SearchView()), animated: true)
                }
            )

            // Composer
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newPostText)
                        .focused($composerFocused)
                        .frame(minHeight: 60, maxHeight: 140)
                        .padding(8)
                        .foregroundColor(.white)
                        .background(Color(.systemGray6).opacity(0.18))
                        .cornerRadius(10)
                        // Dismiss keyboard when the last character typed is Return
                        .onChange(of: newPostText) { newVal in
                            guard newVal.last == "\n" else { return }
                            newPostText = newVal.trimmingCharacters(in: .newlines)
                            composerFocused = false
                        }

                    if newPostText.isEmpty {
                        Text(editingPostId == nil ? "What’s the gist? (use #tags)" : "Editing post...")
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 14)
                            .padding(.horizontal, 14)
                            .allowsHitTesting(false)
                    }
                }

                // Media preview (kept simple to avoid heavy type-checking)
                if let type = selectedMediaType {
                    if type == .image, let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                    } else if type == .video, let url = selectedVideoURL {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 220)
                            .cornerRadius(8)
                    }
                }

                // Buttons
                HStack(spacing: 16) {
                    Button(action: { showImagePicker = true }) {
                        Image(systemName: "photo.on.rectangle")
                            .padding(8)
                            .background(Color.gray.opacity(0.4))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }

                    Button(action: {
                        if let id = editingPostId {
                            updatePost(id)
                        } else {
                            postToFirebase()
                        }
                        composerFocused = false // hide keyboard on submit
                    }) {
                        Image(systemName: "paperplane.fill")
                            .padding(8)
                            .background(editingPostId == nil ? Color.blue : Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .toolbar { // keyboard accessory
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { composerFocused = false }
                }
            }

            Divider().background(Color.gray.opacity(0.3))

            // Trending tags
            if !trendingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(trendingTags, id: \.self) { tag in
                            Text(tag)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background((selectedTagFilter == tag ? Color.blue.opacity(0.7) : Color.gray.opacity(0.3)))
                                .foregroundColor(.white)
                                .cornerRadius(16)
                                .onTapGesture {
                                    selectedTagFilter = (selectedTagFilter == tag) ? nil : tag
                                    mergeContent()
                                    resetPaging()
                                }
                        }
                        Button(showAllTags ? "Less" : "More") {
                            showAllTags.toggle()
                            updateTrendingTags()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.3))
                        .foregroundColor(.blue)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }

                if let tag = selectedTagFilter {
                    HStack(spacing: 10) {
                        Text("Filtering by \(tag)")
                            .foregroundColor(.white.opacity(0.8))
                        Button("Clear") {
                            selectedTagFilter = nil
                            mergeContent()
                            resetPaging()
                        }
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
            }

            // Feed (append in batches of 5)
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading...")
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            let page = Array(pagedSlice(of: combinedFeed))
                            ForEach(page, id: \.id) { item in
                                item.view($selectedURL, $showWebView)
                                    .onAppear {
                                        if let lastId = page.last?.id, item.id == lastId {
                                            loadMoreIfNeeded()
                                        }
                                    }
                            }
                            if loadingMore {
                                ProgressView().padding(.vertical, 12)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            // 1) Show cached content instantly (if available)
            loadCache()
            // 2) Then refresh from network/backends
            reloadContent()
        }
        .sheet(isPresented: $showWebView) {
            if let url = selectedURL { WebView(url: url) }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(
                selectedImage: $selectedImage,
                selectedVideoURL: $selectedVideoURL,
                selectedMediaType: $selectedMediaType
            )
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

    // Async export/compress to MP4 (medium quality). Falls back to original if export fails.
    func exportVideoIfNeeded(inputURL: URL) async throws -> URL {
        let asset = AVAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            return inputURL
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    cont.resume(returning: outURL)
                case .failed, .cancelled:
                    cont.resume(returning: inputURL) // use original if export fails
                default:
                    cont.resume(returning: inputURL)
                }
            }
        }
    }

    // Write UIImage to temp as JPEG (async) to avoid big main-thread work
    func writeImageToTemp(_ image: UIImage, quality: CGFloat = 0.85) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "ImageWrite", code: -1, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // Simple async wrapper around Firebase Storage putFile
    func uploadFileURL(_ localURL: URL, path: String, contentType: String? = nil) async throws -> String {
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = contentType

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            ref.putFile(from: localURL, metadata: meta) { _, error in
                if let error = error { return cont.resume(throwing: error) }
                ref.downloadURL { url, err in
                    if let err = err { return cont.resume(throwing: err) }
                    cont.resume(returning: url?.absoluteString ?? "")
                }
            }
        }
    }

    // MARK: - CRUD + Comments + Likes + Share

    func reloadContent() {
        fetchFeedsInChunks()
        fetchUserPosts()
    }

    func postToFirebase() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        posting = true
        isUploading = true

        Task.detached(priority: .userInitiated) {
            do {
                var mediaURLString: String? = nil
                var mediaTypeString: String? = nil

                if selectedMediaType == .video, let inputURL = selectedVideoURL {
                    var needsStop = false
                    if inputURL.startAccessingSecurityScopedResource() {
                        needsStop = true
                    }
                    defer { if needsStop { inputURL.stopAccessingSecurityScopedResource() } }

                    let exportedURL = try await exportVideoIfNeeded(inputURL: inputURL)
                    let storagePath = "posts/\(uid)/videos/\(UUID().uuidString).mp4"
                    mediaURLString = try await uploadFileURL(exportedURL, path: storagePath, contentType: "video/mp4")
                    mediaTypeString = "video"

                    if exportedURL.path.contains(FileManager.default.temporaryDirectory.path) {
                        try? FileManager.default.removeItem(at: exportedURL)
                    }

                } else if selectedMediaType == .image, let image = selectedImage {
                    let tempURL = try writeImageToTemp(image, quality: 0.85)
                    let storagePath = "posts/\(uid)/images/\(UUID().uuidString).jpg"
                    mediaURLString = try await uploadFileURL(tempURL, path: storagePath, contentType: "image/jpeg")
                    mediaTypeString = "image"
                    try? FileManager.default.removeItem(at: tempURL)
                }

                // Build post payload
                let postId = UUID().uuidString
                let now = Date().timeIntervalSince1970
                var payload: [String: Any] = [
                    "id": postId,
                    "text": newPostText.trimmingCharacters(in: .whitespacesAndNewlines),
                    "timestamp": now,
                    "userId": uid
                ]
                if let murl = mediaURLString { payload["mediaURL"] = murl }
                if let mtype = mediaTypeString { payload["mediaType"] = mtype }

                // Write DB (Realtime Database — adjust path if needed)
                let ref = Database.database().reference()
                    .child("posts")
                    .child(postId)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    ref.setValue(payload) { error, _ in
                        if let error = error { return cont.resume(throwing: error) }
                        cont.resume(returning: ())
                    }
                }

                // Update UI on main
                await MainActor.run {
                    let newItem = UserPost(
                        id: postId,
                        text: payload["text"] as? String ?? "",
                        timestamp: now,
                        userId: uid,
                        mediaURL: mediaURLString,
                        mediaType: mediaTypeString
                    )
                    userPosts.insert(newItem, at: 0)
                    mergeContent()
                    resetPaging()

                    newPostText = ""
                    selectedImage = nil
                    selectedVideoURL = nil
                    selectedMediaType = nil
                    editingPostId = nil
                    posting = false
                    isUploading = false
                    composerFocused = false
                }

            } catch {
                await MainActor.run {
                    posting = false
                    isUploading = false
                    composerFocused = false
                    print("Post failed: \(error.localizedDescription)")
                }
            }
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
        selectedVideoURL = nil
        selectedMediaType = nil
        editingPostId = nil
        fetchUserPosts()
    }

    func deletePost(_ post: UserPost) {
        Database.database().reference()
            .child("posts").child(post.id)
            .removeValue { _, _ in fetchUserPosts() }
    }

    func postComment(to post: UserPost) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("comments").child(post.id).childByAutoId()
        ref.setValue([
            "userId": uid,
            "text": commentText,
            "timestamp": Date().timeIntervalSince1970
        ]) { _, _ in resetPostFields() }
    }

    func toggleLike(for id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let r = Database.database().reference().child("likes").child(id).child(uid)
        r.observeSingleEvent(of: .value) { snap in
            if snap.exists() { r.removeValue { _, _ in fetchUserPosts() } }
            else { r.setValue(true) { _, _ in fetchUserPosts() } }
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

    func updateTrendingTags() {
        var tagCount: [String: Int] = [:]
        for post in userPosts {
            for tag in extractHashtags(from: post.text) { tagCount[tag, default: 0] += 1 }
        }
        for article in rssArticles {
            let combined = "\(article.title) \(article.description)"
            for tag in extractHashtags(from: combined) { tagCount[tag, default: 0] += 1 }
        }
        trendingTags = Array(tagCount.sorted { $0.value > $1.value }.prefix(10).map { "#\($0.key)" })
    }

    /// Ensure we have a readable, local file URL (mp4) ready for upload.
    /// Handles ph:// assets, security-scoped URLs, and transcodes to mp4 if needed.
    private func preparedVideoFileURL(from inputURL: URL, completion: @escaping (URL?) -> Void) {
        func isReadableFile(_ url: URL) -> Bool {
            return url.isFileURL && FileManager.default.isReadableFile(atPath: url.path)
        }
        if isReadableFile(inputURL), inputURL.pathExtension.lowercased() == "mp4" {
            completion(inputURL)
            return
        }
        var didStartAccess = false
        if inputURL.startAccessingSecurityScopedResource() {
            didStartAccess = true
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let outURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            print("❌ AVAssetExportSession unavailable")
            if didStartAccess { inputURL.stopAccessingSecurityScopedResource() }
            completion(nil)
            return
        }
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            if didStartAccess { inputURL.stopAccessingSecurityScopedResource() }
            switch session.status {
            case .completed:
                completion(outURL)
            case .failed, .cancelled:
                print("❌ Video export failed: \(session.error?.localizedDescription ?? "unknown error")")
                completion(nil)
            default:
                completion(nil)
            }
        }
    }

    // MARK: - Fetch User Posts + Likes + Comments

    func fetchUserPosts(limit: UInt = 10) {
        let pRef = Database.database().reference().child("posts")
        let lRef = Database.database().reference().child("likes")
        let cRef = Database.database().reference().child("comments")
        guard let uid = Auth.auth().currentUser?.uid else { return }

        pRef.queryOrdered(byChild: "timestamp")
            .queryLimited(toLast: limit)
            .observeSingleEvent(of: .value) { snap in
                var arr: [UserPost] = []

                for case let cs as DataSnapshot in snap.children {
                    if let d = cs.value as? [String: Any],
                       let t = d["text"] as? String,
                       let ts = d["timestamp"] as? TimeInterval,
                       let u = d["userId"] as? String {
                        arr.append(UserPost(
                            id: cs.key, text: t, timestamp: ts, userId: u,
                            mediaURL: d["mediaURL"] as? String, mediaType: d["mediaType"] as? String
                        ))
                    }
                }

                lRef.observeSingleEvent(of: .value) { lsnap in
                    var liked: Set<String> = []
                    for case let ps as DataSnapshot in lsnap.children { if ps.hasChild(uid) { liked.insert(ps.key) } }

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

                        userPosts = arr.sorted { $0.timestamp > $1.timestamp }

                        // Profiles
                        let uniqueUserIds = Set(arr.map { $0.userId })
                        let usersRef = Database.database().reference().child("users")
                        for uid in uniqueUserIds {
                            usersRef.child(uid).observeSingleEvent(of: .value) { snapshot in
                                if let dict = snapshot.value as? [String: Any] {
                                    let name = dict["name"] as? String ?? "User"
                                    let img = dict["profileImageURL"] as? String
                                    DispatchQueue.main.async {
                                        userProfiles[uid] = (name, img)
                                        mergeContent()
                                        updateTrendingTags()
                                    }
                                }
                            }
                        }

                        // Save posts cache whenever we update posts
                        savePostsCache()
                    }
                }
            }
    }

    // MARK: - Optimized Fetch RSS Articles in Chunks

    func fetchFeedsInChunks(chunkSize: Int = 3) {
        Task {
            let chunks = chunkedArray(rssFeedURLs, size: chunkSize)
            for c in chunks {
                var chunkArticles: [RSSArticle] = []

                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in c { group.addTask { await fetchFeed(urlString: url) } }
                    for await articles in group { chunkArticles.append(contentsOf: articles) }
                }

                await MainActor.run {
                    let existingTitles = Set(rssArticles.map { $0.title })
                    let filtered = chunkArticles.filter { !existingTitles.contains($0.title) }
                    rssArticles.append(contentsOf: filtered)
                    mergeContent()
                    saveRSSCache()
                }
            }

            await MainActor.run {
                if combinedFeed.isEmpty { isLoading = false } else { isLoading = false }
            }
        }
    }

    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try FeedParser(data: data).parse()
            guard case .success(let feed) = result else { return [] }
            let items = feed.rssFeed?.items ?? []

            return items.prefix(3).compactMap { item -> RSSArticle? in
                guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let link = item.link,
                      let pubDate = item.pubDate else { return nil }

                let desc = extractPlainText(from: item.description ?? "")

                let enclosureURL = item.enclosure?.attributes?.url
                let mimeType = item.enclosure?.attributes?.type ?? ""
                let isVideo = mimeType.contains("video")

                let videoURL = isVideo ? enclosureURL.flatMap(URL.init) : nil

                var imageURL: URL? = nil
                if !isVideo {
                    if let urlStr = enclosureURL, let valid = URL(string: urlStr) { imageURL = valid }
                    else if let fallback = extractImageURL(from: item.description ?? ""), let valid = URL(string: fallback) { imageURL = valid }
                }

                return RSSArticle(
                    title: title,
                    link: link,
                    description: desc,
                    pubDate: pubDate,
                    imageURL: imageURL,
                    videoURL: videoURL
                )
            }
        } catch {
            print("❌ Error fetching/parsing \(urlString): \(error.localizedDescription)")
            return []
        }
    }

    func extractImageURL(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']",
                                                   options: .caseInsensitive),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (html as NSString).substring(with: match.range(at: 1))
    }

    // MARK: - Combine and Render Posts

    func mergeContent() {
        let filteredRSS: [AnyIdentifiablePost] = rssArticles
            .filter { article in
                guard let tag = selectedTagFilter?.lowercased() else { return true }
                return article.title.lowercased().contains(tag) || article.description.lowercased().contains(tag)
            }
            .map { article in
                AnyIdentifiablePost(timestamp: article.pubDate.timeIntervalSince1970, id: article.title) {
                    Button(action: {
                        selectedURL = URL(string: article.link)
                        showWebView = true
                    }) {
                        RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

        let filteredUserPosts: [AnyIdentifiablePost] = userPosts
            .filter { post in
                guard let tag = selectedTagFilter?.lowercased() else { return true }
                return post.text.lowercased().contains(tag)
            }
            .map { post in
                let profile = userProfiles[post.userId]
                let displayName = profile?.name ?? "User"

                return AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayName).foregroundColor(.white).font(.subheadline)
                            Spacer()
                        }
                        TextWithHashtagsView(text: post.text) { tappedTag in
                            selectedTagFilter = tappedTag
                            mergeContent()
                            resetPaging()
                        }
                        .padding(.vertical, 4)

                        if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                            if post.mediaType == "video" {
                                VideoPlayer(player: AVPlayer(url: url)).frame(height: 200).cornerRadius(10)
                            } else {
                                AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(maxHeight: 200).cornerRadius(10)
                            }
                        }

                        Text(post.dateFormatted).font(.caption).foregroundColor(.gray)

                        HStack(spacing: 20) {
                            Button(action: { toggleLike(for: post.id) }) {
                                Image(systemName: "hand.thumbsup").foregroundColor(post.isLikedByCurrentUser ? .blue : .gray)
                            }
                            Button(action: { commentTargetPost = post }) {
                                Image(systemName: "bubble.right").foregroundColor(.gray)
                            }
                            Button(action: { sharePost(post) }) {
                                Image(systemName: "square.and.arrow.up").foregroundColor(.gray)
                            }
                            if post.userId == Auth.auth().currentUser?.uid {
                                Button(action: { newPostText = post.text; editingPostId = post.id }) {
                                    Image(systemName: "pencil").foregroundColor(.yellow)
                                }
                                Button(role: .destructive, action: { deletePost(post) }) {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.top, 4)

                        if !post.comments.isEmpty {
                            ForEach(post.comments) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.text).font(.caption).foregroundColor(.white)
                                    Text(Date(timeIntervalSince1970: c.timestamp), style: .time).font(.caption2).foregroundColor(.gray)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

        DispatchQueue.main.async {
            withAnimation {
                combinedFeed = (filteredUserPosts + filteredRSS)
                    .sorted { $0.timestamp > $1.timestamp }
                visibleCount = min(max(visibleCount, batchSize), combinedFeed.count)
                if !combinedFeed.isEmpty { isLoading = false }
            }
        }
    }

    // MARK: - Paging

    private func resetPaging() { visibleCount = min(batchSize, combinedFeed.count) }
    private func pagedSlice<T>(of array: [T]) -> ArraySlice<T> { array[0..<min(visibleCount, array.count)] }
    private func loadMoreIfNeeded() {
        throttler.throttle("loadMore", interval: 0.5) {
            guard !loadingMore, visibleCount < combinedFeed.count else { return }
            loadingMore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                visibleCount = min(visibleCount + batchSize, combinedFeed.count)
                loadingMore = false
            }
        }
    }

    // MARK: - Cache: Save / Load

    private func savePostsCache() {
        let toCache: [CachedUserPost] = userPosts.map { p in
            .init(
                id: p.id, text: p.text, timestamp: p.timestamp, userId: p.userId,
                mediaURL: p.mediaURL, mediaType: p.mediaType,
                isLikedByCurrentUser: p.isLikedByCurrentUser,
                comments: p.comments.map { .init(id: $0.id, userId: $0.userId, text: $0.text, timestamp: $0.timestamp) }
            )
        }
        do {
            let data = try JSONEncoder().encode(toCache)
            try data.write(to: postsCacheURL, options: .atomic)
        } catch { print("❌ Failed to save posts cache:", error.localizedDescription) }
    }

    private func saveRSSCache() {
        let toCache: [CachedRSSArticle] = rssArticles.map { a in
            .init(
                title: a.title, link: a.link, description: a.description,
                pubDate: a.pubDate.timeIntervalSince1970,
                imageURL: a.imageURL?.absoluteString,
                videoURL: a.videoURL?.absoluteString
            )
        }
        do {
            let data = try JSONEncoder().encode(toCache)
            try data.write(to: rssCacheURL, options: .atomic)
        } catch { print("❌ Failed to save RSS cache:", error.localizedDescription) }
    }

    private func loadCache() {
        var cachedRSS: [RSSArticle] = []
        var cachedPosts: [UserPost] = []

        if let data = try? Data(contentsOf: rssCacheURL),
           let arr = try? JSONDecoder().decode([CachedRSSArticle].self, from: data) {
            cachedRSS = arr.map {
                RSSArticle(
                    title: $0.title,
                    link: $0.link,
                    description: $0.description,
                    pubDate: Date(timeIntervalSince1970: $0.pubDate),
                    imageURL: $0.imageURL.flatMap(URL.init),
                    videoURL: $0.videoURL.flatMap(URL.init)
                )
            }
        }

        if let data = try? Data(contentsOf: postsCacheURL),
           let arr = try? JSONDecoder().decode([CachedUserPost].self, from: data) {
            cachedPosts = arr.map { c in
                var p = UserPost(
                    id: c.id, text: c.text, timestamp: c.timestamp, userId: c.userId,
                    mediaURL: c.mediaURL, mediaType: c.mediaType
                )
                p.isLikedByCurrentUser = c.isLikedByCurrentUser
                p.comments = c.comments.map { .init(id: $0.id, userId: $0.userId, text: $0.text, timestamp: $0.timestamp) }
                return p
            }
        }

        if !cachedRSS.isEmpty || !cachedPosts.isEmpty {
            rssArticles = cachedRSS
            userPosts = cachedPosts
            mergeContent()
            resetPaging()
            isLoading = false // show cached immediately
        }
    }

    // MARK: - Helpers

    func extractHashtags(from text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "#(\\w+)", options: [])
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) ?? []
        return matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).lowercased() } }
    }

    func extractPlainText(from html: String) -> String {
        guard let data = html.data(using: .utf8) else {
            return html.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
            return html.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
    }

    private func chunkedArray<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        var res: [[T]] = []
        var idx = 0
        while idx < array.count {
            let end = min(idx + size, array.count)
            res.append(Array(array[idx..<end]))
            idx = end
        }
        return res
    }
}

// MARK: - Hashtag text renderer

struct TextWithHashtagsView: View {
    let text: String
    let onHashtagTap: (String) -> Void

    var body: some View {
        let words = text.split(separator: " ")
        WrapHStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                if word.hasPrefix("#") {
                    let tag = String(word)
                    Text(tag)
                        .foregroundColor(.blue)
                        .bold()
                        .onTapGesture { onHashtagTap(tag.lowercased().trimmingCharacters(in: ["#"])) }
                } else {
                    Text(String(word)).foregroundColor(.white)
                }
            }
        }
    }
}

struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content
    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
    }
}

// MARK: - Lightweight throttler

private final class Throttler {
    private var workItems: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "Gossip.Throttler", qos: .userInitiated)
    func throttle(_ key: String, interval: TimeInterval, action: @escaping () -> Void) {
        guard workItems[key] == nil else { return }
        let item = DispatchWorkItem { [weak self] in action(); self?.workItems[key] = nil }
        workItems[key] = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }
}
