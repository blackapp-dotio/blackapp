import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth

struct BrandBlogFeedView: View {
    var brand: BrandModel
    @State private var blogPosts: [BrandBlogPost] = []
    @State private var isLoading = true
    @State private var purchasedPostIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(blogPosts) { post in
                    BlogPostCard(
                        post: post,
                        hasPurchased: purchasedPostIds.contains(post.id),
                        onPurchase: {
                            guard let uid = Auth.auth().currentUser?.uid else { return }
                            PurchaseManager.shared.startCheckout(
                                buyerId: uid,
                                sellerId: brand.ownerId,
                                basePrice: post.price,
                                itemType: "blog",
                                itemId: post.id,
                                itemTitle: post.title,
                                itemImageURL: ""
                            )
                        }
                    )
                    .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding()
                } else if blogPosts.isEmpty {
                    Text("No blog posts available.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .padding(.top)
        }
        .background(
            LinearGradient(gradient: Gradient(colors: [.black, .gray.opacity(0.3)]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        )
        .navigationTitle("\(brand.name) Blog")
        .onAppear {
            fetchBlogPosts()
            fetchPurchasedBlogPosts()
        }
    }

    // MARK: - Fetchers (with path fallbacks)

    func fetchBlogPosts() {
        // Primary per your DB sample: brands/{brandId}/blog
        let p1 = Database.database().reference()
            .child("brands").child(brand.id).child("blog")

        // Fallbacks for older/alternate layouts:
        let p2 = Database.database().reference()
            .child("brands").child(brand.id).child("blogs")
        let p3 = Database.database().reference()
            .child("brandBlogs").child(brand.id)

        func read(_ ref: DatabaseReference, label: String, onEmpty: @escaping () -> Void) {
            print("📝 Trying blog path: \(label)")
            ref.observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists() else {
                    print("⚠️ No data at \(label)")
                    onEmpty()
                    return
                }

                var temp: [BrandBlogPost] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let dict = child.value as? [String: Any],
                       let post = BrandBlogPost.from(dict: dict, id: child.key) {
                        temp.append(post)
                    } else {
                        print("❌ Blog parse failed for \(child.key) at \(label)")
                    }
                }

                self.blogPosts = temp.sorted(by: { $0.timestamp > $1.timestamp })
                self.isLoading = false
                print("✅ Loaded \(temp.count) blog posts from \(label)")
            }
        }

        // Attempt in order: primary → fallback 1 → legacy
        read(p1, label: "brands/\(brand.id)/blog") {
            read(p2, label: "brands/\(brand.id)/blogs") {
                read(p3, label: "brandBlogs/\(brand.id)") {
                    self.blogPosts = []
                    self.isLoading = false
                    print("🚫 No blog posts found in any known path.")
                }
            }
        }
    }

    func fetchPurchasedBlogPosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(uid)

        ref.observeSingleEvent(of: .value) { snapshot in
            var ids: Set<String> = []
            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let val = snap.value as? [String: Any],
                   val["type"] as? String == "blog" {
                    ids.insert(snap.key)
                }
            }
            self.purchasedPostIds = ids
        }
    }
}

// MARK: - BrandBlogPost Model

struct BrandBlogPost: Identifiable {
    var id: String
    var title: String
    var content: String   // mapped from "body" (or "content" fallback)
    var timestamp: TimeInterval
    var price: Double
    var isPremium: Bool

    static func from(dict: [String: Any], id: String) -> BrandBlogPost? {
        guard let title = dict["title"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }

        // Your sample uses "body"
        let body = (dict["body"] as? String) ?? (dict["content"] as? String) ?? ""

        let price = dict["price"] as? Double ?? 0.0
        let isPremium = dict["isPremium"] as? Bool ?? false

        return BrandBlogPost(
            id: id,
            title: title,
            content: body,
            timestamp: timestamp,
            price: price,
            isPremium: isPremium
        )
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

// MARK: - Blog Post Card

struct BlogPostCard: View {
    let post: BrandBlogPost
    var hasPurchased: Bool
    var onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(post.title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(post.formattedDate)
                .font(.caption)
                .foregroundColor(.gray)

            Text(post.isPremium && !hasPurchased
                 ? "🔒 Premium blog post. Unlock to read full content."
                 : String(post.content.prefix(200)) + "…")
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(5)

            HStack {
                Spacer()
                if post.isPremium && !hasPurchased {
                    Button(action: onPurchase) {
                        Label("Unlock - $\(String(format: "%.2f", post.price))", systemImage: "lock.fill")
                            .font(.footnote)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                } else {
                    Button(action: {
                        // TODO: navigate to a full post detail view
                    }) {
                        Text("Read More")
                            .font(.footnote)
                            .foregroundColor(.purple)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 6)
    }
}
