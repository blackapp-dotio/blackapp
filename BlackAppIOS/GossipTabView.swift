import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import FirebaseAppCheck
import WebKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import Combine
import PhotosUI // ⬅️ NEW

// ===============================================
// MARK: - Cloud Functions base
// ===============================================
private enum CloudFunctions {
    static let projectId = "blackappios"
    static let base = "https://us-central1-\(projectId).cloudfunctions.net"
    static let rssBundle = base + "/rssBundle" // POST
}

// ===============================================
// MARK: - Cached remote image (HTTPS only) – uses ImageStore elsewhere in project
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
// MARK: - NEW: Multi-media model (back-compat supported)
// ===============================================
struct PostMedia: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case image, video }
    let id: String
    let url: String
    let kind: Kind
    var thumbURL: String?
    var width: Int?
    var height: Int?
    var duration: Double?
    var order: Int = 0
}

// ===============================================
// MARK: - Twitter-like UserPost Model
// ===============================================
struct UserPost: Identifiable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let userId: String

    // Legacy single-media (kept for old posts/clients)
    var mediaURL: String?
    var mediaType: String? // "image", "video"

    // NEW: multiple media
    var media: [PostMedia] = []

    var isLikedByCurrentUser: Bool = false
    var hasRepostedByCurrentUser: Bool = false

    var likeCount: Int = 0
    var commentCount: Int = 0
    var repostCount: Int = 0

    var comments: [Comment] = []
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
    let pubDate: TimeInterval // ms since epoch
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
// MARK: - Cache DTOs (now includes media)
// ===============================================
private struct CachedPostMedia: Codable {
    let id: String, url: String, kind: String
    let thumbURL: String?
    let width: Int?
    let height: Int?
    let duration: Double?
    let order: Int
}

