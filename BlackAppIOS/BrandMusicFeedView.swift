import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth
import AVFoundation

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

struct BrandMusicFeedView: View {
    var brand: BrandModel
    @State private var tracks: [MusicTrack] = []
    @State private var isLoading = true
    @State private var purchasedTrackIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForEach(tracks) { track in
                    MusicTrackCard(
                        track: track,
                        hasPurchased: purchasedTrackIds.contains(track.id),
                        brand: brand
                    )
                    .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding()
                } else if tracks.isEmpty {
                    Text("No music tracks uploaded yet.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .padding(.top)
        }
        .background(
            LinearGradient(gradient: Gradient(colors: [.black, .gray.opacity(0.4)]),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .navigationTitle("\(brand.name) Music")
        .onAppear {
            fetchTracks()
            fetchPurchasedTracks()
        }
    }

    // MARK: - Fetchers (with fallbacks)

    func fetchTracks() {
        print("🎧 Fetching music for brand ID: \(brand.id)")

        let p1 = Database.database().reference().child("brands").child(brand.id).child("music")
        let p2 = Database.database().reference().child("brandMusic").child(brand.id)

        func read(_ ref: DatabaseReference, label: String, onEmpty: @escaping () -> Void) {
            print("🎵 Trying music path: \(label)")
            ref.observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists() else {
                    print("⚠️ No music at \(label)")
                    onEmpty()
                    return
                }
                var tmp: [MusicTrack] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let dict = child.value as? [String: Any],
                       let track = MusicTrack.from(dict: dict, id: child.key) {
                        tmp.append(track)
                    } else {
                        print("❌ Music parse failed for \(child.key) @ \(label)")
                    }
                }
                self.tracks = tmp.sorted(by: { $0.timestamp > $1.timestamp })
                self.isLoading = false
                print("✅ Loaded \(tmp.count) tracks from \(label)")
            }
        }

        read(p1, label: "brands/\(brand.id)/music") {
            read(p2, label: "brandMusic/\(brand.id)") {
                self.tracks = []
                self.isLoading = false
                print("🚫 No tracks found in any known path.")
            }
        }
    }

    func fetchPurchasedTracks() {
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
                   tool == "music" {
                    ids.insert(itemId)
                }
            }
            self.purchasedTrackIds = ids
        }
    }
}

// MARK: - Model

struct MusicTrack: Identifiable {
    var id: String
    var title: String
    var audioURL: String
    var description: String
    var timestamp: TimeInterval
    var price: Double
    var isPremium: Bool
    var imageURL: String? // optional cover

    static func from(dict: [String: Any], id: String) -> MusicTrack? {
        guard let title = dict["title"] as? String,
              let audioURL = dict["audioURL"] as? String,
              let description = dict["description"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        let price = dict["price"] as? Double ?? 0.0
        let isPremium = dict["isPremium"] as? Bool ?? false
        let imageURL = (dict["imageURL"] as? String)?.nilIfEmpty
        return MusicTrack(id: id, title: title, audioURL: audioURL, description: description, timestamp: timestamp, price: price, isPremium: isPremium, imageURL: imageURL)
    }
}

// MARK: - Card

struct MusicTrackCard: View {
    let track: MusicTrack
    let hasPurchased: Bool
    let brand: BrandModel

    @State private var audioPlayer: AVPlayer?
    @State private var isPlaying = false
    @State private var isSaved = false
    @State private var showShareSheet = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(track.title)
                    .font(.headline)
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

            Text(track.description)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(3)

            if track.isPremium && !hasPurchased {
                Button {
                    // require login like your original flow; remove this guard for guest checkout
                    guard let uid = Auth.auth().currentUser?.uid else { return }
                    let url = Checkout.url(
                        tool: "music",
                        brandId: brand.id,
                        itemId: track.id,
                        title: track.title,
                        price: track.price,
                        currency: "USD",
                        imagePath: track.imageURL,
                        userId: uid,
                        allowQty: false,
                        minQty: 1,
                        maxQty: 1,
                        returnUrl: "blackappios://done"
                        // clientTokenUrl: "https://blackapp.io/api/client_token",
                        // chargeUrl: "https://blackapp.io/api/charge_braintree"
                    )
                    if let url { openURL(url) }
                } label: {
                    Label("Buy to Listen - $\(String(format: "%.2f", track.price))", systemImage: "cart.fill")
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            } else {
                Button(action: togglePlayPause) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8)
        .onAppear {
            loadPlayer()
            checkSavedStatus()
        }
        .sheet(isPresented: $showShareSheet) {
            MusicShareSheet(activityItems: [URL(string: track.audioURL) as Any, "🎶 \(track.title) on BlackApp"])
        }
    }

    // MARK: - Helpers

    func loadPlayer() {
        guard let url = URL(string: track.audioURL) else { return }
        audioPlayer = AVPlayer(url: url)
    }

    func togglePlayPause() {
        guard let p = audioPlayer else { return }
        isPlaying ? p.pause() : p.play()
        isPlaying.toggle()
    }

    func toggleSave() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedMusic").child(uid).child(track.id)
        if isSaved { ref.removeValue() } else { ref.setValue(true) }
        isSaved.toggle()
    }

    func checkSavedStatus() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedMusic").child(uid).child(track.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            isSaved = snapshot.exists()
        }
    }
}

// unique share wrapper to avoid duplicate type names across files
struct MusicShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// tiny helper
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
