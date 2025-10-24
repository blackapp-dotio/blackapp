import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Picked Media Model

public struct PickedMedia: Identifiable, Equatable {
    public enum Kind: Equatable {
        case image(UIImage)                // full-resolution UIImage
        case video(URL, duration: Double?) // temp file URL + duration (sec)
    }

    public let id = UUID()
    public let kind: Kind
    public let originalFilename: String?
    public let uniformType: UTType?
}

// MARK: - ImagePicker (Instagram-style, multi-select, backward-compatible)

struct ImagePicker: UIViewControllerRepresentable {
    // ===== Backwards-compatible bindings (single selection) =====
    @Binding var selectedImage: UIImage?
    @Binding var selectedVideoURL: URL?
    @Binding var selectedMediaType: MediaType?

    // ===== New: batch selection =====
    @Binding var selectedItems: [PickedMedia]

    // ===== Config =====
    var selectionLimit: Int = 10                 // 1 = single, 0 = unlimited
    var allowImages: Bool = true
    var allowVideos: Bool = true
    var preferCurrentRepresentation = true       // .current vs .compatible
    var preProcessImage: ((UIImage) -> UIImage)? // optional post-process (e.g., applyFilter)

    enum MediaType { case image, video }

    // MARK: Initializers

    /// Legacy initializer (keeps old call sites compiling).
    init(selectedImage: Binding<UIImage?>,
         selectedVideoURL: Binding<URL?> = .constant(nil),
         selectedMediaType: Binding<MediaType?> = .constant(nil)) {
        self._selectedImage = selectedImage
        self._selectedVideoURL = selectedVideoURL
        self._selectedMediaType = selectedMediaType
        self._selectedItems = .constant([])
    }

    /// New initializer for multi-select.
    init(selectedItems: Binding<[PickedMedia]>,
         selectionLimit: Int = 10,
         allowImages: Bool = true,
         allowVideos: Bool = true,
         preferCurrentRepresentation: Bool = true,
         preProcessImage: ((UIImage) -> UIImage)? = nil,
         // still allow legacy outputs if caller wants the "first" item mirrored
         selectedImage: Binding<UIImage?> = .constant(nil),
         selectedVideoURL: Binding<URL?> = .constant(nil),
         selectedMediaType: Binding<MediaType?> = .constant(nil)) {
        self._selectedItems = selectedItems
        self.selectionLimit = selectionLimit
        self.allowImages = allowImages
        self.allowVideos = allowVideos
        self.preferCurrentRepresentation = preferCurrentRepresentation
        self.preProcessImage = preProcessImage
        self._selectedImage = selectedImage
        self._selectedVideoURL = selectedVideoURL
        self._selectedMediaType = selectedMediaType
    }

    // MARK: UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        var filters: [PHPickerFilter] = []
        if allowImages { filters.append(.images) }
        if allowVideos { filters.append(.videos) }
        config.filter = .any(of: filters.isEmpty ? [.images, .videos] : filters)
        config.preferredAssetRepresentationMode = preferCurrentRepresentation ? .current : .compatible
        config.selection = .ordered // keep user’s pick order (iOS 17+; harmless earlier)

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Coordinator

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            // Reset legacy outputs
            parent.selectedImage = nil
            parent.selectedVideoURL = nil
            parent.selectedMediaType = nil

            guard !results.isEmpty else {
                DispatchQueue.main.async { self.parent.selectedItems = [] }
                return
            }

            // We’ll fill this in the same order as `results`
            var ordered: [PickedMedia?] = Array(repeating: nil, count: results.count)

            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider

                // Prefer video first if available
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {

                    group.enter()
                    loadVideo(provider: provider) { media in
                        ordered[index] = media
                        group.leave()
                    }
                    continue
                }

                // Otherwise, try image
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    loadImage(provider: provider, preProcess: parent.preProcessImage) { media in
                        ordered[index] = media
                        group.leave()
                    }
                    continue
                }

                // Unsupported item → leave as nil (will be filtered)
            }

            group.notify(queue: .main) {
                let items: [PickedMedia] = ordered.compactMap { $0 }
                self.parent.selectedItems = items

                // Mirror first item to legacy outputs for backwards compatibility
                if let first = items.first {
                    switch first.kind {
                    case .image(let img):
                        self.parent.selectedImage = img
                        self.parent.selectedMediaType = .image
                    case .video(let url, _):
                        self.parent.selectedVideoURL = url
                        self.parent.selectedMediaType = .video
                    }
                }
            }
        }

        // MARK: Loaders

        private func loadVideo(provider: NSItemProvider,
                               completion: @escaping (PickedMedia?) -> Void) {
            // Prefer .movie
            let typeId = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                ? UTType.movie.identifier
                : UTType.video.identifier

            // We want a stable local copy (the provided URL can be ephemeral)
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
                if let error = error {
                    print("🎥 Video load error:", error)
                    completion(nil)
                    return
                }
                guard let srcURL = url else {
                    completion(nil); return
                }

                // Build a safe temp destination with extension
                let ext = srcURL.pathExtension.isEmpty ? "mov" : srcURL.pathExtension
                let destURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)

                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: srcURL, to: destURL)

                    // Probe duration (non-fatal)
                    var duration: Double? = nil
                    let asset = AVAsset(url: destURL)
                    let secs = CMTimeGetSeconds(asset.duration)
                    if secs.isFinite { duration = secs }

                    // Extract filename and UTI if possible
                    let name = provider.suggestedName
                    let ut = (try? UTType(filenameExtension: ext)) ?? .movie

                    completion(PickedMedia(kind: .video(destURL, duration: duration),
                                           originalFilename: name,
                                           uniformType: ut))
                } catch {
                    print("🎥 Temp copy error:", error)
                    completion(nil)
                }
            }
        }

        private func loadImage(provider: NSItemProvider,
                               preProcess: ((UIImage) -> UIImage)?,
                               completion: @escaping (PickedMedia?) -> Void) {
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error = error {
                    print("🖼️ Image load error:", error)
                    completion(nil)
                    return
                }
                guard var image = object as? UIImage else {
                    completion(nil); return
                }

                // Optional post-process (e.g., apply LCFilterKind outside the picker)
                if let fx = preProcess {
                    image = fx(image)
                }

                // Try to infer filename / type
                let name = provider.suggestedName
                let ut: UTType? = {
                    if provider.hasItemConformingToTypeIdentifier(UTType.heic.identifier) { return .heic }
                    if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) { return .jpeg }
                    if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)  { return .png }
                    return nil
                }()

                completion(PickedMedia(kind: .image(image),
                                       originalFilename: name,
                                       uniformType: ut))
            }
        }
    }
}
