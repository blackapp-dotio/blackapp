import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth

// MARK: - Universal Checkout URL Builder
fileprivate enum Checkout {
    /// Hosted universal checkout (Card or PayPal via Braintree)
    static let base = "https://blackapp.io/checkout" // keep if you rewrote /checkout → /checkout.html

    static func url(
        tool: String,
        brandId: String,
        itemId: String,
        title: String,
        price: Double,
        currency: String = "USD",
        imagePath: String? = nil,
        userId: String?,
        allowQty: Bool = false,
        minQty: Int = 1,
        maxQty: Int = 1,
        returnUrl: String = "blackappios://done",
        clientTokenUrl: String? = nil,  // optional override
        chargeUrl: String? = nil        // optional override
    ) -> URL? {
        var comps = URLComponents(string: base)
        var q: [URLQueryItem] = [
            .init(name: "tool", value: tool),
            .init(name: "brandId", value: brandId),
            .init(name: "itemId", value: itemId),
            .init(name: "title", value: title),
            .init(name: "price", value: String(format: "%.2f", price)),
            .init(name: "currency", value: currency),
            .init(name: "allowQty", value: allowQty ? "1" : "0"),
            .init(name: "minQty", value: "\(minQty)"),
            .init(name: "maxQty", value: "\(maxQty)"),
            .init(name: "returnUrl", value: returnUrl)
        ]
        if let imagePath, !imagePath.isEmpty {
            q.append(.init(name: "imagePath", value: imagePath))
        }
        if let userId, !userId.isEmpty {
            q.append(.init(name: "userId", value: userId))
        }
        if let clientTokenUrl, !clientTokenUrl.isEmpty {
            q.append(.init(name: "clientTokenUrl", value: clientTokenUrl))
        }
        if let chargeUrl, !chargeUrl.isEmpty {
            q.append(.init(name: "chargeUrl", value: chargeUrl))
        }
        comps?.queryItems = q
        return comps?.url
    }
}

struct BrandBlogFeedView: View {
    var brand: BrandModel
    @State private var blogPosts: [BrandBlogPost] = []
    @State private var isLoading = true
    @State private var purchasedPostIds: Set<String> = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(blogPosts) { post in
                    BlogPostCard(
                        post: post,
                        hasPurchased: purchasedPostIds.contains(post.id),
                        onPurchase: { openCheckout(for: post) }
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

    // MARK: - Checkout

    private func openCheckout(for post: BrandBlogPost) {
        // Require login like your original flow; remove this guard to allow guest checkout
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let url = Checkout.url(
            tool: "blog",
            brandId: brand.id,
            itemId: post.id,
            title: post.title,
            price: post.price,
            currency: "USD",
            imagePath: nil,
            userId: uid,
            allowQty: false,
            minQty: 1,
            maxQty: 1,
            returnUrl: "blackappios://done"
            // clientTokenUrl: "https://blackapp.io/api/client_token",
            // chargeUrl: "https://blackapp.io/api/charge_braintree"
        )
        if let url { openURL(url) }
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
        // Updated to universal checkout schema:
        // purchases/{uid}/{purchaseId} with fields { tool, itemId, ... }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(uid)

        ref.observeSingleEvent(of: .value) { snapshot in
            var ids: Set<String> = []
            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let val = snap.value as? [String: Any],
                   let tool = val["tool"] as? String,
                   let itemId = val["itemId"] as? String,
                   tool == "blog" {
                    ids.insert(itemId)
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
