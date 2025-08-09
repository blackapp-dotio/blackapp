import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ImagePicker: UIViewControllerRepresentable {
    // Existing binding (still works)
    @Binding var selectedImage: UIImage?

    // New optional bindings (have defaults so old call sites still compile)
    @Binding var selectedVideoURL: URL?
    @Binding var selectedMediaType: MediaType?

    enum MediaType {
        case image
        case video
    }

    // Backwards-compatible initializer (old code can keep using this)
    init(selectedImage: Binding<UIImage?>,
         selectedVideoURL: Binding<URL?> = .constant(nil),
         selectedMediaType: Binding<MediaType?> = .constant(nil)) {
        self._selectedImage = selectedImage
        self._selectedVideoURL = selectedVideoURL
        self._selectedMediaType = selectedMediaType
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        // ✅ allow both images and videos
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            // Reset previous selections
            parent.selectedImage = nil
            parent.selectedVideoURL = nil
            parent.selectedMediaType = nil

            guard let provider = results.first?.itemProvider else { return }

            // Try video first
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ||
               provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {

                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    if let error = error {
                        print("🎥 Video load error:", error)
                        return
                    }
                    guard let url = url else { return }

                    // Copy to a stable temp URL (original may be ephemeral)
                    let tmpName = UUID().uuidString + ".mov"
                    let destURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tmpName)

                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.copyItem(at: url, to: destURL)
                        DispatchQueue.main.async {
                            self.parent.selectedVideoURL = destURL
                            self.parent.selectedMediaType = .video
                        }
                    } catch {
                        print("🎥 Failed to copy temp video:", error)
                    }
                }
                return
            }

            // Fallback: image
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let error = error {
                        print("🖼️ Image load error:", error)
                        return
                    }
                    guard let image = object as? UIImage else { return }
                    DispatchQueue.main.async {
                        self.parent.selectedImage = image
                        self.parent.selectedMediaType = .image
                    }
                }
            }
        }
    }
}
