import SwiftUI
import FirebaseStorage
import AVKit
import AVFoundation

// MARK: - Dynamic Storage Image (Firebase Storage path)
struct FittedStorageImageView: View {
    let storagePath: String
    let cornerRadius: CGFloat

    @State private var uiImage: UIImage?
    @State private var isLoading = false

    init(storagePath: String, cornerRadius: CGFloat = 12) {
        self.storagePath = storagePath
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()                    // ✅ dynamic fit (no crop)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(cornerRadius)
            } else if isLoading {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.15))
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(ProgressView())
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.15))
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(Image(systemName: "photo").font(.title2).foregroundColor(.gray))
            }
        }
        .onAppear(perform: fetchImage)
    }

    private func fetchImage() {
        guard uiImage == nil, !isLoading else { return }
        isLoading = true
        let ref = Storage.storage().reference(withPath: storagePath)
        ref.downloadURL { url, error in
            guard let url = url, error == nil else {
                isLoading = false
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    if let data = data, let img = UIImage(data: data) {
                        self.uiImage = img
                    }
                    self.isLoading = false
                }
            }.resume()
        }
    }
}

// MARK: - Dynamic AsyncImage (URL)
struct DynamicAsyncImageView: View {
    let url: URL
    let cornerRadius: CGFloat

    init(url: URL, cornerRadius: CGFloat = 12) {
        self.url = url
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.15))
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(ProgressView())

            case .success(let image):
                image.resizable()
                    .scaledToFit()                    // ✅ dynamic fit (no crop)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(cornerRadius)

            case .failure(_):
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.2))
                    .frame(maxWidth: .infinity, minHeight: 120)

            @unknown default:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.2))
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}

// MARK: - Dynamic Video (auto height based on natural aspect)
struct DynamicVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var aspect: CGFloat? = nil   // width / height

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspect ?? (16.0/9.0), contentMode: .fit) // ✅ fit, height grows
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity) // width stretches, height follows aspect
        .onAppear {
            let p = AVPlayer(url: url)
            self.player = p
            loadAspect(from: url)
        }
    }

    private func loadAspect(from url: URL) {
        let asset = AVAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            let tracks = asset.tracks(withMediaType: .video)
            guard let t = tracks.first else { return }
            let raw = t.naturalSize.applying(t.preferredTransform)
            let w = abs(raw.width)
            let h = abs(raw.height)
            let a = (w > 0 && h > 0) ? (w / h) : (16.0 / 9.0)
            DispatchQueue.main.async { self.aspect = a }
        }
    }
}
