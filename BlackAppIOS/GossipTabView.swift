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

// MARK: - Avatar

struct AvatarView: View {
    let urlString: String?
    var size: CGFloat = 36

    var body: some View {
        if let s = urlString, let url = URL(string: s) {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.gray.opacity(0.25))
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            // Fallback placeholder avatar
            Circle()
                .fill(Color.gray.opacity(0.25))
                .overlay(Image(systemName: "person.fill")
                    .foregroundColor(.white.opacity(0.85)))
                .frame(width: size, height: size)
        }
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

// MARK: - Cache DTOs

private struct CachedUserPost: Codable {
    struct Cmt: Codable { let id: String; let userId: String; let text: String; let timestamp: TimeInterval }
    let id: String, text: String, timestamp: TimeInterval, userId: String
    let mediaURL: String?, mediaType: String?
    let isLikedByCurrentUser: Bool
    let comments: [Cmt]
}

private struct CachedGossipArticle: Codable {
    let title: String
    let link: String
    let description: String
    let pubDate: TimeInterval
    let imageURL: String?
    let videoURL: String?
}

// MARK: - Gossip Article

struct GossipArticle: Identifiable, Hashable {
    let id: String = UUID().uuidString
    let title: String
    let link: String
    let description: String
    let pubDate: Date
    let imageURL: URL?
    let videoURL: URL?
}

// MARK: - Feed Source

enum FeedKind { case nightlife, news }

struct FeedSource: Hashable {
    let url: String
    let kind: FeedKind
    let maxItems: Int
}

// MARK: - GossipTabView

struct GossipTabView: View {
    // Posts
    @State private var userPosts: [UserPost] = []
    @State private var combinedFeed: [AnyIdentifiablePost] = []
    @State private var rssArticles: [GossipArticle] = []

    // Composer
    @State private var newPostText: String = ""
    @State private var editingPostId: String? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var selectedVideoURL: URL? = nil
    @State private var selectedMediaType: ImagePicker.MediaType? = nil
    @FocusState private var composerFocused: Bool

    // Tags
    @State private var trendingTags: [String] = []
    @State private var showAllTags = false
    @State private var selectedTagFilter: String? = nil

    // UI
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var showImagePicker = false
    @State private var isLoading = true
    @State private var commentTargetPost: UserPost? = nil
    @State private var commentText: String = ""
    @State private var userProfiles: [String: (name: String, imageURL: String?)] = [:]
    @State private var isUploading: Bool = false
    @State private var posting: Bool = false

    // Paging
    @State private var loadingMore: Bool = false
    @State private var visibleCount: Int = 5
    private let batchSize: Int = 5
    private let throttler = Throttler()

    // Cache
    private var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first! }
    private var postsCacheURL: URL { cacheDir.appendingPathComponent("gossip_user_posts.json") }
    private var rssCacheURL: URL { cacheDir.appendingPathComponent("gossip_rss_articles.json") }

