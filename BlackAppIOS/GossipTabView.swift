import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import FirebaseAppCheck          // ✅ App Check header for Cloud Function call
import WebKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

// ===============================================
// MARK: - Cloud Functions base
// ===============================================
private enum CloudFunctions {
    // Set your GCP project id here (used by index.js): e.g. "blackappios"
    static let projectId = "blackappios"
    static let base = "https://us-central1-\(projectId).cloudfunctions.net"
    static let rssBundle = base + "/rssBundle" // POST
    // imgThumb is embedded by rssBundle as absolute URLs in `thumb` field
}

// ===============================================
// MARK: - Cached remote image (HTTPS only)
// ===============================================
struct CachedRemoteImage: View {
    let urlString: String
    let contentMode: ContentMode
    @State private var uiImage: UIImage?

    init(_ urlString: String, contentMode: ContentMode = .fill) {
        self.urlString = urlString
        self.contentMode = contentMode
    }
    var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay(ProgressView().progressViewStyle(.circular))
            }
        }
        .task(id: urlString) {
            guard let url = URL(string: urlString) else { return }
            ImageStore.shared.load(from: url, key: urlString) { img in
                withAnimation(.easeOut(duration: 0.15)) { uiImage = img }
            }
        }
    }
}

// ===============================================
// MARK: - Avatar (cached, dynamic)
// ===============================================
struct AvatarView: View {
    let urlString: String?
    var size: CGFloat = 36
    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.white.opacity(0.85))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: urlString ?? "") {
            guard let s = urlString, let url = URL(string: s) else {
                uiImage = nil
                return
            }
            ImageStore.shared.load(from: url, key: s) { img in
                withAnimation(.easeOut(duration: 0.15)) { uiImage = img }
            }
        }
    }
}

// ===============================================
// MARK: - Twitter-like UserPost Model
// ===============================================
struct UserPost: Identifiable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let userId: String
    var mediaURL: String?
    var mediaType: String? // "image", "video"

    // Interactions
    var isLikedByCurrentUser: Bool = false
    var hasRepostedByCurrentUser: Bool = false

    // Counters
    var likeCount: Int = 0
    var commentCount: Int = 0
    var repostCount: Int = 0

    // Comments
    var comments: [Comment] = []

    // Repost / Quote
    var originalPostId: String?
    var quoteText: String?

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

// ===============================================
// MARK: - Bundle Feed (Server items)
// ===============================================
enum FeedKind: String, Codable { case nightlife, news }

struct FeedSource: Hashable, Codable {
    let url: String
    let kind: FeedKind
}

struct BundleItem: Identifiable, Codable {
    let id: String
    let title: String
    let link: String
    let summary: String
    let pubDate: TimeInterval // milliseconds since epoch
    let image: String?
    let thumb: String?
    let aspect: Double?
    let kind: FeedKind
    let source: String
}

struct GossipArticle: Identifiable, Hashable {
    let id: String
    let title: String
    let link: String
    let description: String
    let pubDate: Date
    let thumbURL: URL?
    let imageURL: URL?
    let kind: FeedKind
}

// ===============================================
// MARK: - AnyIdentifiablePost Wrapper
// ===============================================
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

// ===============================================
// MARK: - Cache DTOs
// ===============================================
private struct CachedUserPost: Codable {
    struct Cmt: Codable { let id: String; let userId: String; let text: String; let timestamp: TimeInterval }
    let id: String, text: String, timestamp: TimeInterval, userId: String
    let mediaURL: String?, mediaType: String?
    let isLikedByCurrentUser: Bool
    let hasRepostedByCurrentUser: Bool
    let likeCount: Int
    let commentCount: Int
    let repostCount: Int
    let originalPostId: String?
    let quoteText: String?
    let comments: [Cmt]
}

private struct CachedGossipArticle: Codable {
    let id: String
    let title: String
    let link: String
    let description: String
    let pubDate: TimeInterval
    let thumbURL: String?
    let imageURL: String?
    let kind: String
}

