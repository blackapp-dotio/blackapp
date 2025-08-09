import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth
import AVKit

struct BrandVlogFeedView: View {
    var brand: BrandModel
    @State private var vlogs: [VlogVideo] = []
    @State private var isLoading = true
    @State private var savedVlogIds: Set<String> = []
    @State private var purchasedVlogIds: Set<String> = []
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ForEach(vlogs) { vlog in
                    VlogVideoCard(
                        vlog: vlog,
                        isSaved: savedVlogIds.contains(vlog.id),
                        hasPurchased: purchasedVlogIds.contains(vlog.id),
                        onSaveToggle: { toggleSave(for: vlog) },
                        onShare: { share(vlog: vlog) },
                        onPurchase: {
                            guard let uid = Auth.auth().currentUser?.uid else { return }
                            PurchaseManager.shared.startCheckout(
                                buyerId: uid,
                                sellerId: brand.ownerId,
                                basePrice: vlog.price,
                                itemType: "vlog",
                                itemId: vlog.id,
                                itemTitle: vlog.title,
                                itemImageURL: nil
                            )
                        }
                    )
                    .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding()
                } else if vlogs.isEmpty {
                    Text("No vlogs uploaded yet.")
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
        .navigationTitle("\(brand.name) Vlogs")
        .onAppear {
            fetchVlogs()
            fetchSavedVlogs()
            fetchPurchasedVlogs()
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                VlogShareSheet(activityItems: [url, "🎬 Watch on BlackApp"])
            }
        }
    }

    // MARK: - Fetchers with fallbacks

    func fetchVlogs() {
        let p1 = Database.database().reference().child("brands").child(brand.id).child("vlogs")
        let p2 = Database.database().reference().child("brandVlogs").child(brand.id)

        func read(_ ref: DatabaseReference, label: String, onEmpty: @escaping () -> Void) {
            print("🎬 Trying vlog path: \(label)")
            ref.observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists() else { print("⚠️ No data at \(label)"); onEmpty(); return }
                var tmp: [VlogVideo] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let dict = child.value as? [String: Any],
                       let vlog = VlogVideo.from(dict: dict, id: child.key) {
                        tmp.append(vlog)
                    }
                }
                self.vlogs = tmp.sorted(by: { $0.timestamp > $1.timestamp })
                self.isLoading = false
                print("✅ Loaded \(tmp.count) vlogs from \(label)")
            }
        }

        read(p1, label: "brands/\(brand.id)/vlogs") {
            read(p2, label: "brandVlogs/\(brand.id)") {
                self.vlogs = []
                self.isLoading = false
                print("🚫 No vlogs found in any known path.")
            }
        }
    }

    func fetchSavedVlogs() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedVlogs").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            var saved = Set<String>()
            for child in snapshot.children {
                if let snap = child as? DataSnapshot { saved.insert(snap.key) }
            }
            self.savedVlogIds = saved
        }
    }

    func fetchPurchasedVlogs() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(uid)
        ref.observeSingleEvent(of: .value) { snapshot in
            var ids = Set<String>()
            for case let child as DataSnapshot in snapshot.children {
                if let val = child.value as? [String: Any],
                   val["type"] as? String == "vlog" {
                    ids.insert(child.key)
                }
            }
            self.purchasedVlogIds = ids
        }
    }

    // MARK: - Actions

    func toggleSave(for vlog: VlogVideo) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedVlogs").child(uid).child(vlog.id)
        if savedVlogIds.contains(vlog.id) {
            ref.removeValue()
            savedVlogIds.remove(vlog.id)
        } else {
            ref.setValue(true)
            savedVlogIds.insert(vlog.id)
        }
    }

    func share(vlog: VlogVideo) {
        // Share a public deep link for the vlog (replace with your hosted page when ready)
        if let url = URL(string: "https://blackappios.web.app/vlog.html?vlogId=\(vlog.id)") {
            shareURL = url
            showShareSheet = true
        }
    }
}

// MARK: - Model

struct VlogVideo: Identifiable {
    var id: String
    var title: String
    var videoURL: String
    var description: String
    var timestamp: TimeInterval
    var price: Double
    var isPremium: Bool

    static func from(dict: [String: Any], id: String) -> VlogVideo? {
        guard let title = dict["title"] as? String,
              let videoURL = dict["videoURL"] as? String,
              let description = dict["description"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        let price = dict["price"] as? Double ?? 0.0
        let isPremium = dict["isPremium"] as? Bool ?? false
        return VlogVideo(id: id, title: title, videoURL: videoURL, description: description, timestamp: timestamp, price: price, isPremium: isPremium)
    }
}

// MARK: - Card

struct VlogVideoCard: View {
    let vlog: VlogVideo
    var isSaved: Bool
    var hasPurchased: Bool
    var onSaveToggle: () -> Void
    var onShare: () -> Void
    var onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vlog.title)
                .font(.headline)
                .foregroundColor(.white)

            if vlog.isPremium && !hasPurchased {
                Button(action: onPurchase) {
                    Label("Buy to Watch - $\(String(format: "%.2f", vlog.price))", systemImage: "cart.fill")
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            } else if let url = URL(string: vlog.videoURL) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 220)
                    .cornerRadius(16)
                    .shadow(radius: 5)
            }

            Text(vlog.description)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(4)

            HStack {
                Button(action: onSaveToggle) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundColor(isSaved ? .red : .white)
                }
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8)
    }
}

// unique share wrapper
struct VlogShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