    // Optional proxy (unchanged)
    private let proxyBase = "https://us-central1-wakandan-app.cloudfunctions.net/api/proxy?url="
    private func proxiedImageURL(_ imageUrl: String?) -> URL? {
        guard let raw = imageUrl, !raw.isEmpty else { return nil }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: proxyBase + encoded)
    }

    // MARK: Sources — 100% Afro‑diaspora; nightlife‑leaning (~80% nightlife, ~20% news)
    private var nightlifeFeeds: [FeedSource] = [
        .init(url: "https://www.bellanaija.com/category/events/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "https://www.dancehallmag.com/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "https://urbanislandz.com/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "https://notjustok.com/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "https://naijavibes.com/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "https://tooxclusive.com/feed/", kind: .nightlife, maxItems: 3),
        .init(url: "http://www.okayafrica.com/feeds/music.rss", kind: .nightlife, maxItems: 2),
        .init(url: "https://www.thesouthafrican.com/culture/entertainment/feed/", kind: .nightlife, maxItems: 2),
        .init(url: "https://www.largeup.com/feed/", kind: .nightlife, maxItems: 2),
        .init(url: "https://thesource.com/feed/", kind: .nightlife, maxItems: 2)
    ]

    private var newsFeeds: [FeedSource] = [
        .init(url: "https://allafrica.com/tools/headlines/rdf/entertainment/headlines.rdf", kind: .news, maxItems: 2),
        .init(url: "https://www.africanews.com/feed/rss", kind: .news, maxItems: 2),
        .init(url: "https://www.bellanaija.com/feed/", kind: .news, maxItems: 2),
        .init(url: "https://www.pulse.ng/entertainment/rss", kind: .news, maxItems: 2)
    ]

    private var weightedFeedOrder: [FeedSource] {
        var ordered: [FeedSource] = []
        var n = nightlifeFeeds, e = newsFeeds
        var ni = 0, ei = 0
        while ni < n.count || ei < e.count {
            for _ in 0..<4 where ni < n.count { ordered.append(n[ni]); ni += 1 }
            if ei < e.count { ordered.append(e[ei]); ei += 1 }
        }
        return ordered
    }

    private let nightlifeKeywords: [String] = [
        "party","nightlife","club","lounge","dj","soundsystem","sound system","mixtape","set",
        "concert","live","show","tour","gig","festival","rave","block party","afterparty",
        "dancefloor","dance floor","dance","stage","arena","hall","stadium","tickets","doors","hosted by"
    ]

    private let rssTimeout: TimeInterval = 3.5
    private let perChunkParallelism = 3

    var body: some View {
        VStack(spacing: 0) {
            EmailVerificationBanner()
            TopToolbarView(
                onLogoTap: { reloadContent() },
                onSearchTap: {
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let root = scene.windows.first?.rootViewController else { return }
                    root.present(UIHostingController(rootView: SearchView()), animated: true)
                }
            )

            // MARK: Composer — uses your working placeholder, but one-line then expands
            VStack(spacing: 8) {
                // Decide if editor should expand (focus, media, or non-empty text)
                let expanded = composerFocused
                    || selectedMediaType != nil
                    || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                ZStack(alignment: .topLeading) {
                    // TextEditor MUST be first so the placeholder can overlay it (like your original)
                    TextEditor(text: $newPostText)
                        .focused($composerFocused)
                        // one-line collapsed (36), expands when focused/has text/has media
                        .frame(
                            minHeight: (composerFocused
                                        || selectedMediaType != nil
                                        || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 88 : 36,
                            maxHeight: (composerFocused
                                        || selectedMediaType != nil
                                        || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 140 : 36
                        )
                        .padding(8)
                        .foregroundColor(.white)
                        .background(Color(.systemGray6).opacity(0.18))
                        .cornerRadius(10)
                        // your original "Return to dismiss" behavior
                        .onChange(of: newPostText) { newVal in
                            guard newVal.last == "\n" else { return }
                            newPostText = newVal.trimmingCharacters(in: .newlines)
                            composerFocused = false
                        }

                    // Placeholder must be AFTER the TextEditor so it sits above it (your original approach)
                    if newPostText.isEmpty && selectedMediaType == nil {
                        Text(editingPostId == nil ? "What’s the gist? (use #tags)" : "Editing post...")
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 14)
                            .padding(.horizontal, 14)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: composerFocused || selectedMediaType != nil || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Media preview (unchanged)
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

                // Buttons (unchanged)
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
            .toolbar {
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

            // Feed
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
                            let page: [AnyIdentifiablePost] = Array(pagedSlice(of: combinedFeed))
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
            loadCache()        // instant paint
            reloadContent()    // refresh
        }
        .sheet(isPresented: $showWebView) {
            if let url = selectedURL { GossipWebView(url: url) }
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

    // MARK: - Video export & image write

    private func exportVideoIfNeeded(inputURL: URL) async throws -> URL {
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
                case .completed: cont.resume(returning: outURL)
                case .failed, .cancelled: cont.resume(returning: inputURL)
                default: cont.resume(returning: inputURL)
                }
            }
        }
    }

    private func writeImageToTemp(_ image: UIImage, quality: CGFloat = 0.85) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw NSError(domain: "ImageWrite", code: -1, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func uploadFileURL(_ localURL: URL, path: String, contentType: String? = nil) async throws -> String {
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

    private func reloadContent() {
        isLoading = combinedFeed.isEmpty
        fetchFeedsWeighted()
        fetchUserPosts()
    }

    private func postToFirebase() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        posting = true
        isUploading = true

        Task.detached(priority: .userInitiated) {
            do {
                var mediaURLString: String? = nil
                var mediaTypeString: String? = nil

                if selectedMediaType == .video, let inputURL = selectedVideoURL {
                    var needsStop = false
                    if inputURL.startAccessingSecurityScopedResource() { needsStop = true }
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

                let ref = Database.database().reference().child("posts").child(postId)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    ref.setValue(payload) { error, _ in
                        if let error = error { return cont.resume(throwing: error) }
                        cont.resume(returning: ())
                    }
                }

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

    private func updatePost(_ id: String) {
        let ref = Database.database().reference().child("posts").child(id)
        ref.updateChildValues(["text": newPostText]) { _, _ in
            resetPostFields()
        }
    }

    private func resetPostFields() {
        newPostText = ""
        selectedImage = nil
        selectedVideoURL = nil
        selectedMediaType = nil
        editingPostId = nil
        fetchUserPosts()
    }

    private func deletePost(_ post: UserPost) {
        Database.database().reference()
            .child("posts").child(post.id)
            .removeValue { _, _ in fetchUserPosts() }
    }

    private func postComment(to post: UserPost) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("comments").child(post.id).childByAutoId()
        ref.setValue([
            "userId": uid,
            "text": commentText,
            "timestamp": Date().timeIntervalSince1970
        ]) { _, _ in resetPostFields() }
    }

    private func toggleLike(for id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let r = Database.database().reference().child("likes").child(id).child(uid)
        r.observeSingleEvent(of: .value) { snap in
            if snap.exists() { r.removeValue { _, _ in fetchUserPosts() } }
            else { r.setValue(true) { _, _ in fetchUserPosts() } }
        }
    }

    private func sharePost(_ post: UserPost) {
        guard let root = UIApplication.shared.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [post.text], applicationActivities: nil), animated: true)
    }

    private func shareArticle(_ article: GossipArticle) {
        guard let url = URL(string: article.link),
              let root = UIApplication.shared.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    private func updateTrendingTags() {
        var tagCount: [String: Int] = [:]
        for post in userPosts {
            for tag in extractHashtags(from: post.text) { tagCount[tag, default: 0] += 1 }
        }
        for article in rssArticles {
            let combined = "\(article.title) \(article.description)"
            for tag in extractHashtags(from: combined) { tagCount[tag, default: 0] += 1 }
        }
        trendingTags = Array(tagCount.sorted { $0.value > $1.value }.prefix(showAllTags ? 24 : 10).map { "#\($0.key)" })
    }

    // MARK: - User Posts + Profiles

    private func fetchUserPosts(limit: UInt = 10) {
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

                        savePostsCache()
                    }
                }
            }
    }

    // MARK: - Fast/Weighted RSS Fetch (+nightlife classifier & media requirement)

    private func fetchFeedsWeighted() {
        Task.detached(priority: .userInitiated) {
            let all = weightedFeedOrder
            let chunks = chunkedArray(all, size: perChunkParallelism)
            for group in chunks {
                var groupArticles: [GossipArticle] = []

                await withTaskGroup(of: [GossipArticle].self) { tg in
                    for feed in group {
                        tg.addTask { await fetchFeed(urlString: feed.url, limit: feed.maxItems, expectedKind: feed.kind) }
                    }
                    for await arts in tg { groupArticles.append(contentsOf: arts) }
                }

                await MainActor.run {
                    let existingLinks = Set(rssArticles.map { $0.link })
                    let fresh = groupArticles.filter { !existingLinks.contains($0.link) }

                    rssArticles.append(contentsOf: fresh)
                    rssArticles = enforceMix(rssArticles) // keep 80/20 bias

                    mergeContent()
                    saveRSSCache()
                    isLoading = false
                }
            }
        }
    }

    private func enforceMix(_ items: [GossipArticle]) -> [GossipArticle] {
        let nightlife = items.filter { isNightlife($0) }
        let news      = items.filter { !isNightlife($0) }
        let total = max(items.count, 1)
        let maxNight = Int(Double(total) * 0.8)
        let maxNews  = Int(Double(total) * 0.2)
        let nightSlice = Array(nightlife.sorted { $0.pubDate > $1.pubDate }.prefix(maxNight))
        let newsSlice  = Array(news.sorted { $0.pubDate > $1.pubDate }.prefix(maxNews))
        return (nightSlice + newsSlice).sorted { $0.pubDate > $1.pubDate }
    }

    private func isNightlife(_ a: GossipArticle) -> Bool {
        let hay = (a.title + " " + a.description).lowercased()
        return nightlifeKeywords.contains { kw in hay.contains(kw) }
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = rssTimeout
        cfg.timeoutIntervalForResource = rssTimeout
        return URLSession(configuration: cfg)
    }

    private func fetchFeed(urlString: String, limit: Int = 3, expectedKind: FeedKind) async -> [GossipArticle] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let session = makeSession()
            let (data, _) = try await session.data(from: url)

            let parser = FeedParser(data: data)
            switch parser.parse() {
            case .success(let feed):
                var articles: [GossipArticle] = []
                if let rss = feed.rssFeed {
                    articles = (rss.items ?? []).compactMap { mapRSSItem($0) }
                } else if let atom = feed.atomFeed {
                    articles = (atom.entries ?? []).compactMap { mapAtomEntry($0) }
                } else if let rdf = feed.rssFeed {
                    articles = (rdf.items ?? []).compactMap { mapRSSItem($0) }
                }

                // Require image or video for external items
                articles = articles.filter { $0.imageURL != nil || $0.videoURL != nil }

                // Bias to expected kind while honoring limit
                if expectedKind == .nightlife {
                    let nl = articles.filter { isNightlife($0) }
                    let non = articles.filter { !isNightlife($0) }
                    return Array((nl + non).prefix(limit))
                } else {
                    let non = articles.filter { !isNightlife($0) }
                    let nl = articles.filter { isNightlife($0) }
                    return Array((non + nl).prefix(limit))
                }
            case .failure:
                return []
            }
        } catch {
            print("❌ Error fetching \(urlString): \(error.localizedDescription)")
            return []
        }
    }

    private func mapRSSItem(_ item: RSSFeedItem) -> GossipArticle? {
        guard
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            let link = item.link
        else { return nil }

        let pub = item.pubDate ?? item.dublinCore?.dcDate ?? Date()
        let descHTML = item.description ?? item.content?.contentEncoded ?? ""
        let desc = extractPlainText(from: descHTML)

        let enclosureURL = item.enclosure?.attributes?.url
        let mimeType = item.enclosure?.attributes?.type ?? ""
        let isVideo = mimeType.contains("video")

        var imageURL: URL? = nil
        var videoURL: URL? = nil

        if isVideo, let v = enclosureURL, let vURL = URL(string: v) {
            videoURL = vURL
        } else {
            if let e = enclosureURL, let u = URL(string: e) { imageURL = u }
            else if let media = item.media?.mediaThumbnails?.first?.attributes?.url, let u = URL(string: media) { imageURL = u }
            else if let mediaC = item.media?.mediaContents?.first?.attributes?.url, let u = URL(string: mediaC) { imageURL = u }
            else if let fallback = extractImageURL(from: descHTML), let u = URL(string: fallback) { imageURL = u }
        }

        if imageURL == nil && videoURL == nil { return nil }

        return GossipArticle(
            title: title,
            link: link,
            description: desc,
            pubDate: pub,
            imageURL: imageURL,
            videoURL: videoURL
        )
    }

    private func mapAtomEntry(_ entry: AtomFeedEntry) -> GossipArticle? {
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let link = entry.links?.first?.attributes?.href ?? ""
        guard !link.isEmpty else { return nil }
        let pub = entry.published ?? entry.updated ?? Date()
        let descHTML = entry.summary?.value ?? entry.content?.value ?? ""
        let desc = extractPlainText(from: descHTML)

        var imageURL: URL? = nil
        if let thumb = entry.media?.mediaThumbnails?.first?.attributes?.url, let u = URL(string: thumb) { imageURL = u }
        else if let fallback = extractImageURL(from: descHTML), let u = URL(string: fallback) { imageURL = u }

        if imageURL == nil { return nil }

        return GossipArticle(
            title: title,
            link: link,
            description: desc,
            pubDate: pub,
            imageURL: imageURL,
            videoURL: nil
        )
    }

    private func extractImageURL(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']",
                                                   options: .caseInsensitive),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (html as NSString).substring(with: match.range(at: 1))
    }

    // MARK: - Combine & Render (STRICT ALTERNATION)

    private func mergeContent() {
        // External (RSS) cards (media already enforced)
        let rssCards: [AnyIdentifiablePost] = rssArticles
            .filter { a in
                (a.imageURL != nil || a.videoURL != nil)
                && matchesSelectedTag("\(a.title) \(a.description)", selected: selectedTagFilter)
            }
            .sorted { $0.pubDate > $1.pubDate }
            .map { (article: GossipArticle) in   // <- make it GossipArticle
                AnyIdentifiablePost(timestamp: article.pubDate.timeIntervalSince1970, id: article.id) {
                    Button {
                        selectedURL = URL(string: article.link)
                        showWebView = true
                    } label: {
                        GossipRSSCardView(                        // <- use the Gossip card
                            article: article,
                            selectedURL: $selectedURL,
                            showWebView: $showWebView
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

        // User post cards (media optional)
        let userCards: [AnyIdentifiablePost] = userPosts
            .filter { post in
                matchesSelectedTag(post.text, selected: selectedTagFilter)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .map { post in
                let profile = userProfiles[post.userId]
                let displayName = profile?.name ?? "User"

                return AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                    VStack(alignment: .leading, spacing: 4) {

                        // Header with avatar + name + timestamp
                        HStack(alignment: .center, spacing: 10) {
                            AvatarView(urlString: profile?.imageURL, size: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline).bold()
                                Text(post.dateFormatted)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }

                            Spacer()
                        }

                        // Body text with tappable hashtags
                        TextWithHashtagsView(text: post.text) { tappedTag in
                            selectedTagFilter = tappedTag
                            mergeContent()
                            resetPaging()
                        }
                        .padding(.vertical, 4)

                        // Optional user media (allowed to be absent for user posts)
                        if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                            if post.mediaType == "video" {
                                VideoPlayer(player: AVPlayer(url: url))
                                    .frame(height: 200)
                                    .cornerRadius(10)
                            } else {
                                AsyncImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(maxHeight: 200)
                                .clipped()
                                .cornerRadius(10)
                            }
                        }

                        // Footer actions
                        HStack(spacing: 20) {
                            Button(action: { toggleLike(for: post.id) }) {
                                Image(systemName: "hand.thumbsup")
                                    .foregroundColor(post.isLikedByCurrentUser ? .blue : .gray)
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

                        // Comments
                        if !post.comments.isEmpty {
                            ForEach(post.comments) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.text).font(.caption).foregroundColor(.white)
                                    Text(Date(timeIntervalSince1970: c.timestamp), style: .time)
                                        .font(.caption2).foregroundColor(.gray)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

        // Alternate strictly, starting with whichever is newest
        let alternated = buildAlternating(user: userCards, external: rssCards)

        DispatchQueue.main.async {
            withAnimation {
                combinedFeed = alternated
                visibleCount = min(max(visibleCount, batchSize), combinedFeed.count)
                if !combinedFeed.isEmpty { isLoading = false }
            }
        }
    }

    private enum NextPick { case user, external }

    /// Strict alternation: start with the newest of the two heads, then alternate; append leftovers.
    private func buildAlternating(user: [AnyIdentifiablePost], external: [AnyIdentifiablePost]) -> [AnyIdentifiablePost] {
        var i = 0, j = 0
        var out: [AnyIdentifiablePost] = []
        guard !(user.isEmpty && external.isEmpty) else { return out }

        // Decide who starts by comparing newest heads
        let nextStart: NextPick = {
            let uTs = user.first?.timestamp ?? -1
            let eTs = external.first?.timestamp ?? -1
            return (uTs >= eTs) ? .user : .external
        }()

        var next = nextStart
        while i < user.count && j < external.count {
            switch next {
            case .user:
                out.append(user[i]); i += 1; next = .external
            case .external:
                out.append(external[j]); j += 1; next = .user
            }
        }
        if i < user.count { out.append(contentsOf: user[i...]) }
        if j < external.count { out.append(contentsOf: external[j...]) }
        return out
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

    // MARK: - Cache

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
        let toCache: [CachedGossipArticle] = rssArticles.map { a in
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
        var cachedRSS: [GossipArticle] = []
        var cachedPosts: [UserPost] = []

        if let data = try? Data(contentsOf: rssCacheURL),
           let arr = try? JSONDecoder().decode([CachedGossipArticle].self, from: data) {
            cachedRSS = arr.map {
                GossipArticle(
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
            rssArticles = enforceMix(cachedRSS)
            userPosts = cachedPosts
            mergeContent()
            resetPaging()
            isLoading = false
        }
    }

    // MARK: - Helpers

    private func extractHashtags(from text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: "#(\\w+)", options: [])
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) ?? []
        return matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).lowercased() } }
    }

    private func extractPlainText(from html: String) -> String {
        guard let data = html.data(using: .utf8) else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
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

// Extract lowercase hashtags (without the leading '#') from any text
private func extractHashtags(from text: String) -> [String] {
    let pattern = "#(\\w+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    return matches.compactMap { match in
        guard match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range).lowercased()
    }
}

// Tag/category matching without CMTag/CMTypedTag
private func matchesSelectedTag(_ text: String, selected: String?) -> Bool {
    guard let selected = selected?
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    else { return true } // no filter → match all

    let tags = extractHashtags(from: text) // already lowercase
    if tags.contains(selected) { return true }
    return text.lowercased().contains(selected)
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

// MARK: - Card + WebView

struct GossipRSSCardView: View {
    let article: GossipArticle
    @Binding var selectedURL: URL?
    @Binding var showWebView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imgURL = article.imageURL {
                AsyncImage(url: imgURL) { phase in
                    switch phase {
                    case .empty:
                        ZStack { Rectangle().fill(Color.gray.opacity(0.2)); ProgressView() }
                            .frame(height: 180)
                            .cornerRadius(12)
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(height: 180).clipped()
                            .cornerRadius(12)
                    case .failure(_):
                        Rectangle().fill(Color.gray.opacity(0.2))
                            .frame(height: 180)
                            .cornerRadius(12)
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.2))
                            .frame(height: 180)
                            .cornerRadius(12)
                    }
                }
            } else if let v = article.videoURL {
                VideoPlayer(player: AVPlayer(url: v))
                    .frame(height: 200)
                    .cornerRadius(12)
            }

            Text(article.title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(3)

            Text(article.description)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(3)

            HStack(spacing: 16) {
                Button {
                    selectedURL = URL(string: article.link)
                    showWebView = true
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .foregroundColor(.blue)

                Button {
                    if let url = URL(string: article.link),
                       let root = UIApplication.shared.windows.first?.rootViewController {
                        root.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .foregroundColor(.gray)
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

struct GossipWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .black
        return wv
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        webView.load(req)
    }
}