// ===============================================
// MARK: - Gossip Tab
// ===============================================
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
    @State private var composerVideoPlayer: AVPlayer? = nil
    
    // 👇 IG-style post composer (opens when LiveCaptureView posts inviteOrbCapturedMedia)
    @State private var showComposer = false
    @State private var composerImage: UIImage? = nil
    @State private var composerVideoURL: URL? = nil
    @State private var composerFilter: String = "none"
    
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
    
    // MARK: Sources (we’ll send these to rssBundle; the server does the heavy lifting)
    private var nightlifeFeeds: [FeedSource] = [
        .init(url: "https://www.bellanaija.com/category/events/feed/", kind: .nightlife),
        .init(url: "https://www.dancehallmag.com/feed/", kind: .nightlife),
        .init(url: "https://urbanislandz.com/feed/", kind: .nightlife),
        .init(url: "https://notjustok.com/feed/", kind: .nightlife),
        .init(url: "https://naijavibes.com/feed/", kind: .nightlife),
        .init(url: "https://tooxclusive.com/feed/", kind: .nightlife),
        .init(url: "http://www.okayafrica.com/feeds/music.rss", kind: .nightlife),
        .init(url: "https://www.thesouthafrican.com/culture/entertainment/feed/", kind: .nightlife),
        .init(url: "https://www.largeup.com/feed/", kind: .nightlife),
        .init(url: "https://thesource.com/feed/", kind: .nightlife)
    ]
    private var newsFeeds: [FeedSource] = [
        .init(url: "https://allafrica.com/tools/headlines/rdf/entertainment/headlines.rdf", kind: .news),
        .init(url: "https://www.africanews.com/feed/rss", kind: .news),
        .init(url: "https://www.bellanaija.com/feed/", kind: .news),
        .init(url: "https://www.pulse.ng/entertainment/rss", kind: .news)
    ]
    
    private var weightedFeeds: [FeedSource] {
        // 4x nightlife, 1x news ordering (like your previous mix)
        var ordered: [FeedSource] = []
        var n = nightlifeFeeds, e = newsFeeds
        var ni = 0, ei = 0
        while ni < n.count || ei < e.count {
            for _ in 0..<4 where ni < n.count { ordered.append(n[ni]); ni += 1 }
            if ei < e.count { ordered.append(e[ei]); ei += 1 }
        }
        return ordered
    }
    
    private let rssThumbWidth = 900 // tuned for crispness + speed
    
    // MARK: Body
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
            
            // Composer
            composer
            
            Divider().background(Color.gray.opacity(0.3))
            
            // Trending tags
            if !trendingTags.isEmpty { trendingTagStrip }
            
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
        .background(
            LinearGradient(
                colors: [Color.black, Color.black.opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
        .onAppear {
            loadCache()
            reloadContent()
        }
        .onChange(of: selectedVideoURL) { newValue in
            if let url = newValue {
                composerVideoPlayer = AVPlayer(url: url)
                composerVideoPlayer?.seek(to: .zero)
            } else {
                composerVideoPlayer = nil
            }
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
        // ✅ LISTENER lives ON the root View (not outside body)
        .onReceive(NotificationCenter.default.publisher(for: .inviteOrbCapturedMedia)) { note in
            handleInviteOrbCapture(note.userInfo)
        }
        // ✅ IG-style composer sheet presented from here
        .sheet(isPresented: $showComposer) {
            IGStylePostComposer(
                image: composerImage,
                videoURL: composerVideoURL,
                filterName: composerFilter
            ) { caption, mediaURL, image in
                // TODO: your existing “create post” logic here.
                // 1) Start background upload if needed
                // 2) Optimistically insert into feed
                // 3) Dismiss composer after you kick off work
                showComposer = false
            }
        }
    }
    
    // Renamed to avoid redeclaration
    private func handleCapturedMediaNote(_ info: [AnyHashable: Any]?) {
        let userInfo = info ?? [:]
        let hasURL   = (userInfo["hasURL"] as? Bool) ?? false
        let hasImage = (userInfo["hasImage"] as? Bool) ?? false
        composerFilter = (userInfo["filter"] as? String) ?? "none"
        
        if hasImage, let img = userInfo["image"] as? UIImage {
            composerImage = img
            composerVideoURL = nil
            showComposer = true
        } else if hasURL, let url = userInfo["mediaURL"] as? URL {
            composerImage = nil
            composerVideoURL = url
            showComposer = true
        }
    }
    
    
    // ===============================================
    // MARK: Composer UI
    // ===============================================
    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $newPostText)
                    .focused($composerFocused)
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
                    .onChange(of: newPostText) { newVal in
                        guard newVal.last == "\n" else { return }
                        newPostText = newVal.trimmingCharacters(in: .newlines)
                        composerFocused = false
                    }
                
                if newPostText.isEmpty && selectedMediaType == nil {
                    Text(editingPostId == nil ? "What’s the gist? (use #tags)" : "Editing post...")
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 14)
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.15),
                       value: composerFocused || selectedMediaType != nil || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            
            if let type = selectedMediaType {
                Group {
                    if type == .image, let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .cornerRadius(12)
                    } else if type == .video, let player = composerVideoPlayer {
                        VideoPlayer(player: player)
                            .frame(height: 240)
                            .cornerRadius(12)
                            .onAppear {
                                player.seek(to: .zero)
                                player.play()
                            }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        newPostText = ""
                        selectedImage = nil
                        selectedVideoURL = nil
                        selectedMediaType = nil
                        composerVideoPlayer?.pause()
                        composerVideoPlayer = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                            .padding(8)
                    }
                    .accessibilityLabel("Remove attached media")
                }
            }
            
            HStack(spacing: 16) {
                Button(action: { showImagePicker = true }) {
                    Image(systemName: "photo.on.rectangle")
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(Circle())
                        .shadow(radius: 4, x: 0, y: 2)
                        .foregroundColor(.white)
                }
                .disabled(isUploading || posting)
                
                Button(role: .destructive) {
                    newPostText = ""
                    selectedImage = nil
                    selectedVideoURL = nil
                    selectedMediaType = nil
                    editingPostId = nil
                    composerVideoPlayer?.pause()
                    composerVideoPlayer = nil
                } label: {
                    Image(systemName: "trash")
                        .padding(10)
                        .background(Color.red.opacity(0.25))
                        .foregroundColor(.red)
                        .clipShape(Circle())
                        .shadow(radius: 4, x: 0, y: 2)
                }
                .accessibilityLabel("Discard draft")
                .disabled(isUploading || posting)
                
                Button(action: {
                    if let id = editingPostId {
                        updatePost(id)
                    } else {
                        postToFirebase()
                    }
                    composerFocused = false
                }) {
                    HStack(spacing: 6) {
                        if isUploading || posting { ProgressView().scaleEffect(0.8) }
                        Image(systemName: editingPostId == nil ? "paperplane.fill" : "square.and.pencil")
                    }
                    .padding(10)
                    .background(
                        (isUploading || posting)
                        ? Color.gray.opacity(0.4)
                        : (editingPostId == nil ? Color.blue : Color.orange)
                    )
                    .foregroundColor(.white)
                    .clipShape(Circle())
                    .shadow(radius: 4, x: 0, y: 2)
                }
                .disabled(
                    isUploading || posting ||
                    (newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedMediaType == nil)
                )
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
    }
    
    
    
    // ===============================================
    // MARK: Trending Tags UI
    // ===============================================
    @ViewBuilder
    private var trendingTagStrip: some View {
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
    
    // ===============================================
    // MARK: Reload (fast server bundle + RTDB posts)
    // ===============================================
    private func reloadContent() {
        isLoading = combinedFeed.isEmpty
        fetchBundleFromCloud()
        fetchUserPosts()
    }
    
    // ===============================================
    // MARK: Server bundle fetcher (rssBundle) + App Check header
    // ===============================================
    private func fetchBundleFromCloud() {
        Task.detached(priority: .userInitiated) {
            do {
                // Request body
                let reqBody = try JSONEncoder().encode(
                    BundleRequest(feeds: weightedFeeds, perFeedLimit: 6, thumbWidth: rssThumbWidth)
                )
                
                // Build request
                var req = URLRequest(url: URL(string: CloudFunctions.rssBundle)!)
                req.httpMethod = "POST"
                req.timeoutInterval = 15
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = reqBody
                
                // ✅ App Check header
                if let t = try? await AppCheck.appCheck().token(forcingRefresh: false) {
                    req.setValue(t.token, forHTTPHeaderField: "X-Firebase-AppCheck")
                }
                
                
                // Send
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "rssBundle", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Non-200: \(raw)"])
                }
                
                // Decode and map
                let decoded = try JSONDecoder().decode(BundleResponse.self, from: data)
                let items = decoded.items
                let arts: [GossipArticle] = items.compactMap { it in
                    GossipArticle(
                        id: it.id,
                        title: it.title,
                        link: it.link,
                        description: it.summary,
                        pubDate: Date(timeIntervalSince1970: it.pubDate / 1000.0),
                        thumbURL: URL(string: it.thumb ?? it.image ?? ""),
                        imageURL: URL(string: it.image ?? ""),
                        kind: it.kind
                    )
                }
                
                // Keep 80/20 nightlife/news bias just like before
                let enforced = enforceMix(arts)
                
                await MainActor.run {
                    rssArticles = enforced
                    mergeContent()
                    saveRSSCache()
                    isLoading = false
                }
            } catch {
                print("❌ rssBundle error:", error.localizedDescription)
                await MainActor.run {
                    // fall back to cache only
                    isLoading = false
                }
            }
        }
    }
    
    private struct BundleRequest: Encodable {
        let feeds: [FeedSource]
        let perFeedLimit: Int
        let thumbWidth: Int
    }
    private struct BundleResponse: Decodable {
        let ok: Bool
        let items: [BundleItem]
    }
    
    // ===============================================
    // MARK: Enforce 80/20 Mix
    // ===============================================
    private func enforceMix(_ items: [GossipArticle]) -> [GossipArticle] {
        let nightlife = items.filter { $0.kind == .nightlife }
        let news      = items.filter { $0.kind == .news }
        let total = max(items.count, 1)
        let maxNight = Int(Double(total) * 0.8)
        let maxNews  = Int(Double(total) * 0.2)
        let nightSlice = Array(nightlife.sorted { $0.pubDate > $1.pubDate }.prefix(maxNight))
        let newsSlice  = Array(news.sorted { $0.pubDate > $1.pubDate }.prefix(maxNews))
        return (nightSlice + newsSlice).sorted { $0.pubDate > $1.pubDate }
    }
    
    // ===============================================
    // MARK: Helpers for media + live capture
    // ===============================================
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
    
    private func handleInviteOrbCapture(_ userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo else { return }
        let kind = (info["type"] as? String) ?? "photo"
        
        if kind == "photo", let image = info["image"] as? UIImage {
            selectedImage = image
            selectedVideoURL = nil
            selectedMediaType = .image
            newPostText = newPostText.isEmpty ? "#nightlife" : newPostText
            composerFocused = true
            
        } else if kind == "video", let url = info["mediaURL"] as? URL {
            selectedVideoURL = url
            selectedImage = nil
            selectedMediaType = .video
            newPostText = newPostText.isEmpty ? "#nightlife" : newPostText
            composerFocused = true
        }
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
    
    // ===============================================
    // MARK: User Posts + Profiles (with counters)
    // ===============================================
    private func fetchUserPosts(limit: UInt = 10) {
        let pRef = Database.database().reference().child("posts")
        let lRef = Database.database().reference().child("likes")
        let cRef = Database.database().reference().child("comments")
        let rRef = Database.database().reference().child("reposts")
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
                        var post = UserPost(
                            id: cs.key, text: t, timestamp: ts, userId: u,
                            mediaURL: d["mediaURL"] as? String, mediaType: d["mediaType"] as? String
                        )
                        post.originalPostId = d["originalPostId"] as? String
                        post.quoteText = d["quoteText"] as? String
                        arr.append(post)
                    }
                }
                
                lRef.observeSingleEvent(of: .value) { lsnap in
                    var liked: Set<String> = []
                    for case let ps as DataSnapshot in lsnap.children {
                        if ps.hasChild(uid) { liked.insert(ps.key) }
                    }
                    
                    cRef.observeSingleEvent(of: .value) { csnap in
                        var cm: [String: [UserPost.Comment]] = [:]
                        var cmCounts: [String: Int] = [:]
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
                            cmCounts[pSnap.key] = comments.count
                        }
                        
                        rRef.observeSingleEvent(of: .value) { rsnap in
                            var reposted: Set<String> = []
                            var rpCounts: [String: Int] = [:]
                            for case let pSnap as DataSnapshot in rsnap.children {
                                rpCounts[pSnap.key] = Int(pSnap.childrenCount)
                                if pSnap.hasChild(uid) { reposted.insert(pSnap.key) }
                            }
                            
                            var likeCounts: [String: Int] = [:]
                            for case let pSnap as DataSnapshot in lsnap.children {
                                likeCounts[pSnap.key] = Int(pSnap.childrenCount)
                            }
                            
                            for i in arr.indices {
                                let pid = arr[i].id
                                arr[i].isLikedByCurrentUser = liked.contains(pid)
                                arr[i].hasRepostedByCurrentUser = reposted.contains(pid)
                                arr[i].comments = cm[pid] ?? []
                                arr[i].commentCount = cmCounts[pid] ?? 0
                                arr[i].likeCount = likeCounts[pid] ?? 0
                                arr[i].repostCount = rpCounts[pid] ?? 0
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
    }
    
    // ===============================================
    // MARK: Combine & Render (strict alternation)
    // ===============================================
    private func mergeContent() {
        // External cards (from server bundle)
        let rssCards: [AnyIdentifiablePost] = rssArticles
            .filter { a in
                matchesSelectedTag("\(a.title) \(a.description)", selected: selectedTagFilter)
            }
            .sorted { $0.pubDate > $1.pubDate }
            .map { (article: GossipArticle) in
                AnyIdentifiablePost(timestamp: article.pubDate.timeIntervalSince1970, id: article.id) {
                    Button {
                        selectedURL = URL(string: article.link)
                        showWebView = true
                    } label: {
                        GossipRSSCardView(
                            article: article,
                            selectedURL: $selectedURL,
                            showWebView: $showWebView
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        
        // User post cards
        let userCards: [AnyIdentifiablePost] = userPosts
            .filter { post in matchesSelectedTag(post.text, selected: selectedTagFilter) }
            .sorted { $0.timestamp > $1.timestamp }
            .map { post in
                let profile = userProfiles[post.userId]
                let displayName = profile?.name ?? "User"
                
                return AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Header
                        HStack(alignment: .center, spacing: 10) {
                            AvatarView(urlString: profile?.imageURL, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName)
                                    .foregroundColor(.white)
                                    .font(.subheadline).bold()
                                Text(post.dateFormatted)
                                    .font(.caption2).foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        
                        // Body text
                        TextWithHashtagsView(text: post.text) { tappedTag in
                            selectedTagFilter = tappedTag
                            mergeContent()
                            resetPaging()
                        }
                        .padding(.vertical, 4)
                        
                        // User media
                        if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                            Group {
                                if post.mediaType == "video" {
                                    DynamicVideoPlayer(url: url) // X-style inline video
                                } else {
                                    DynamicAsyncImageView(url: url, cornerRadius: 10)
                                }
                            }
                        }
                        
                        // Quote context
                        if let originalId = post.originalPostId,
                           let original = userPosts.first(where: { $0.id == originalId }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    AvatarView(urlString: userProfiles[original.userId]?.imageURL, size: 24)
                                    Text(userProfiles[original.userId]?.name ?? "User")
                                        .font(.caption).foregroundColor(.white)
                                    Spacer()
                                }
                                Text(original.text)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(4)
                                if let mediaURL = original.mediaURL, let url = URL(string: mediaURL) {
                                    Group {
                                        if original.mediaType == "video" {
                                            DynamicVideoPlayer(url: url) // sizes itself by aspect
                                        } else {
                                            DynamicAsyncImageView(url: url, cornerRadius: 10) // sizes itself
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(12)
                        }
                        
                        // Footer actions
                        HStack(spacing: 22) {
                            Button(action: { toggleLike(for: post.id) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: post.isLikedByCurrentUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    Text("\(post.likeCount)")
                                }.foregroundColor(post.isLikedByCurrentUser ? .blue : .gray)
                            }
                            Button(action: { commentTargetPost = post }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.right")
                                    Text("\(post.commentCount)")
                                }.foregroundColor(.gray)
                            }
                            Button(action: { toggleRepost(for: post.id) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: post.hasRepostedByCurrentUser ? "arrow.2.squarepath.circle.fill" : "arrow.2.squarepath")
                                    Text("\(post.repostCount)")
                                }.foregroundColor(post.hasRepostedByCurrentUser ? .green : .gray)
                            }
                            Button(action: { presentQuoteComposer(for: post) }) {
                                Image(systemName: "quote.bubble").foregroundColor(.gray)
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
                        .padding(.top, 6)
                        .font(.callout)
                    }
                }
            }
        
        // Strict alternation
        let alternated = buildAlternating(user: userCards, external: rssCards)
        withAnimation {
            combinedFeed = alternated
            visibleCount = min(max(visibleCount, batchSize), combinedFeed.count)
            if !combinedFeed.isEmpty { isLoading = false }
        }
    }
    
    private enum NextPick { case user, external }
    private func buildAlternating(user: [AnyIdentifiablePost], external: [AnyIdentifiablePost]) -> [AnyIdentifiablePost] {
        var i = 0, j = 0
        var out: [AnyIdentifiablePost] = []
        guard !(user.isEmpty && external.isEmpty) else { return out }
        
        let nextStart: NextPick = {
            let uTs = user.first?.timestamp ?? -1
            let eTs = external.first?.timestamp ?? -1
            return (uTs >= eTs) ? .user : .external
        }()
        
        var next = nextStart
        while i < user.count && j < external.count {
            switch next {
            case .user: out.append(user[i]); i += 1; next = .external
            case .external: out.append(external[j]); j += 1; next = .user
            }
        }
        if i < user.count { out.append(contentsOf: user[i...]) }
        if j < external.count { out.append(contentsOf: external[j...]) }
        return out
    }
    
    // ===============================================
    // MARK: Paging
    // ===============================================
    private func resetPaging() { visibleCount = min(batchSize, combinedFeed.count) }
    private func pagedSlice<T>(of array: [T]) -> ArraySlice<T> {
        guard !array.isEmpty else { return ArraySlice<T>() }
        return array[0..<min(visibleCount, array.count)]
    }
    private func loadMoreIfNeeded() {
        guard !loadingMore, visibleCount < combinedFeed.count else { return }
        throttler.throttle("loadMore", interval: 0.35) {
            loadingMore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                visibleCount = min(visibleCount + batchSize, combinedFeed.count)
                loadingMore = false
            }
        }
    }
    
    // ===============================================
    // MARK: Cache
    // ===============================================
    private func savePostsCache() {
        let toCache: [CachedUserPost] = userPosts.map { p in
                .init(
                    id: p.id, text: p.text, timestamp: p.timestamp, userId: p.userId,
                    mediaURL: p.mediaURL, mediaType: p.mediaType,
                    isLikedByCurrentUser: p.isLikedByCurrentUser,
                    hasRepostedByCurrentUser: p.hasRepostedByCurrentUser,
                    likeCount: p.likeCount, commentCount: p.commentCount, repostCount: p.repostCount,
                    originalPostId: p.originalPostId, quoteText: p.quoteText,
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
                    id: a.id,
                    title: a.title, link: a.link, description: a.description,
                    pubDate: a.pubDate.timeIntervalSince1970,
                    thumbURL: a.thumbURL?.absoluteString,
                    imageURL: a.imageURL?.absoluteString,
                    kind: a.kind.rawValue
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
                    id: $0.id,
                    title: $0.title,
                    link: $0.link,
                    description: $0.description,
                    pubDate: Date(timeIntervalSince1970: $0.pubDate),
                    thumbURL: $0.thumbURL.flatMap(URL.init),
                    imageURL: $0.imageURL.flatMap(URL.init),
                    kind: FeedKind(rawValue: $0.kind) ?? .nightlife
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
                p.hasRepostedByCurrentUser = c.hasRepostedByCurrentUser
                p.likeCount = c.likeCount
                p.commentCount = c.commentCount
                p.repostCount = c.repostCount
                p.originalPostId = c.originalPostId
                p.quoteText = c.quoteText
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
    
    // ===============================================
    // MARK: Tag utils
    // ===============================================
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
    
    // ===============================================
    // MARK: Helpers
    // ===============================================
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
    
    // ===============================================
    // MARK: Hashtags
    // ===============================================
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
    
    private func matchesSelectedTag(_ text: String, selected: String?) -> Bool {
        guard let selected = selected?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        else { return true }
        let tags = extractHashtags(from: text)
        if tags.contains(selected) { return true }
        return text.lowercased().contains(selected)
    }
    
    // MARK: Posting / Media upload
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
                        if let error = error { cont.resume(throwing: error); return }
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
                    composerVideoPlayer = nil
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
        
        // Optimistic UI
        if let idx = userPosts.firstIndex(where: { $0.id == id }) {
            let already = userPosts[idx].isLikedByCurrentUser
            userPosts[idx].isLikedByCurrentUser.toggle()
            userPosts[idx].likeCount = max(0, userPosts[idx].likeCount + (already ? -1 : 1))
            mergeContent()
        }
        
        r.observeSingleEvent(of: .value) { snap in
            if snap.exists() { r.removeValue() }
            else { r.setValue(true) }
        }
    }
    
    private func toggleRepost(for id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("reposts").child(id).child(uid)
        
        // Optimistic UI
        if let idx = userPosts.firstIndex(where: { $0.id == id }) {
            let already = userPosts[idx].hasRepostedByCurrentUser
            userPosts[idx].hasRepostedByCurrentUser.toggle()
            userPosts[idx].repostCount = max(0, userPosts[idx].repostCount + (already ? -1 : 1))
            mergeContent()
        }
        
        ref.observeSingleEvent(of: .value) { snap in
            if snap.exists() { ref.removeValue() } else { ref.setValue(true) }
        }
    }
    
    private func presentQuoteComposer(for post: UserPost) {
        composerFocused = true
        let prefix = newPostText.isEmpty ? "" : (newPostText + "\n")
        newPostText = "\(prefix)\"\(post.text)\" #quote"
        editingPostId = nil
    }
    
    private func sharePost(_ post: UserPost) {
        guard let root = UIApplication.shared.windows.first?.rootViewController else { return }
        root.present(UIActivityViewController(activityItems: [post.text], applicationActivities: nil), animated: true)
    }
    
    private func resetPostFields() {
        newPostText = ""
        selectedImage = nil
        selectedVideoURL = nil
        selectedMediaType = nil
        editingPostId = nil
        composerVideoPlayer = nil
        fetchUserPosts()
    }
    
    // ===============================================
    // MARK: Text with Tappable Hashtags
    // ===============================================
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
    
    // ===============================================
    // MARK: Throttler
    // ===============================================
    private final class Throttler {
        private var workItems: [String: DispatchWorkItem] = [:]
        private let queue = DispatchQueue(label: "Gossip.Throttler", qos: .userInitiated)
        
        func throttle(_ key: String, interval: TimeInterval, action: @escaping () -> Void) {
            guard workItems[key] == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.workItems[key] = nil
                DispatchQueue.main.async { action() }
            }
            workItems[key] = item
            queue.asyncAfter(deadline: .now() + interval, execute: item)
        }
    }
    
    // ===============================================
    // MARK: RSS Card using server thumb
    // ===============================================
    struct GossipRSSCardView: View {
        let article: GossipArticle
        @Binding var selectedURL: URL?
        @Binding var showWebView: Bool
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                
                if let thumb = article.thumbURL?.absoluteString, !thumb.isEmpty {
                    DynamicAsyncImageView(url: URL(string: thumb)!, cornerRadius: 12)
                } else if let img = article.imageURL {
                    DynamicAsyncImageView(url: img, cornerRadius: 12)
                } else {
                    placeholderView
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
                        if let url = URL(string: article.link) {
                            selectedURL = url
                            showWebView = true
                        }
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .foregroundColor(.blue)
                    
                    Button {
                        if let url = URL(string: article.link) {
                            presentShare(url: url)
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
        
        private var placeholderView: some View {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(maxWidth: .infinity, minHeight: 120)
        }
        
        private func presentShare(url: URL) {
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(av, animated: true)
            }
        }
    }
    
    // ===============================================
    // MARK: Dynamic media helpers (self-contained)
    // ===============================================
    struct DynamicAsyncImageView: View {
        let url: URL
        var cornerRadius: CGFloat = 10
        
        @State private var uiImage: UIImage?
        @State private var aspect: CGFloat = 16.0/9.0
        
        var body: some View {
            ZStack {
                if let img = uiImage {
                    GeometryReader { geo in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width / aspect)
                            .clipped()
                    }
                    .frame(height: UIScreen.main.bounds.width / aspect * 0.9) // responsive
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 180)
                        .overlay(ProgressView())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: url.absoluteString) {
                ImageStore.shared.load(from: url, key: url.absoluteString) { img in
                    if let img = img {
                        uiImage = img
                        let w = img.size.width, h = img.size.height
                        if w > 0 && h > 0 { aspect = max(0.5, min(2.0, w/h)) } // clamp aspect
                    }
                }
            }
        }
    }
    
    
    // ===============================================
    // MARK: - X-style inline video (autoplay muted, pause off-screen, native aspect)
    // ===============================================
    
    final class GossipVideoPlaybackCenter: ObservableObject {
        static let shared = GossipVideoPlaybackCenter()
        @Published var currentlyPlaying: UUID?
        private init() {}
    }
    
    private struct FramePrefKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }
    
    struct VisibilityReader: View {
        var onChange: (CGFloat) -> Void
        init(_ onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }
        
        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: FramePrefKey.self, value: proxy.frame(in: .global))
            }
            .onPreferenceChange(FramePrefKey.self) { frame in
                let screen = UIScreen.main.bounds
                let intersection = frame.intersection(screen)
                let ratio = max(0, min(1, intersection.height / max(1, frame.height)))
                onChange(ratio) // 0.0 ... 1.0
            }
        }
    }
    
    struct DynamicVideoPlayer: View {
        let url: URL
        
        @State private var id = UUID()
        @State private var player: AVPlayer?
        @State private var aspect: CGFloat = 16.0 / 9.0 // updated once we inspect the asset
        @State private var isMuted: Bool = true
        @State private var endObserver: NSObjectProtocol?
        
        @ObservedObject private var center = GossipVideoPlaybackCenter.shared
        
        var body: some View {
            // Reserve height up-front so layout is stable before the asset loads
            let reservedHeight = calculatedHeightForCurrentAspect()
            ZStack(alignment: .bottomTrailing) {
                if let p = player {
                    GeometryReader { geo in
                        VideoPlayer(player: p)
                            .frame(
                                width: geo.size.width,
                                height: clampedHeight(forWidth: geo.size.width)
                            )
                            .clipped()
                            .cornerRadius(12)
                        // If another cell claims "currently playing", pause this one.
                            .onChange(of: center.currentlyPlaying) { newValue in
                                guard let current = newValue else { return }
                                if current != id { p.pause() }
                            }
                    }
                    // Mute toggle (X autoplays muted; tap to un/mute)
                    Button {
                        isMuted.toggle()
                        player?.isMuted = isMuted
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .padding(10)
                    .accessibilityLabel(isMuted ? "Unmute video" : "Mute video")
                    
                } else {
                    // Placeholder while preparing the player
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: reservedHeight)
                        .overlay(ProgressView())
                }
            }
            .frame(height: reservedHeight) // ensures stable list layout
            .background(
                // Visibility detector: play when >= ~55% visible, pause when <= ~30% visible
                VisibilityReader { visible in
                    guard let p = player else { return }
                    if visible >= 0.55 {
                        if center.currentlyPlaying != id {
                            center.currentlyPlaying = id // claim focus so others pause
                        }
                        p.play()
                    } else if visible <= 0.30 {
                        p.pause()
                    }
                }
            )
            .onAppear { preparePlayer() }
            .onDisappear {
                player?.pause()
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            }
        }
        
        private func preparePlayer() {
            guard player == nil else { return }
            
            let asset = AVURLAsset(url: url)
            
            // Best-effort natural aspect using the first video track
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let w = abs(size.width), h = abs(size.height)
                if w > 0 && h > 0 { aspect = max(0.2, min(5.0, w / h)) } // clamp to avoid extremes
            }
            
            let p = AVPlayer(url: url)
            p.isMuted = true  // X: autoplay muted
            p.actionAtItemEnd = .pause
            
            // Loop inline like X (only if this cell still owns focus)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem,
                queue: .main
            ) { _ in
                p.seek(to: .zero)
                if GossipVideoPlaybackCenter.shared.currentlyPlaying == id {
                    p.play()
                }
            }
            
            player = p
        }
        
        private func calculatedHeightForCurrentAspect() -> CGFloat {
            // matches your feed's .padding(.horizontal, 12) => width ≈ screen - 24
            let width = UIScreen.main.bounds.width - 24
            return clampedHeight(forWidth: width)
        }
        
        private func clampedHeight(forWidth width: CGFloat) -> CGFloat {
            // Native aspect like X: portrait/square get more height, landscape is shorter.
            let h = width / max(0.01, aspect)
            // Keep within sensible bounds for timeline readability
            return max(160, min(h, 600))
        }
    }
    
    // ===============================================
    // MARK: WebView
    // ===============================================
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
    /*
     // ===============================================
     // MARK: Notification name used by LiveCapture
     // ===============================================
     extension Notification.Name {
     static let inviteOrbCapturedMedia = Notification.Name("inviteOrbCapturedMedia")
     }
     */
    
    // Drop this in GossipTabView.swift (or a related file)
    
    
    struct IGStylePostComposer: View {
        let image: UIImage?
        let videoURL: URL?
        let filterName: String
        
        @State private var caption: String = ""
        @State private var isPosting = false
        @State private var progress: Double = 0
        
        // Inject your uploader if you want resumable uploads here too.
        var onPost: (_ caption: String, _ mediaURL: URL?, _ image: UIImage?) -> Void
        
        var body: some View {
            VStack(spacing: 14) {
                // Media preview (image or video)
                ZStack {
                    if let img = image {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(height: 320).clipped()
                            .cornerRadius(16)
                    } else if let url = videoURL {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 320)
                            .cornerRadius(16)
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08))
                            .frame(height: 120)
                            .overlay(Text("No media").foregroundColor(.white.opacity(0.6)))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if filterName != "none" {
                        Text(filterName.capitalized)
                            .font(.caption2).bold()
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                
                // Caption box (IG-like)
                TextField("Write a caption…", text: $caption, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    )
                    .foregroundColor(.white)
                    .lineLimit(3...6)
                
                // (Optional) quick chips
                HStack(spacing: 8) {
                    Label("Tag friends", systemImage: "person.crop.circle.badge.plus")
                    Label("Add location", systemImage: "mappin.and.ellipse")
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .font(.caption).foregroundColor(.white.opacity(0.8))
                
                Spacer()
                
                Button {
                    guard !isPosting else { return }
                    isPosting = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    // Optimistic insert: emit your usual “create post” action immediately;
                    // your upload can run in background (wire progress if you like).
                    onPost(caption, videoURL, image)
                } label: {
                    HStack {
                        if isPosting { ProgressView(value: progress).progressViewStyle(.linear).frame(width: 20) }
                        Text(isPosting ? "Posting…" : "Post")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [Color.blue, Color.purple],
                                                 startPoint: .leading, endPoint: .trailing))
                    )
                    .foregroundColor(.white)
                    .shadow(color: .blue.opacity(0.35), radius: 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
