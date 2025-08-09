import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth

struct BrandConsoleFeedView: View {
    var brand: BrandModel
    @State private var consolePosts: [ConsolePost] = []
    @State private var isLoading = true
    @State private var purchasedPostIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(consolePosts) { post in
                    ConsolePostCard(
                        post: post,
                        hasPurchased: purchasedPostIds.contains(post.id),
                        onPurchase: {
                            guard let uid = Auth.auth().currentUser?.uid else { return }
                            PurchaseManager.shared.startCheckout(
                                buyerId: uid,
                                sellerId: brand.ownerId,
                                basePrice: post.price,
                                itemType: "console",
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
                } else if consolePosts.isEmpty {
                    Text("No console updates yet.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .padding(.top)
        }
        .navigationTitle("\(brand.name) Console")
        .background(
            LinearGradient(gradient: Gradient(colors: [.black, .gray.opacity(0.3)]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        )
        .onAppear {
            fetchConsolePosts()
            fetchPurchasedConsolePosts()
        }
    }

    // ✅ FIXED: Moved this inside the struct so it can access `self`
    func fetchConsolePosts() {
        let ref = Database.database().reference().child("brandConsole").child(brand.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [ConsolePost] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let post = ConsolePost.from(dict: dict, id: child.key) {
                    temp.append(post)
                }
            }

            self.consolePosts = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoading = false
        }
    }

    // ✅ FIXED: Now properly scoped to access `self.purchasedPostIds`
    func fetchPurchasedConsolePosts() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(uid)

        ref.observeSingleEvent(of: .value) { snapshot in
            var ids: Set<String> = []
            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let val = snap.value as? [String: Any],
                   val["type"] as? String == "console" {
                    ids.insert(snap.key)
                }
            }
            self.purchasedPostIds = ids
        }
    }
}

// MARK: - ConsolePost Model

struct ConsolePost: Identifiable {
    let id: String
    let title: String
    let body: String
    let timestamp: TimeInterval
    let isPremium: Bool
    let price: Double

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func from(dict: [String: Any], id: String) -> ConsolePost? {
        guard let title = dict["title"] as? String,
              let body = dict["body"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }

        let isPremium = dict["isPremium"] as? Bool ?? false
        let price = dict["price"] as? Double ?? 0.0

        return ConsolePost(id: id, title: title, body: body, timestamp: timestamp, isPremium: isPremium, price: price)
    }
}

// MARK: - ConsolePostCard

struct ConsolePostCard: View {
    let post: ConsolePost
    var hasPurchased: Bool
    var onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(post.title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)

            if post.isPremium && !hasPurchased {
                Text("🔒 This console update is premium. Unlock to view.")
                    .foregroundColor(.white.opacity(0.6))
            } else {
                Text(post.body)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
            }

            Text(post.formattedDate)
                .font(.caption)
                .foregroundColor(.gray)

            if post.isPremium && !hasPurchased {
                HStack {
                    Spacer()
                    Button(action: onPurchase) {
                        Label("Unlock - $\(String(format: "%.2f", post.price))", systemImage: "lock.fill")
                            .font(.footnote)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 5)
    }
}