private struct CachedUserPost: Codable {
    struct Cmt: Codable { let id: String; let userId: String; let text: String; let timestamp: TimeInterval }
    let id: String, text: String, timestamp: TimeInterval, userId: String
    let mediaURL: String?, mediaType: String?          // legacy
    let media: [CachedPostMedia]                        // new
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
// MARK: Email Verification Banner (phone-safe)
// ===============================================
import FirebaseAuth
import FirebaseFirestore

struct EmailVerificationBanner: View {
    @StateObject private var vm = EmailVerificationBannerVM()
    var body: some View {
        Group {
            if vm.showBanner {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .imageScale(.large)
                        .foregroundColor(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verify your email")
                            .font(.subheadline).bold()
                            .foregroundColor(.white)
                        Text("We’ve sent a verification link. Please check your inbox.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if vm.sending {
                        ProgressView().tint(.white)
                    } else {
                        Button("Resend") { vm.resend() }
                            .font(.caption).bold()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.9))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .cornerRadius(10)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

final class EmailVerificationBannerVM: ObservableObject {
    @Published var showBanner: Bool = false
    @Published var sending: Bool = false

    private let db = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var userListener: ListenerRegistration?

    func start() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            self.listenUserDoc(for: user)
            self.compute(user: user, userDoc: nil)  // best-effort immediately
        }
    }

    func stop() {
        if let h = authHandle { Auth.auth().removeStateDidChangeListener(h) }
        userListener?.remove()
        authHandle = nil
        userListener = nil
    }

    private func listenUserDoc(for user: User?) {
        userListener?.remove()
        guard let uid = user?.uid else {
            compute(user: nil, userDoc: nil)
            return
        }
        userListener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self = self else { return }
                self.compute(user: Auth.auth().currentUser, userDoc: snap?.data())
            }
    }

    /// Core logic:
    /// - Hide for phone-only accounts (no email/password provider).
    /// - Hide if Firestore sets `emailVerificationExempt == true`.
    /// - Show for email signups when `requiresEmailVerification` (or default true for email providers)
    ///   AND currentUser.isEmailVerified == false.
    private func compute(user: User?, userDoc: [String: Any]?) {
        guard let user = user else {
            showBanner = false
            return
        }

        let providers = user.providerData.map { $0.providerID }
        let hasPhone  = providers.contains("phone")
        let hasEmailProvider = providers.contains("password") || providers.contains("email")
        let hasEmailString = !(user.email ?? "").isEmpty

        // Phone-only → never show banner
        if hasPhone && !hasEmailProvider {
            showBanner = false
            return
        }

        // Firestore flags (optional; default behavior is based on provider)
        let emailExempt = (userDoc?["emailVerificationExempt"] as? Bool) == true
        if emailExempt {
            showBanner = false
            return
        }

        let requiresEmailVerification: Bool = {
            if let v = userDoc?["requiresEmailVerification"] as? Bool { return v }
            // default: if the account has email/password provider, require email verification
            return hasEmailProvider
        }()

        if requiresEmailVerification, hasEmailString {
            showBanner = !user.isEmailVerified
        } else {
            showBanner = false
        }
    }

    func resend() {
        guard let user = Auth.auth().currentUser else { return }
        guard !user.isEmailVerified else { showBanner = false; return }
        sending = true

        // Use app language; simple send is sufficient for banner UX.
        Auth.auth().useAppLanguage()
        user.sendEmailVerification { [weak self] error in
            DispatchQueue.main.async {
                self?.sending = false
                // We keep the banner visible; if user taps the link later and re-opens app,
                // `isEmailVerified` will hide it automatically via auth state / listener.
                if let error = error {
                    print("❌ resend verify email failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
// ===============================================
// MARK: - Realtime Database key sanitizer
// ===============================================
private func rtdbSafeKey(_ raw: String) -> String {
    // Replace forbidden characters with underscores
    var result = ""
    for ch in raw {
        switch ch {
        case ".", "#", "$", "[", "]", "/":
            result.append("_")
        default:
            result.append(ch)
        }
    }
    // Fallback if somehow empty
    if result.isEmpty {
        return "unknown_key"
    }
    return result
}

// ===============================================
// MARK: - Gossip Tab
// ===============================================
struct GossipTabView: View {
    // Posts
    @State private var userPosts: [UserPost] = []
    @State private var combinedFeed: [AnyIdentifiablePost] = []
    @State private var rssArticles: [GossipArticle] = []

    // Composer (UPDATED: multi-pick arrays)
    @State private var newPostText: String = ""
    @State private var editingPostId: String? = nil

    // ⬇️ NEW multi-selection state (replaces single image/video fields)
    @State private var selectedImages: [UIImage] = []
    @State private var selectedVideos: [URL] = []

    // Keep these to preserve existing code paths (legacy single-pick UI still works elsewhere)
    @State private var selectedImage: UIImage? = nil
    @State private var selectedVideoURL: URL? = nil
    @State private var selectedMediaType: ImagePicker.MediaType? = nil

    @FocusState private var composerFocused: Bool
    @State private var composerVideoPlayer: AVPlayer? = nil

    // IG-style composer (LiveCapture)
    @State private var showComposer = false
    @State private var composerImage: UIImage? = nil
    @State private var composerVideoURL: URL? = nil
    @State private var composerFilter: String = "none"

    // Tags
    @State private var trendingTags: [String] = []
    @State private var showAllTags = false
    @State private var selectedTagFilter: String? = nil
    // 🔁 City-specific tags derived from hashtags (e.g. #charlotte, #lagos)
    @State private var cityTags: [String] = []
    @State private var selectedCityTag: String? = nil

    // UI
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var showImagePicker = false     // legacy flag; re-used for new multi-picker
    @State private var isLoading = true
    @State private var commentTargetPost: UserPost? = nil
    @State private var commentText: String = ""
    @State private var userProfiles: [String: (name: String, imageURL: String?)] = [:]
    @State private var isUploading: Bool = false
    @State private var posting: Bool = false
    @State private var selectedSmartFilter: SmartFilter = .all

    // Refresh tracking (capsule overlay)
    @State private var loadingBundle = false
    @State private var loadingPosts = false

    // Paging (Twitter-style: quick first paint)
    @State private var visibleCount: Int = 5
    @State private var loadingMore: Bool = false
    private let batchSize: Int = 5
    private let throttler = Throttler()

    // Cache
    private var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first! }
    private var postsCacheURL: URL { cacheDir.appendingPathComponent("gossip_user_posts.json") }
    private var rssCacheURL: URL { cacheDir.appendingPathComponent("gossip_rss_articles.json") }

    // MARK: Sources sent to rssBundle
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

    // Weighted 4:1 ordering helper used by rssBundle request
    private var weightedFeeds: [FeedSource] {
        var ordered: [FeedSource] = []
        var n = nightlifeFeeds, e = newsFeeds
        var ni = 0, ei = 0
        while ni < n.count || ei < e.count {
            for _ in 0..<4 where ni < n.count { ordered.append(n[ni]); ni += 1 }
            if ei < e.count { ordered.append(e[ei]); ei += 1 }
        }
        return ordered
    }
    private let rssThumbWidth = 900

    // MARK: Body
    var body: some View {
        ZStack {
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

                // Composer (post box at the top)
                composer

                // 🔮 Smart source / mode filters
                smartFilterStrip
                
                // 🏙 City chips (derived from hashtags like #charlotte, #lagos)
                if !cityTags.isEmpty { cityFilterStrip }
                
                Divider().background(Color.gray.opacity(0.3))

                // Trending tags (hashtags, including cities like #charlotte, #lagos, etc.)
                if !trendingTags.isEmpty { trendingTagStrip }

                // Feed
                feedSection

            }
            .background(
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            // 🔄 Refresh overlay (shows while either source is loading)
            if loadingBundle || loadingPosts {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Refreshing…")
                        .foregroundColor(.white.opacity(0.9))
                        .font(.footnote)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
                .transition(.opacity)
                .accessibilityLabel("Refreshing")
            }
        }
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
        .sheet(item: $selectedURL) { url in
            GossipWebView(url: url)
                .applySheetStyle()   // keep if you’re using the helper; otherwise remove
        }



        // ⬇️ REPLACED: use SystemMultiMediaPicker for multi-select
        .sheet(isPresented: $showImagePicker) {
            SystemMultiMediaPicker(
                selectionLimit: 4,
                onComplete: { imgs, vids in
                    // cap at 4 total like Twitter
                    let space = max(0, 4 - min(imgs.count, 4))
                    let imgsCapped = Array(imgs.prefix(4))
                    let vidsCapped = Array(vids.prefix(space > 0 ? space : 0)) // keep total ≤ 4
                    selectedImages = imgsCapped
                    selectedVideos = vidsCapped
                    // keep legacy flags coherent (optional)
                    selectedMediaType = (!imgsCapped.isEmpty ? .image : (!vidsCapped.isEmpty ? .video : nil))
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteOrbCapturedMedia)) { note in
            handleInviteOrbCapture(note.userInfo)
        }
        .sheet(isPresented: $showComposer) {
            IGStylePostComposer(
                image: composerImage,
                videoURL: composerVideoURL,
                filterName: composerFilter
            ) { caption, mediaURL, image in
                showComposer = false
            }
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

    // ===============================================
    // MARK: Feed Rendering (split for compiler sanity)
    // ===============================================
    private var feedSection: some View {
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
                                    let lastTwoIDs = Array(page.suffix(2).map { $0.id })
                                    if lastTwoIDs.contains(item.id) { loadMoreIfNeeded() }
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

    // ===============================================
    // MARK: Composer UI (UPDATED for multi-media)
    // ===============================================
    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $newPostText)
                    .focused($composerFocused)
                    .frame(
                        minHeight: (composerFocused
                                    || (!selectedImages.isEmpty || !selectedVideos.isEmpty)
                                    || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 88 : 36,
                        maxHeight: (composerFocused
                                    || (!selectedImages.isEmpty || !selectedVideos.isEmpty)
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

                if newPostText.isEmpty && selectedImages.isEmpty && selectedVideos.isEmpty {
                    Text(editingPostId == nil ? "What’s the gist? (use #tags)" : "Editing post…")
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 14)
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.15),
                       value: composerFocused || !selectedImages.isEmpty || !selectedVideos.isEmpty || !newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            // ⬇️ Multi-media preview (Twitter-style: grid/pager)
            if !selectedImages.isEmpty || !selectedVideos.isEmpty {
                ComposerSelectedPreview(images: selectedImages, videos: selectedVideos)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            clearComposerSelection()
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
                    clearComposerSelection()
                    editingPostId = nil
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
                        // Cap to Twitter/X’s 4-attachment rule
                        let imgs = Array(selectedImages.prefix(max(0, 4 - selectedVideos.count)))
                        let vids = Array(selectedVideos.prefix(max(0, 4 - imgs.count)))
                        postToFirebaseMultiple(caption: newPostText, pickedImages: imgs, pickedVideos: vids)
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
                    (newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     && selectedImages.isEmpty && selectedVideos.isEmpty)
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

    private func clearComposerSelection() {
        selectedImages.removeAll()
        selectedVideos.removeAll()
        // keep legacy variables synced (optional)
        selectedImage = nil
        selectedVideoURL = nil
        selectedMediaType = nil
        composerVideoPlayer?.pause()
        composerVideoPlayer = nil
    }
    
    // ===============================================
    // MARK: Smart Filter Modes (futuristic pills)
    // ===============================================
    private enum SmartFilter: String, CaseIterable, Identifiable {
        case all
        case myPosts
        case nightlifeOnly
        case newsOnly
        case mediaOnly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all:           return "All"
            case .myPosts:       return "My Posts"
            case .nightlifeOnly: return "Nightlife"
            case .newsOnly:      return "News"
            case .mediaOnly:     return "Media"
            }
        }

        var icon: String {
            switch self {
            case .all:           return "sparkles"
            case .myPosts:       return "person.crop.circle"
            case .nightlifeOnly: return "moon.stars.fill"
            case .newsOnly:      return "newspaper.fill"
            case .mediaOnly:     return "photo.on.rectangle.angled"
            }
        }
    }

    // ===============================================
    // MARK: Smart Filter Strip (source / mode chips)
    // ===============================================
    @ViewBuilder
    private var smartFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SmartFilter.allCases) { filter in
                    let isSelected = (filter == selectedSmartFilter)

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedSmartFilter = filter
                            mergeContent()
                            resetPaging()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.icon)
                                .font(.caption2)
                            Text(filter.label)
                                .font(.footnote).bold()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Group {
                                if isSelected {
                                    LinearGradient(
                                        colors: [Color.blue, Color.purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                } else {
                                    Color.white.opacity(0.08)
                                }
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 999)
                                .stroke(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .white : .white.opacity(0.75))
                        .clipShape(Capsule())
                        .shadow(color: isSelected ? Color.blue.opacity(0.35) : Color.clear,
                                radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }
    
    // ===============================================
    // MARK: City Filter Strip (dynamic from tags)
    // ===============================================
    @ViewBuilder
    private var cityFilterStrip: some View {
        if cityTags.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Label chip
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text("Cities")
                            .font(.footnote).bold()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .foregroundColor(.white.opacity(0.8))
                    .clipShape(Capsule())

                    ForEach(cityTags, id: \.self) { tag in
                        let isSelected = (selectedCityTag == tag)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isSelected {
                                    // clear city + global tag filter
                                    selectedCityTag = nil
                                    selectedTagFilter = nil
                                } else {
                                    selectedCityTag = tag
                                    selectedTagFilter = tag   // reuse existing tag filter logic
                                }
                                mergeContent()
                                resetPaging()
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(tag)
                                .font(.footnote).bold()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? Color.blue.opacity(0.9) : Color.white.opacity(0.08)
                                )
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
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
                    selectedCityTag = nil
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
    // MARK: Reload (Parallel) + App Check
    // ===============================================
    private func reloadContent() {
        isLoading = combinedFeed.isEmpty
        loadingBundle = true
        loadingPosts  = true

        let group = DispatchGroup()

        group.enter()
        fetchBundleFromCloud { group.leave() }

        group.enter()
        fetchUserPostsFast(limit: 180) { group.leave() }

        group.notify(queue: .main) {
            loadingBundle = false
            loadingPosts  = false
            isLoading = false
            resetPaging()
        }
    }

    private func fetchBundleFromCloud(completion: (() -> Void)? = nil) {
        Task.detached(priority: .userInitiated) {
            do {
                let reqBody = try JSONEncoder().encode(
                    BundleRequest(feeds: weightedFeeds, perFeedLimit: 6, thumbWidth: rssThumbWidth)
                )

                var req = URLRequest(url: URL(string: CloudFunctions.rssBundle)!)
                req.httpMethod = "POST"
                req.timeoutInterval = 15
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = reqBody

                if let t = try? await AppCheck.appCheck().token(forcingRefresh: false) {
                    req.setValue(t.token, forHTTPHeaderField: "X-Firebase-AppCheck")
                }

                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "rssBundle", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Non-200: \(raw)"])
                }

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

                let enforced = enforceMix(arts)

                await MainActor.run {
                    rssArticles = enforced
                    mergeContent()
                    saveRSSCache()
                }
            } catch {
                print("❌ rssBundle error:", error.localizedDescription)
            }

            await MainActor.run {
                loadingBundle = false
                completion?()
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
            selectedImages = [image]
            selectedVideos = []
            if newPostText.isEmpty { newPostText = "#nightlife" }
            composerFocused = true
        } else if kind == "video", let url = info["mediaURL"] as? URL {
            selectedVideos = [url]
            selectedImages = []
            if newPostText.isEmpty { newPostText = "#nightlife" }
            composerFocused = true
        }
    }

    /// Ensure we have a stable, readable local file (outside security-scoped containers)
    private func copyToTempIfNeeded(_ sourceURL: URL, preferredExtension: String? = nil) throws -> URL {
        let fm = FileManager.default
        let ext = preferredExtension ?? sourceURL.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)

        if sourceURL.isFileURL {
            // If already under /var/... we still copy to avoid security scope invalidation mid-upload
            try fm.copyItem(at: sourceURL, to: dest)
            return dest
        } else {
            // Unusual, but just in case
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: dest, options: .atomic)
            return dest
        }
    }
    
    /// Uploads small blobs (e.g., JPEGs) via foreground `putData` to avoid background/resumable quirks.
    private func uploadData(_ data: Data, path: String, contentType: String) async throws -> String {
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = contentType

        // Retry on transient network/storage errors (same set we used before)
        let transientCodes: Set<Int> = [-1001, -1005, -1011, -1017]
        var attempt = 0, lastError: Error?

        while attempt < 3 {
            do {
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    ref.putData(data, metadata: meta) { _, error in
                        if let error = error { cont.resume(throwing: error); return }
                        ref.downloadURL { url, err in
                            if let err = err { cont.resume(throwing: err); return }
                            cont.resume(returning: url?.absoluteString ?? "")
                        }
                    }
                }
            } catch {
                lastError = error
                let ns = error as NSError
                print("⚠️ Storage putData attempt \(attempt + 1) failed [\(ns.domain):\(ns.code)] details=\(ns.userInfo) path=\(path)")
                if transientCodes.contains(ns.code) {
                    let delay = pow(2.0, Double(attempt)) * 0.6
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
        throw lastError ?? NSError(domain: "Upload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown upload failure (putData)"])
    }

    private func uploadFileURL(_ localURL: URL, path: String, contentType: String? = nil) async throws -> String {
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = contentType

        // Retry on common transient network/storage errors
        let transientCodes: Set<Int> = [
            -1001, // timed out
            -1005, // network connection lost
            -1011, // bad server response
            -1017  // cannot parse response
        ]

        var attempt = 0
        let maxAttempts = 3
        var lastError: Error?

        while attempt < maxAttempts {
            do {
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    ref.putFile(from: localURL, metadata: meta) { _, error in
                        if let error = error {
                            cont.resume(throwing: error)
                            return
                        }
                        ref.downloadURL { url, err in
                            if let err = err { cont.resume(throwing: err); return }
                            cont.resume(returning: url?.absoluteString ?? "")
                        }
                    }
                }
            } catch {
                lastError = error
                let ns = (error as NSError)
                let code = ns.code
                let domain = ns.domain
                let details = ns.userInfo

                print("⚠️ Storage upload attempt \(attempt + 1) failed [\(domain):\(code)] details=\(details) path=\(path)")

                if transientCodes.contains(code) {
                    // Exponential backoff
                    let delay = pow(2.0, Double(attempt)) * 0.6
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                } else {
                    // Non-transient; bubble up immediately
                    throw error
                }
            }
        }
        throw lastError ?? NSError(domain: "Upload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown upload failure"])
    }


    // ===============================================
    // MARK: User Posts + Profiles (FAST PARALLEL, multi-media aware)
    // ===============================================
    private func fetchUserPostsFast(limit: UInt = 180, done: (() -> Void)? = nil) {
        loadingPosts = true

        let pRef = Database.database().reference().child("posts")
        let lRef = Database.database().reference().child("likes")
        let cRef = Database.database().reference().child("comments")
        let rRef = Database.database().reference().child("reposts")
        let usersRef = Database.database().reference().child("users")
        let me = Auth.auth().currentUser?.uid

        pRef.queryOrdered(byChild: "timestamp")
            .queryLimited(toLast: limit)
            .observeSingleEvent(of: .value) { snap in

                var posts: [UserPost] = []
                var uniqueUserIds = Set<String>()

                for case let cs as DataSnapshot in snap.children {
                    guard let d = cs.value as? [String: Any],
                          let t = d["text"] as? String,
                          let ts = d["timestamp"] as? TimeInterval,
                          let u = d["userId"] as? String else { continue }

                    var post = UserPost(
                        id: cs.key, text: t, timestamp: ts, userId: u,
                        mediaURL: d["mediaURL"] as? String,   // legacy
                        mediaType: d["mediaType"] as? String  // legacy
                    )
                    post.originalPostId = d["originalPostId"] as? String
                    post.quoteText = d["quoteText"] as? String

                    // NEW: parse media map
                    if let mediaDict = d["media"] as? [String: Any] {
                        var list: [PostMedia] = []
                        list.reserveCapacity(mediaDict.count)
                        for (mid, raw) in mediaDict {
                            guard let md = raw as? [String: Any],
                                  let url = md["url"] as? String,
                                  let kindStr = md["kind"] as? String,
                                  let kind = PostMedia.Kind(rawValue: kindStr) else { continue }
                            let m = PostMedia(
                                id: (md["id"] as? String) ?? mid,
                                url: url,
                                kind: kind,
                                thumbURL: md["thumbURL"] as? String,
                                width: md["width"] as? Int,
                                height: md["height"] as? Int,
                                duration: md["duration"] as? Double,
                                order: md["order"] as? Int ?? 0
                            )
                            list.append(m)
                        }
                        post.media = list.sorted { $0.order < $1.order }
                    }

                    posts.append(post)
                    uniqueUserIds.insert(u)
                }

                posts.sort { $0.timestamp > $1.timestamp }

                // Fetch counters in parallel
                let group = DispatchGroup()

                var likeCounts: [String: Int] = [:]
                var likedByMe: Set<String> = []

                var commentMap: [String: [UserPost.Comment]] = [:]
                var commentCounts: [String: Int] = [:]

                var repostCounts: [String: Int] = [:]
                var repostedByMe: Set<String> = []

                group.enter()
                lRef.observeSingleEvent(of: .value) { lsnap in
                    defer { group.leave() }
                    for case let pSnap as DataSnapshot in lsnap.children {
                        likeCounts[pSnap.key] = Int(pSnap.childrenCount)
                        if let me = me, pSnap.hasChild(me) { likedByMe.insert(pSnap.key) }
                    }
                }

                group.enter()
                cRef.observeSingleEvent(of: .value) { csnap in
                    defer { group.leave() }
                    for case let pSnap as DataSnapshot in csnap.children {
                        var arr: [UserPost.Comment] = []
                        arr.reserveCapacity(Int(pSnap.childrenCount))
                        for case let cSnap as DataSnapshot in pSnap.children {
                            if let cd = cSnap.value as? [String: Any],
                               let u = cd["userId"] as? String,
                               let tx = cd["text"] as? String,
                               let tm = cd["timestamp"] as? TimeInterval {
                                arr.append(.init(id: cSnap.key, userId: u, text: tx, timestamp: tm))
                            }
                        }
                        commentMap[pSnap.key] = arr
                        commentCounts[pSnap.key] = arr.count
                    }
                }

                group.enter()
                rRef.observeSingleEvent(of: .value) { rsnap in
                    defer { group.leave() }
                    for case let pSnap as DataSnapshot in rsnap.children {
                        repostCounts[pSnap.key] = Int(pSnap.childrenCount)
                        if let me = me, pSnap.hasChild(me) { repostedByMe.insert(pSnap.key) }
                    }
                }

                group.notify(queue: .main) {
                    // Merge counters in O(n)
                    for i in posts.indices {
                        let pid = posts[i].id
                        posts[i].isLikedByCurrentUser = likedByMe.contains(pid)
                        posts[i].hasRepostedByCurrentUser = repostedByMe.contains(pid)
                        posts[i].likeCount = likeCounts[pid] ?? 0
                        posts[i].commentCount = commentCounts[pid] ?? 0
                        posts[i].repostCount = repostCounts[pid] ?? 0
                        posts[i].comments = commentMap[pid] ?? []
                    }

                    userPosts = posts
                    savePostsCache()

                    // Fetch minimal profiles once per uid
                    let inner = DispatchGroup()
                    for uid in uniqueUserIds {
                        inner.enter()
                        usersRef.child(uid).observeSingleEvent(of: .value) { uSnap in
                            if let dict = uSnap.value as? [String: Any] {
                                let name = dict["name"] as? String ?? "User"
                                let img = dict["profileImageURL"] as? String
                                userProfiles[uid] = (name, img)
                            }
                            inner.leave()
                        }
                    }

                    inner.notify(queue: .main) {
                        // Single recompute rather than per-profile
                        mergeContent()
                        updateTrendingTags()
                        loadingPosts = false
                        done?()
                    }
                }
            }
    }

    // ===============================================
    // MARK: Combine & Render (strict alternation)
    // ===============================================
    private func mergeContent() {
        let rssCards: [AnyIdentifiablePost] = rssArticles
            .filter { a in
                passesSmartFilter(a) &&
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

        let userCards: [AnyIdentifiablePost] = userPosts
            .filter { post in
                passesSmartFilter(post) &&
                matchesSelectedTag(post.text, selected: selectedTagFilter)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .map { post in
                let profile = userProfiles[post.userId]
                let displayName = profile?.name ?? "User"

                return AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                    ZStack(alignment: .topTrailing) {
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

                            // NEW: Multi-media render
                            if !post.media.isEmpty {
                                MediaGalleryView(media: post.media)
                            } else if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                                // legacy single-media fallback
                                Group {
                                    if post.mediaType == "video" {
                                        DynamicVideoPlayer(url: url)
                                    } else {
                                        DynamicAsyncImageView(url: url, cornerRadius: 10)
                                    }
                                }
                            }

                            // Quote
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
                                    if !original.media.isEmpty {
                                        MediaGalleryView(media: original.media)
                                    } else if let m = original.mediaURL, let url = URL(string: m) {
                                        if original.mediaType == "video" { DynamicVideoPlayer(url: url) }
                                        else { DynamicAsyncImageView(url: url, cornerRadius: 10) }
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

                        // Moderation overlay (component provided elsewhere)
                        PostModerationOverlay(
                            authorUid: post.userId,
                            targetId: post.id,
                            targetType: .post
                        )
                    }
                }
            }

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
    // MARK: Cache (now includes media)
    // ===============================================
    private func savePostsCache() {
        let toCache: [CachedUserPost] = userPosts.map { p in
            .init(
                id: p.id, text: p.text, timestamp: p.timestamp, userId: p.userId,
                mediaURL: p.mediaURL, mediaType: p.mediaType,
                media: p.media.map { m in
                    .init(id: m.id, url: m.url, kind: m.kind.rawValue, thumbURL: m.thumbURL, width: m.width, height: m.height, duration: m.duration, order: m.order)
                },
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
                p.media = c.media.map { m in
                    PostMedia(id: m.id, url: m.url, kind: PostMedia.Kind(rawValue: m.kind) ?? .image,
                              thumbURL: m.thumbURL, width: m.width, height: m.height, duration: m.duration, order: m.order)
                }.sorted { $0.order < $1.order }
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

        // Count hashtags on user posts
        for post in userPosts {
            for tag in extractHashtags(from: post.text) {
                tagCount[tag, default: 0] += 1
            }
        }

        // Count hashtags on RSS articles
        for article in rssArticles {
            let combined = "\(article.title) \(article.description)"
            for tag in extractHashtags(from: combined) {
                tagCount[tag, default: 0] += 1
            }
        }

        // Main trending tags (mixed)
        trendingTags = Array(
            tagCount
                .sorted { $0.value > $1.value }
                .prefix(showAllTags ? 24 : 10)
                .map { "#\($0.key)" }
        )

        // 🔁 City tags – subset of hashtags that look like cities we care about
        let cityUniverse: Set<String> = [
            "charlotte", "atl", "atlanta", "lagos", "houston", "miami",
            "nyc", "la", "losangeles", "los_angeles",
            "dc", "washingtondc", "washington_dc",
            "dubai", "london", "johannesburg", "capetown", "cape_town",
            "toronto", "paris", "berlin", "nairobi", "accra", "abidjan"
        ]

        let cityKeys = tagCount.keys.filter { cityUniverse.contains($0.lowercased()) }

        cityTags = Array(
            cityKeys
                .sorted { (tagCount[$0] ?? 0) > (tagCount[$1] ?? 0) }
                .prefix(12)
                .map { "#\($0)" }
        )

        // If current selected city no longer in the list, clear it
        if let selected = selectedCityTag, !cityTags.contains(selected) {
            selectedCityTag = nil
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

    // ===============================================
    // MARK: Smart Filter Logic
    // ===============================================
    private func passesSmartFilter(_ post: UserPost) -> Bool {
        switch selectedSmartFilter {
        case .all:
            return true
        case .myPosts:
            return post.userId == Auth.auth().currentUser?.uid
        case .nightlifeOnly:
            // rely on hashtags / text signals
            let lower = post.text.lowercased()
            return lower.contains("#nightlife") || lower.contains("nightlife")
        case .newsOnly:
            let lower = post.text.lowercased()
            return lower.contains("#news") || lower.contains("headline")
        case .mediaOnly:
            return !post.media.isEmpty || post.mediaURL != nil
        }
    }

    private func passesSmartFilter(_ article: GossipArticle) -> Bool {
        switch selectedSmartFilter {
        case .all:
            return true
        case .myPosts:
            // Smart filter "My Posts" hides external RSS
            return false
        case .nightlifeOnly:
            return article.kind == .nightlife
        case .newsOnly:
            return article.kind == .news
        case .mediaOnly:
            // require at least a thumbnail or image
            return article.thumbURL != nil || article.imageURL != nil
        }
    }

    
    // ===============================================
    // MARK: Posting / Media upload (MULTI-MEDIA, concurrent)
    // ===============================================
    private func postToFirebaseMultiple(
        caption: String,
        pickedImages: [UIImage],
        pickedVideos: [URL]
    ) {
        if ProfanityFilter.containsBanned(caption) {
            print("Post blocked: contains prohibited words.")
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        posting = true
        isUploading = true

        Task.detached(priority: .userInitiated) {
            do {
                let postId = UUID().uuidString
                let now = Date().timeIntervalSince1970

                // 1) Upload media concurrently
                var uploaded: [PostMedia] = []
                try await withThrowingTaskGroup(of: PostMedia?.self) { group in

                    for (idx, img) in pickedImages.enumerated() {
                        group.addTask {
                            // Ensure we have real JPEG bytes and basic sanity checks
                            guard let data = img.jpegData(compressionQuality: 0.85), data.count > 0 else { return nil }

                            // Optional: lightweight size metadata
                            let width = Int(img.size.width)
                            let height = Int(img.size.height)

                            let mId = Database.database().reference().child("tmp").childByAutoId().key ?? UUID().uuidString
                            let storagePath = "posts/\(uid)/\(postId)/images/\(mId).jpg"

                            // 👉 Foreground upload (no background/resumable) to dodge -1017
                            let urlStr = try await uploadData(data, path: storagePath, contentType: "image/jpeg")

                            return PostMedia(
                                id: mId,
                                url: urlStr,
                                kind: .image,
                                thumbURL: urlStr,
                                width: width,
                                height: height,
                                duration: nil,
                                order: idx
                            )
                        }
                    }


                    for (vIdx, vURL) in pickedVideos.enumerated() {
                        group.addTask {
                            var needsStop = false
                            if vURL.startAccessingSecurityScopedResource() { needsStop = true }
                            defer { if needsStop { vURL.stopAccessingSecurityScopedResource() } }

                            // Export to mp4 if beneficial (smaller, network-friendly); fallback is original
                            let exportedURL = try? await exportVideoIfNeeded(inputURL: vURL)
                            let candidate = exportedURL ?? vURL

                            // COPY to temp to avoid security scope invalidation mid-upload
                            let localCopy = try copyToTempIfNeeded(candidate, preferredExtension: "mp4")

                            let mId = Database.database().reference().child("tmp").childByAutoId().key ?? UUID().uuidString
                            let storagePath = "posts/\(uid)/\(postId)/videos/\(mId).mp4"
                            let urlStr = try await uploadFileURL(localCopy, path: storagePath, contentType: "video/mp4")

                            // cleanup
                            try? FileManager.default.removeItem(at: localCopy)
                            if let e = exportedURL { try? FileManager.default.removeItem(at: e) }

                            return PostMedia(
                                id: mId, url: urlStr, kind: .video, thumbURL: nil,
                                width: nil, height: nil, duration: nil,
                                order: pickedImages.count + vIdx
                            )
                        }
                    }


                    for try await item in group {
                        if let m = item { uploaded.append(m) }
                    }
                }

                // 2) Compose payload
                var payload: [String: Any] = [
                    "id": postId,
                    "text": caption.trimmingCharacters(in: .whitespacesAndNewlines),
                    "timestamp": now,
                    "userId": uid
                ]

                if !uploaded.isEmpty {
                    var mediaMap: [String: Any] = [:]
                    for m in uploaded {
                        mediaMap[m.id] = [
                            "id": m.id,
                            "url": m.url,
                            "kind": m.kind.rawValue,
                            "thumbURL": m.thumbURL as Any,
                            "width": m.width as Any,
                            "height": m.height as Any,
                            "duration": m.duration as Any,
                            "order": m.order
                        ]
                    }
                    payload["media"] = mediaMap

                    // legacy single-media (only if exactly one)
                    if uploaded.count == 1 {
                        payload["mediaURL"] = uploaded[0].url
                        payload["mediaType"] = uploaded[0].kind.rawValue
                    }
                }

                // 3) Write once
                let ref = Database.database().reference().child("posts").child(postId)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    ref.setValue(payload) { error, _ in
                        if let error = error { cont.resume(throwing: error); return }
                        cont.resume(returning: ())
                    }
                }

                // 4) Update UI
                await MainActor.run {
                    var newItem = UserPost(
                        id: postId,
                        text: payload["text"] as? String ?? "",
                        timestamp: now,
                        userId: uid
                    )
                    newItem.media = uploaded.sorted { $0.order < $1.order }
                    if uploaded.count == 1 {
                        newItem.mediaURL = uploaded[0].url
                        newItem.mediaType = uploaded[0].kind.rawValue
                    }

                    userPosts.insert(newItem, at: 0)
                    savePostsCache()
                    mergeContent()
                    resetPaging()

                    newPostText = ""
                    clearComposerSelection()
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
                    let ns = error as NSError
                    print("❌ Post failed [\(ns.domain):\(ns.code)] \(ns.localizedDescription) userInfo=\(ns.userInfo)")
                    // You could also set a @State var errorBannerText and show it briefly in the UI.
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
            .removeValue { _, _ in fetchUserPostsFast(limit: 180) }
    }

    private func postComment(to post: UserPost) {
        guard !ProfanityFilter.containsBanned(commentText) else {
            print("Comment blocked: contains prohibited words.")
            return
        }
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
        clearComposerSelection()
        editingPostId = nil
        fetchUserPostsFast(limit: 180)
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
    // MARK: NEW: Media gallery (grid/pager)
    // ===============================================
    struct MediaGalleryView: View {
        let media: [PostMedia]

        var body: some View {
            if media.isEmpty {
                EmptyView()
            } else if media.count == 1 {
                Single(media: media[0])
            } else if media.allSatisfy({ $0.kind == .image }) && media.count <= 4 {
                ImageGrid(media: media)
            } else {
                Pager(media: media)
            }
        }

        @ViewBuilder
        private func Single(media: PostMedia) -> some View {
            if media.kind == .video, let url = URL(string: media.url) {
                DynamicVideoPlayer(url: url).cornerRadius(10)
            } else if let url = URL(string: media.url) {
                DynamicAsyncImageView(url: url, cornerRadius: 10)
            }
        }

        private struct ImageGrid: View {
            let media: [PostMedia]
            var body: some View {
                let cols = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(media) { m in
                        if let url = URL(string: m.url) {
                            DynamicAsyncImageView(url: url, cornerRadius: 10)
                                .frame(minHeight: 120)
                        }
                    }
                }
            }
        }

        private struct Pager: View {
            let media: [PostMedia]
            @State private var page: Int = 0
            var body: some View {
                TabView(selection: $page) {
                    ForEach(Array(media.enumerated()), id: \.offset) { idx, m in
                        Group {
                            if m.kind == .video, let url = URL(string: m.url) {
                                DynamicVideoPlayer(url: url)
                            } else if let url = URL(string: m.url) {
                                DynamicAsyncImageView(url: url, cornerRadius: 10)
                            }
                        }
                        .tag(idx)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, -2)
                    }
                }
                .frame(height: 280)
                .tabViewStyle(.page(indexDisplayMode: .automatic))
            }
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
    // MARK: RSS Card – uses DynamicAsyncImageView from mediahandling.swift
    // ===============================================
    struct GossipRSSCardView: View {
        let article: GossipArticle
        @Binding var selectedURL: URL?
        @Binding var showWebView: Bool

        // Video state
        @State private var player: AVPlayer? = nil
        @State private var isVideoReady = false
        @State private var videoFailed = false
        @State private var statusObserver: NSKeyValueObservation?
        @State private var isMuted = true

        // Engagement state
        @State private var likedByMe = false
        @State private var hotByMe = false
        @State private var repostedByMe = false
        @State private var likeCount: Int = 0
        @State private var commentCount: Int = 0
        @State private var hotCount: Int = 0
        @State private var repostCount: Int = 0

        // Comment sheet
        @State private var showCommentSheet = false
        @State private var commentText: String = ""

        // 🔐 Safe hex key for this article (valid RTDB key: 0-9a-f only)
        private var safeArticleKey: String {
            let s = article.id
            if s.isEmpty { return "unknown_key" }
            var hash: UInt64 = 1469598103934665603 // FNV-1a 64-bit
            for u in s.utf8 {
                hash ^= UInt64(u)
                hash &*= 1099511628211
            }
            return String(hash, radix: 16) // hex string
        }

        // Realtime DB root for this article’s engagement
        private var engagementRef: DatabaseReference {
            Database.database().reference()
                .child("engagement")
                .child("rss")
                .child(safeArticleKey)
        }

        // MARK: - Decide if this item has a real video URL (backend-provided)
        private var bestVideoURL: URL? {
            let exts = [".mp4", ".mov", ".m4v", ".webm", ".m3u8"]

            func videoURL(from url: URL?) -> URL? {
                guard let u = url else { return nil }
                let lower = u.absoluteString.lowercased()
                return exts.contains(where: { lower.hasSuffix($0) }) ? u : nil
            }

            // Prefer backend-provided media URLs over article.link
            if let u = videoURL(from: article.imageURL) { return u }
            if let u = videoURL(from: article.thumbURL) { return u }

            // Fallback: if the link itself is a direct video file
            if let linkURL = URL(string: article.link) {
                let lower = article.link.lowercased()
                if exts.contains(where: { lower.hasSuffix($0) }) {
                    return linkURL
                }
            }

            return nil
        }

        private var isVideoItem: Bool {
            bestVideoURL != nil
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {

                // MEDIA AREA: inline video if we have a clean video URL, else image
                ZStack {
                    if let videoURL = bestVideoURL, !videoFailed {
                        ZStack {
                            // Always have an image behind the video for safety
                            if let imgURL = article.thumbURL ?? article.imageURL {
                                DynamicAsyncImageView(url: imgURL, cornerRadius: 12)
                            } else {
                                placeholderView
                            }

                            VideoPlayer(player: player)
                                .onAppear { prepareVideo(url: videoURL) }
                                .onDisappear {
                                    player?.pause()
                                }
                                .opacity(isVideoReady ? 1.0 : 0.0) // fade in when ready

                            if !isVideoReady {
                                // Loading overlay while video prepares
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(1.2)
                            }

                            // Small mute indicator
                            if isVideoReady {
                                HStack {
                                    Spacer()
                                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                .padding(10)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let imgURL = article.thumbURL ?? article.imageURL {
                        DynamicAsyncImageView(url: imgURL, cornerRadius: 12)
                    } else {
                        placeholderView
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isVideoItem {
                        // For video items: tap toggles mute/unmute instead of opening IG
                        toggleMute()
                    } else if let url = URL(string: article.link) {
                        // Non-video items: open provider page
                        selectedURL = url
                        showWebView = true
                    }
                }

                // TEXT
                Text(article.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(3)

                Text(article.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)

                // ENGAGEMENT FOOTER
                HStack(spacing: 22) {

                    // Like
                    Button(action: toggleLike) {
                        HStack(spacing: 6) {
                            Image(systemName: likedByMe ? "hand.thumbsup.fill" : "hand.thumbsup")
                            Text("\(likeCount)")
                        }
                        .foregroundColor(likedByMe ? .blue : .gray)
                    }

                    // Comment
                    Button {
                        showCommentSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.right")
                            Text("\(commentCount)")
                        }
                        .foregroundColor(.gray)
                    }

                    // Hot (🔥)
                    Button(action: toggleHot) {
                        HStack(spacing: 6) {
                            Image(systemName: hotByMe ? "flame.fill" : "flame")
                            Text("\(hotCount)")
                        }
                        .foregroundColor(hotByMe ? .orange : .gray)
                    }

                    // Repost
                    Button(action: toggleRepost) {
                        HStack(spacing: 6) {
                            Image(systemName: repostedByMe ? "arrow.2.squarepath.circle.fill" : "arrow.2.squarepath")
                            Text("\(repostCount)")
                        }
                        .foregroundColor(repostedByMe ? .green : .gray)
                    }
                }
                .font(.callout)
                .padding(.top, 6)
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
            .cornerRadius(14)
            .onAppear {
                loadEngagement()
                recordImpression()
            }
            .onDisappear {
                statusObserver?.invalidate()
                statusObserver = nil
            }
            .sheet(isPresented: $showCommentSheet) {
                commentSheet
            }
        }

        // MARK: - Video helpers

        private func prepareVideo(url: URL) {
            // Don’t recreate player if it already matches
            if let current = (player?.currentItem?.asset as? AVURLAsset)?.url, current == url {
                if isVideoReady { player?.play() }
                return
            }

            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = isMuted
            player = newPlayer
            isVideoReady = false
            videoFailed = false

            statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                DispatchQueue.main.async {
                    switch item.status {
                    case .readyToPlay:
                        isVideoReady = true
                        player?.play()
                    case .failed:
                        videoFailed = true
                        player?.pause()
                    default:
                        break
                    }
                }
            }
        }

        private func toggleMute() {
            isMuted.toggle()
            player?.isMuted = isMuted
            if isVideoReady {
                player?.play()
            }
        }

        // MARK: - Engagement load + toggles

        private func loadEngagement() {
            let me = Auth.auth().currentUser?.uid

            engagementRef.observeSingleEvent(of: .value) { snap in
                var likes = 0, comments = 0, hot = 0, reposts = 0
                var liked = false, hotMine = false, repostMine = false

                if snap.hasChild("likes") {
                    let lsnap = snap.childSnapshot(forPath: "likes")
                    likes = Int(lsnap.childrenCount)
                    if let me = me, lsnap.hasChild(me) { liked = true }
                }

                if snap.hasChild("comments") {
                    let csnap = snap.childSnapshot(forPath: "comments")
                    comments = Int(csnap.childrenCount)
                }

                if snap.hasChild("hot") {
                    let hsnap = snap.childSnapshot(forPath: "hot")
                    hot = Int(hsnap.childrenCount)
                    if let me = me, hsnap.hasChild(me) { hotMine = true }
                }

                if snap.hasChild("reposts") {
                    let rsnap = snap.childSnapshot(forPath: "reposts")
                    reposts = Int(rsnap.childrenCount)
                    if let me = me, rsnap.hasChild(me) { repostMine = true }
                }

                DispatchQueue.main.async {
                    likeCount = likes
                    commentCount = comments
                    hotCount = hot
                    repostCount = reposts
                    likedByMe = liked
                    hotByMe = hotMine
                    repostedByMe = repostMine
                }
            }
        }

        private func toggleLike() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let r = engagementRef.child("likes").child(uid)
            let already = likedByMe

            likedByMe.toggle()
            likeCount = max(0, likeCount + (already ? -1 : 1))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            r.observeSingleEvent(of: .value) { snap in
                if snap.exists() { r.removeValue() } else { r.setValue(true) }
            }
        }

        private func toggleHot() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let r = engagementRef.child("hot").child(uid)
            let already = hotByMe

            hotByMe.toggle()
            hotCount = max(0, hotCount + (already ? -1 : 1))
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

            r.observeSingleEvent(of: .value) { snap in
                if snap.exists() { r.removeValue() } else { r.setValue(true) }
            }
        }

        private func toggleRepost() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let r = engagementRef.child("reposts").child(uid)
            let already = repostedByMe

            repostedByMe.toggle()
            repostCount = max(0, repostCount + (already ? -1 : 1))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            r.observeSingleEvent(of: .value) { snap in
                if snap.exists() { r.removeValue() } else { r.setValue(true) }
            }
        }

        // MARK: - Comments for RSS

        private var commentSheet: some View {
            VStack {
                Text("Comment").font(.headline).padding(.top)

                TextField("Your comment…", text: $commentText, axis: .vertical)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
                    .foregroundColor(.white)
                    .lineLimit(3...5)

                Button("Post Comment") {
                    postComment()
                }
                .padding()
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
            .background(Color.black)
        }

        private func postComment() {
            let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let uid = Auth.auth().currentUser?.uid else { return }

            if ProfanityFilter.containsBanned(trimmed) {
                print("RSS comment blocked: contains prohibited words.")
                return
            }

            let ref = engagementRef.child("comments").childByAutoId()
            let payload: [String: Any] = [
                "userId": uid,
                "text": trimmed,
                "timestamp": Date().timeIntervalSince1970
            ]

            ref.setValue(payload) { error, _ in
                DispatchQueue.main.async {
                    if error == nil {
                        commentText = ""
                        commentCount += 1
                        showCommentSheet = false
                    } else {
                        print("❌ Failed to post RSS comment: \(error?.localizedDescription ?? "unknown")")
                    }
                }
            }
        }

        // MARK: - Impressions

        private func recordImpression() {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let ref = Database.database().reference()
                .child("impressions")
                .child("rss")
                .child(safeArticleKey)
                .childByAutoId()

            ref.setValue([
                "userId": uid,
                "timestamp": Date().timeIntervalSince1970
            ])
        }

        // MARK: - Misc helpers

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



/*
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
*/
    
    
    // ===============================================
    // MARK: IG-Style Composer Sheet
    // ===============================================
    struct IGStylePostComposer: View {
        let image: UIImage?
        let videoURL: URL?
        let filterName: String

        @State private var caption: String = ""
        @State private var isPosting = false
        @State private var progress: Double = 0

        var onPost: (_ caption: String, _ mediaURL: URL?, _ image: UIImage?) -> Void

        var body: some View {
            VStack(spacing: 14) {
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
                    onPost(caption, videoURL, image)
                } label: {
                    HStack {
                        if isPosting { ProgressView(value: progress).progressViewStyle(.linear).frame(width: 20) }
                        Text(isPosting ? "Posting…" : "Post").bold()
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

    // ===============================================
    // MARK: NEW: Composer Selected Preview (grid/pager like Twitter)
    // ===============================================
    struct ComposerSelectedPreview: View {
        let images: [UIImage]
        let videos: [URL]

        var body: some View {
            let total = images.count + videos.count
            Group {
                if total == 1 {
                    oneUp
                } else if total == 2 {
                    twoUp
                } else if total == 3 {
                    threeUp
                } else {
                    fourUp // 4+ shows first 4
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        private var oneUp: some View {
            ZStack {
                if let img = images.first {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let v = videos.first {
                    VideoPlayer(player: AVPlayer(url: v))
                }
            }
            .frame(height: 240).clipped()
        }

        private var twoUp: some View {
            HStack(spacing: 6) {
                thumb(0).frame(height: 200).clipped()
                thumb(1).frame(height: 200).clipped()
            }
        }

        private var threeUp: some View {
            HStack(spacing: 6) {
                thumb(0).frame(width: UIScreen.main.bounds.width * 0.5 - 24, height: 220).clipped()
                VStack(spacing: 6) {
                    thumb(1).frame(height: 107).clipped()
                    thumb(2).frame(height: 107).clipped()
                }
            }
        }

        private var fourUp: some View {
            let w = UIScreen.main.bounds.width
            let cellH = 100.0
            return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                thumb(0).frame(height: cellH).clipped()
                thumb(1).frame(height: cellH).clipped()
                thumb(2).frame(height: cellH).clipped()
                thumb(3).frame(height: cellH).clipped()
            }
        }

        @ViewBuilder
        private func thumb(_ idx: Int) -> some View {
            let seq = images.map { Either.img($0) } + videos.map { Either.vid($0) }
            let item = seq.indices.contains(idx) ? seq[idx] : nil
            switch item {
            case .img(let ui):
                Image(uiImage: ui).resizable().scaledToFill()
            case .vid(let url):
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Image(systemName: "play.fill").font(.title2).foregroundColor(.white)
                    // poster frame generation could be added later if needed
                    VideoPlayer(player: AVPlayer(url: url)).opacity(0.0001) // keep simple; poster not required
                }
            case .none:
                EmptyView()
            }
        }

        private enum Either { case img(UIImage), vid(URL) }
    }

    // ===============================================
    // MARK: NEW: System Multi Media Picker (Photos picker)
// ===============================================
    struct SystemMultiMediaPicker: UIViewControllerRepresentable {
        let selectionLimit: Int
        var onComplete: (_ images: [UIImage], _ videos: [URL]) -> Void

        func makeUIViewController(context: Context) -> PHPickerViewController {
            var cfg = PHPickerConfiguration(photoLibrary: .shared())
            cfg.selectionLimit = selectionLimit
            cfg.filter = .any(of: [.images, .videos])
            cfg.preferredAssetRepresentationMode = .automatic
            let vc = PHPickerViewController(configuration: cfg)
            vc.delegate = context.coordinator
            return vc
        }

        func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, PHPickerViewControllerDelegate {
            let parent: SystemMultiMediaPicker
            init(_ parent: SystemMultiMediaPicker) { self.parent = parent }

            func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
                picker.dismiss(animated: true)
                guard !results.isEmpty else {
                    parent.onComplete([], [])
                    return
                }

                let group = DispatchGroup()
                var images: [UIImage] = []
                var videos: [URL] = []

                for item in results {
                    let provider = item.itemProvider

                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        group.enter()
                        provider.loadObject(ofClass: UIImage.self) { obj, _ in
                            defer { group.leave() }
                            if let img = obj as? UIImage { images.append(img) }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                        group.enter()
                        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                            defer { group.leave() }
                            guard let srcURL = url else { return }
                            // copy to temp we control
                            let tmp = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString)
                                .appendingPathExtension("mp4")
                            do {
                                if FileManager.default.fileExists(atPath: tmp.path) { try? FileManager.default.removeItem(at: tmp) }
                                try FileManager.default.copyItem(at: srcURL, to: tmp)
                                videos.append(tmp)
                            } catch { }
                        }
                    }
                }

                group.notify(queue: .main) {
                    // Trim to selectionLimit total, like X (max 4)
                    var imgs = images
                    var vids = videos
                    let total = imgs.count + vids.count
                    if total > self.parent.selectionLimit {
                        // prefer keeping earlier items
                        let over = total - self.parent.selectionLimit
                        if vids.count >= over {
                            vids = Array(vids.prefix(vids.count - over))
                        } else {
                            let remain = over - vids.count
                            vids = []
                            imgs = Array(imgs.prefix(max(0, imgs.count - remain)))
                        }
                    }
                    self.parent.onComplete(imgs, vids)
                }
            }
        }
    }
}

/*
// ===============================================
// MARK: Notification used by LiveCapture
// ===============================================
extension Notification.Name {
    static let inviteOrbCapturedMedia = Notification.Name("inviteOrbCapturedMedia")
}
*/
extension View {
    @ViewBuilder
    func applySheetStyle() -> some View {
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.large])        // or [.medium, .large]
                .presentationDragIndicator(.visible)  // shows the native pull-down bar
                .interactiveDismissDisabled(false)    // keep swipe-to-dismiss enabled
        } else {
            self
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
