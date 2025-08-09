import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth
import WebKit
import FeedKit
import AVKit

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
    @State private var selectedVideoURL: URL? = nil
    @State private var selectedMediaType: ImagePicker.MediaType? = nil // .image or .video
    @State private var trendingTags: [String] = []
    @State private var showAllTags = false
    @State private var selectedTagFilter: String? = nil
    
    // UI state
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var showImagePicker = false
    @State private var isLoading = true
    @State private var commentTargetPost: UserPost? = nil
    @State private var commentText: String = ""
    @State private var userProfiles: [String: (name: String, imageURL: String?)] = [:]
    
    // RSS URLs
    private let rssFeedURLs = [
       
        "https://swayafrica.com/category/Entertainment/feed/",
        "https://rss.app/feeds/MDlghVUX5yvecvRG.xml",
        "https://rss.app/feeds/wlHd9RRJ1VuDYpHX.xml/",
        "https://blackculture.com/news/rss/category/arts_and_entertainment",
        "https://media.rss.com/afrosinthediaspora/feed.xml",
        "https://digitalcollections.sit.edu/african_diaspora_research/announcements.html",
        "https://theshaderoom.com/latest-tea/feed/"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView(onLogoTap: reloadContent, onSearchTap: {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let root = scene.windows.first?.rootViewController else { return }
                root.present(UIHostingController(rootView: SearchView()), animated: true)
            })
            
            if !trendingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(trendingTags, id: \.self) { tag in
                            Text(tag)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedTagFilter == tag ? Color.blue.opacity(0.7) : Color.gray.opacity(0.3))
                                .foregroundColor(.white)
                                .cornerRadius(16)
                                .onTapGesture {
                                    if selectedTagFilter == tag {
                                        selectedTagFilter = nil
                                    } else {
                                        selectedTagFilter = tag
                                    }
                                    mergeContent()
                                }
                        }
                        
                        Button(action: {
                            showAllTags.toggle()
                            updateTrendingTags()
                        }) {
                            Text(showAllTags ? "Less" : "More")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.gray.opacity(0.3))
                                .foregroundColor(.blue)
                                .cornerRadius(16)
                        }
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
                        }
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
            }
            
            ZStack(alignment: .topLeading) {
                TextEditor(text: $newPostText)
                    .frame(height: 60)
                    .padding(8)
                    .foregroundColor(.white)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                
                if newPostText.isEmpty {
                    Text(editingPostId == nil ? "What’s the gist? (use #tags)" : "Editing post...")
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 14)
                        .padding(.horizontal, 14)
                        .zIndex(1)
                }
            }
            .padding(.horizontal)
            
            
            // Media preview if selected
            if let type = selectedMediaType {
                switch type {
                case .image:
                    if let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                            .padding(.horizontal)
                    }
                case .video:
                    if let url = selectedVideoURL {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 220)
                            .cornerRadius(8)
                            .padding(.horizontal)
                    }
                }
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
                VStack {
                    Spacer()
                    ProgressView("Loading...")
                        .foregroundColor(.white)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(combinedFeed.sorted(by: { $0.timestamp > $1.timestamp })) { item in
                    item.view($selectedURL, $showWebView)
                }
                .listStyle(.plain)
            }
            
        }
        .onAppear(perform: reloadContent)
        .background(Color.black)
        
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showWebView) {
            if let url = selectedURL {
                WebView(url: url)
            }
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

        func save(mediaURL: String?, mediaType: String?) {
            var payload: [String: Any] = [
                "text": newPostText,
                "timestamp": ts,
                "userId": uid
            ]
            if let mediaURL { payload["mediaURL"] = mediaURL }
            if let mediaType { payload["mediaType"] = mediaType }
            ref.setValue(payload)
            resetPostFields()
        }

        // Branch by selected media type
        if selectedMediaType == .image, let data = selectedImage?.jpegData(compressionQuality: 0.85) {
            let sref = Storage.storage().reference().child("post_images/\(id).jpg")
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"
            sref.putData(data, metadata: metadata) { _, error in
                if let error { print("🖼️ upload error:", error); save(mediaURL: nil, mediaType: nil); return }
                sref.downloadURL { url, _ in
                    save(mediaURL: url?.absoluteString, mediaType: "image")
                }
            }
            return
        }

        if selectedMediaType == .video, let fileURL = selectedVideoURL {
            let sref = Storage.storage().reference().child("post_videos/\(id).mov")
            let metadata = StorageMetadata()
            metadata.contentType = "video/quicktime" // or "video/mp4" if you export mp4s
            sref.putFile(from: fileURL, metadata: metadata) { _, error in
                if let error { print("🎥 upload error:", error); save(mediaURL: nil, mediaType: nil); return }
                sref.downloadURL { url, _ in
                    save(mediaURL: url?.absoluteString, mediaType: "video")
                }
            }
            return
        }

        // No media selected → text-only
        save(mediaURL: nil, mediaType: nil)
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
    
    func updateTrendingTags() {
        var tagCount: [String: Int] = [:]
        
        for post in userPosts {
            for tag in extractHashtags(from: post.text) {
                tagCount[tag, default: 0] += 1
            }
        }

        for article in rssArticles {
            let combined = "\(article.title) \(article.description)"
            for tag in extractHashtags(from: combined) {
                tagCount[tag, default: 0] += 1
            }
        }

        trendingTags = Array(tagCount.sorted { $0.value > $1.value }.prefix(10).map { "#\($0.key)" })
    }

    // MARK: - Fetch User Posts + Likes + Comments (Optimized Lazy Load)
    
    func fetchUserPosts(limit: UInt = 10) {
        let pRef = Database.database().reference().child("posts")
        let lRef = Database.database().reference().child("likes")
        let cRef = Database.database().reference().child("comments")
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        // Limit posts to reduce initial load time
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
                            id: cs.key,
                            text: t,
                            timestamp: ts,
                            userId: u,
                            mediaURL: d["mediaURL"] as? String,
                            mediaType: d["mediaType"] as? String
                        ))
                    }
                }
                
                // Fetch likes
                lRef.observeSingleEvent(of: .value) { lsnap in
                    var liked: Set<String> = []
                    for case let ps as DataSnapshot in lsnap.children {
                        if ps.hasChild(uid) {
                            liked.insert(ps.key)
                        }
                    }
                    
                    // Fetch comments
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
                        
                        // Apply likes/comments to posts
                        for i in arr.indices {
                            let p = arr[i].id
                            arr[i].isLikedByCurrentUser = liked.contains(p)
                            arr[i].comments = cm[p] ?? []
                        }
                        
                        // Assign posts (sorted)
                        userPosts = arr.sorted { $0.timestamp > $1.timestamp }
                        
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
                                            
                                        }
                                    }
                                }
                            }
    
    // MARK: - Optimized Fetch RSS Articles in Chunks

    func fetchFeedsInChunks(chunkSize: Int = 3) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for c in chunks {
                var chunkArticles: [RSSArticle] = []

                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in c {
                        group.addTask { await fetchFeed(urlString: url) }
                    }

                    for await articles in group {
                        chunkArticles.append(contentsOf: articles)
                    }
                }

                await MainActor.run {
                    // Prevent duplicates by title
                    let existingTitles = Set(rssArticles.map { $0.title })
                    let filtered = chunkArticles.filter { !existingTitles.contains($0.title) }
                    rssArticles.append(contentsOf: filtered)
                    mergeContent()
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
            let result = try FeedParser(data: data).parse()

            guard case .success(let feed) = result else { return [] }

            let items = feed.rssFeed?.items ?? []

            return items.prefix(3).compactMap { item -> RSSArticle? in
                guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let link = item.link,
                      let desc = item.description?.strippedHTML(),
                      let pubDate = item.pubDate else {
                    return nil // ✅ safely skip invalid entries
                }

                // Detect video
                let enclosureURL = item.enclosure?.attributes?.url
                let mimeType = item.enclosure?.attributes?.type ?? ""
                let isVideo = mimeType.contains("video")

                // Video URL
                let videoURL = isVideo ? enclosureURL.flatMap(URL.init) : nil

                // Image URL
                var imageURL: URL? = nil
                if !isVideo {
                    if let imgFromEnclosure = enclosureURL, let validURL = URL(string: imgFromEnclosure) {
                        imageURL = validURL
                    } else if let fallback = extractImageURL(from: item.description ?? ""), let fallbackURL = URL(string: fallback) {
                        imageURL = fallbackURL
                    }
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
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
              match.numberOfRanges > 1 else {
            return nil
        }
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
                let profileURL = profile?.imageURL
                
                return AnyIdentifiablePost(timestamp: post.timestamp, id: post.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Profile header
                        HStack {
                            Text(displayName)
                                .foregroundColor(.white)
                                .font(.subheadline)
                            Spacer()
                        }

                        
                        // Post text
                        TextWithHashtagsView(text: post.text) { tappedTag in
                            selectedTagFilter = tappedTag
                        }

                        .padding(.vertical, 4)
                        
                        // Optional image
                        if let mediaURL = post.mediaURL, let url = URL(string: mediaURL) {
                            if post.mediaType == "video" {
                                VideoPlayer(player: AVPlayer(url: url))
                                    .frame(height: 200)
                                    .cornerRadius(10)
                            } else {
                                AsyncImage(url: url) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(maxHeight: 200)
                                .cornerRadius(10)
                            }
                        }
                        
                        // Timestamp
                        Text(post.dateFormatted)
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        // Reactions
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
                        
                        // Comments
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
        
        // Update feed with animation on main thread
        DispatchQueue.main.async {
            withAnimation {
                combinedFeed = (filteredUserPosts + filteredRSS)
                    .sorted { $0.timestamp > $1.timestamp }
            }
        }
    }
}
func extractHashtags(from text: String) -> [String] {
    let regex = try? NSRegularExpression(pattern: "#(\\w+)", options: [])
    let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) ?? []
    return matches.map {
        let range = Range($0.range(at: 1), in: text)!
        return String(text[range]).lowercased()
    }
}
struct TextWithHashtagsView: View {
    let text: String
    let onHashtagTap: (String) -> Void

    var body: some View {
        let words = text.split(separator: " ")
        
        // Use a horizontal stack to lay words out
        return WrapHStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                if word.starts(with: "#") {
                    let tag = String(word)
                    Text(tag)
                        .foregroundColor(.blue)
                        .bold()
                        .onTapGesture {
                            onHashtagTap(tag.lowercased().trimmingCharacters(in: ["#"]))
                        }
                } else {
                    Text(String(word))
                        .foregroundColor(.white)
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
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
    }
}
