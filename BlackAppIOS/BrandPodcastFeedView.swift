import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth
import AVKit

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

struct BrandPodcastFeedView: View {
    var brand: BrandModel
    @State private var episodes: [PodcastEpisode] = []
    @State private var isLoading = true
    @State private var purchasedEpisodeIds: Set<String> = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(episodes) { ep in
                    PodcastEpisodeCard(
                        episode: ep,
                        hasPurchased: purchasedEpisodeIds.contains(ep.id),
                        brandOwnerId: brand.ownerId,
                        onPurchase: { openCheckout(for: ep) }
                    )
                    .padding(.horizontal)
                }

                if isLoading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).padding()
                } else if episodes.isEmpty {
                    Text("No podcast episodes available.")
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
        .navigationTitle("\(brand.name) Podcasts")
        .onAppear {
            fetchPodcastEpisodes()
            fetchPurchasedEpisodes()
        }
    }

    // MARK: - Checkout

    private func openCheckout(for ep: PodcastEpisode) {
        // require login like your original flow; remove this guard to allow guest checkout
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let url = Checkout.url(
            tool: "podcast",
            brandId: brand.id,
            itemId: ep.id,
            title: ep.title,
            price: ep.price,
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

    // MARK: - Fetchers with fallbacks

    func fetchPodcastEpisodes() {
        print("🎙️ Fetching podcast episodes for brand ID: \(brand.id)")

        let p1 = Database.database().reference().child("brands").child(brand.id).child("podcasts")
        let p2 = Database.database().reference().child("brandPodcasts").child(brand.id)

        func read(_ ref: DatabaseReference, label: String, onEmpty: @escaping () -> Void) {
            print("🔎 Trying podcast path: \(label)")
            ref.observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists() else { print("⚠️ No data at \(label)"); onEmpty(); return }
                var temp: [PodcastEpisode] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let dict = child.value as? [String: Any],
                       let ep = PodcastEpisode.from(dict: dict, id: child.key) {
                        temp.append(ep)
                    } else {
                        print("❌ Episode parse failed for \(child.key) @ \(label)")
                    }
                }
                self.episodes = temp.sorted(by: { $0.timestamp > $1.timestamp })
                self.isLoading = false
                print("✅ Loaded \(temp.count) episodes from \(label)")
            }
        }

        read(p1, label: "brands/\(brand.id)/podcasts") {
            read(p2, label: "brandPodcasts/\(brand.id)") {
                self.episodes = []
                self.isLoading = false
                print("🚫 No podcast episodes found in any known path.")
            }
        }
    }

    func fetchPurchasedEpisodes() {
        // Updated to universal checkout schema:
        // purchases/{uid}/{purchaseId} with fields { tool, itemId, ... }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            var ids = Set<String>()
            for case let child as DataSnapshot in snapshot.children {
                if let val = child.value as? [String: Any],
                   let tool = val["tool"] as? String,
                   let itemId = val["itemId"] as? String,
                   tool == "podcast" {
                    ids.insert(itemId)
                }
            }
            self.purchasedEpisodeIds = ids
        }
    }
}

// MARK: - Model

struct PodcastEpisode: Identifiable {
    var id: String
    var title: String
    var description: String
    var audioURL: String
    var timestamp: TimeInterval
    var price: Double
    var isPremium: Bool

    static func from(dict: [String: Any], id: String) -> PodcastEpisode? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let audioURL = dict["audioURL"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        let price = dict["price"] as? Double ?? 0.0
        let isPremium = dict["isPremium"] as? Bool ?? false
        return PodcastEpisode(id: id, title: title, description: description, audioURL: audioURL, timestamp: timestamp, price: price, isPremium: isPremium)
    }
}

// MARK: - Card

struct PodcastEpisodeCard: View {
    let episode: PodcastEpisode
    let hasPurchased: Bool
    let brandOwnerId: String
    var onPurchase: () -> Void

    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var isSaved = false
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(episode.title)
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
                Button(action: toggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundColor(isSaved ? .red : .white)
                }
                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
            }

            Text(episode.description)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(4)

            HStack {
                Spacer()
                if episode.isPremium && !hasPurchased {
                    Button(action: onPurchase) {
                        Label("Buy to Listen - $\(String(format: "%.2f", episode.price))", systemImage: "cart.fill")
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                } else {
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .foregroundColor(.white)
                    }
                }
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 6)
        .onAppear { checkSavedStatus() }
        .sheet(isPresented: $showShareSheet) {
            PodcastShareSheet(activityItems: [URL(string: episode.audioURL) as Any, "🎧 \(episode.title) on BlackApp"])
        }
    }

    func togglePlayback() {
        if player == nil, let url = URL(string: episode.audioURL) {
            player = AVPlayer(url: url)
        }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }

    func toggleSave() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedPodcasts").child(uid).child(episode.id)
        if isSaved { ref.removeValue() } else { ref.setValue(true) }
        isSaved.toggle()
    }

    func checkSavedStatus() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedPodcasts").child(uid).child(episode.id)
        ref.observeSingleEvent(of: .value) { snap in
            isSaved = snap.exists()
        }
    }
}

// unique share wrapper
struct PodcastShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
