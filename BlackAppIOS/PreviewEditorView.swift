import SwiftUI
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct PreviewEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: CapturePayload

    // Photo filtering (very light)
    @State private var selectedFilter: String = "None"
    private let photoFilters = ["None", "Noir", "Chrome", "Instant"]

    @State private var processedImage: UIImage?
    private let ciContext = CIContext()

    // Share
    @State private var showShare = false

    var body: some View {
        NavigationView {
            content
                .navigationTitle(payload.kind == .photo ? "Photo" : "Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button("Share") { showShare = true }
                        Button("Post") { post() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .sheet(isPresented: $showShare) {
            MediaShareSheet(items: shareItems())
        }
        .onAppear {
            if payload.kind == .photo {
                processedImage = payload.image
            }
        }
    }

    // MARK: Content
    @ViewBuilder private var content: some View {
        if payload.kind == .photo, let base = payload.image {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let img = processedImage ?? base
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: w, height: w * img.size.height / max(1, img.size.width))
                        .clipped()
                        .cornerRadius(16)
                }
                .frame(height: 380)

                // Optional tiny filter picker
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(photoFilters, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selectedFilter) { _ in applyFilter() }

                Spacer()
            }
            .padding()
        } else if payload.kind == .video, let url = payload.url {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea(edges: .bottom)
                .onDisappear { /* player will deinit */ }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing media…")
            }
            .padding()
        }
    }

    // MARK: Actions
    private func shareItems() -> [Any] {
        switch payload.kind {
        case .photo:
            return [processedImage ?? payload.image as Any].compactMap { $0 }
        case .video:
            return [payload.url as Any].compactMap { $0 }
        }
    }

    private func post() {
        // Build final data (apply chosen photo filter; videos pass the URL through)
        var info: [String: Any] = [
            "type": payload.kind.rawValue
        ]
        if payload.kind == .photo {
            let img = processedImage ?? payload.image
            if let img { info["image"] = img }
            info["filter"] = (selectedFilter == "None") ? nil : selectedFilter
        } else {
            if let url = payload.url { info["mediaURL"] = url }
            info["filter"] = nil
        }

        // Hand off to your existing Gossip uploader/composer
        NotificationCenter.default.post(name: .gossipEditorReadyToPost, object: nil, userInfo: info)

        dismiss()
    }

    private func applyFilter() {
        guard let base = payload.image else { return }
        switch selectedFilter {
        case "None":
            processedImage = base
        case "Noir":
            processedImage = applyCI(name: "CIPhotoEffectNoir", to: base)
        case "Chrome":
            processedImage = applyCI(name: "CIPhotoEffectChrome", to: base)
        case "Instant":
            processedImage = applyCI(name: "CIPhotoEffectInstant", to: base)
        default:
            processedImage = base
        }
    }

    private func applyCI(name: String, to image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: name) else { return image }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage,
              let cgOut = ciContext.createCGImage(out, from: out.extent)
        else { return image }
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
    }
}

// Simple UIActivityViewController wrapper (avoid name clash with your other share sheet)
struct MediaShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
