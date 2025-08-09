import SwiftUI
import PhotosUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import UniformTypeIdentifiers
import UIKit

struct BrandPodcastConfigView: View {
    var brand: BrandModel

    // Form
    @State private var title = ""
    @State private var description = ""
    @State private var isPremium = false
    @State private var priceText = ""
    @State private var releaseDate = Date()
    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var audioFileURL: URL?

    // UX
    @State private var isUploading = false
    @State private var uploadMessage: String?
    @State private var showAudioPicker = false
    @State private var episodes: [BrandPodcastEpisode] = []
    @State private var isLoadingList = true
    @State private var editingEpisodeId: String? = nil

    private var isEditing: Bool { editingEpisodeId != nil }
    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        audioFileURL != nil &&
        (Double(priceText) != nil || !isPremium) // require price only if premium
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Podcast Episode" : "Upload Podcast Episode")
                        .font(.title2).bold().foregroundColor(.white)
                    if let id = editingEpisodeId {
                        Text("Editing: \(id)")
                            .font(.footnote).foregroundColor(.white.opacity(0.6))
                    }
                }

                // Form
                Group {
                    TextField("Episode Title", text: $title)
                    TextField("Description", text: $description)

                    Toggle("Premium (requires purchase)", isOn: $isPremium)
                        .foregroundColor(.white)

                    HStack {
                        TextField("Price (e.g. 3.99)", text: $priceText)
                            .keyboardType(.decimalPad)
                        Text(isPremium ? "" : "(optional)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    DatePicker("Release Date", selection: $releaseDate, displayedComponents: .date)
                        .foregroundColor(.white)
                }
                .textFieldStyle(.roundedBorder)

                // Image picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cover Image (optional)").foregroundColor(.white)
                    PhotosPicker(selection: $imageItem, matching: .images) {
                        Text(imageData == nil ? "Select Image" : "Change Image")
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    if let imageData, let img = UIImage(data: imageData) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                            .cornerRadius(10)
                    }
                }

                // Audio picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio File (MP3/M4A)").foregroundColor(.white)
                    Button { showAudioPicker = true } label: {
                        Text(audioFileURL == nil ? "Select Audio" : "Change Audio")
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    if let url = audioFileURL {
                        Text("Selected: \(url.lastPathComponent)")
                            .foregroundColor(.green)
                            .font(.footnote)
                            .lineLimit(1)
                    }
                }
                .sheet(isPresented: $showAudioPicker) {
                    PodcastAudioPicker { url in
                        audioFileURL = url
                    }
                }

                if isUploading {
                    ProgressView(isEditing ? "Saving changes..." : "Uploading...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                if let msg = uploadMessage {
                    Text(msg).foregroundColor(.yellow)
                }

                HStack(spacing: 12) {
                    Button(isEditing ? "Save Changes" : "Upload Episode") {
                        Task { await saveOrUpdateEpisode() }
                    }
                    .disabled(isUploading || !isFormValid)
                    .padding()
                    .background(isEditing ? Color.orange : Color.blue)
                    .cornerRadius(10)
                    .foregroundColor(.white)

                    if isEditing {
                        Button("Cancel") { clearForm() }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }

                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)

                // Existing episodes
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Episodes", systemImage: "mic.fill")
                            .foregroundColor(.white)
                            .font(.headline)
                        Spacer()
                        Button { fetchEpisodes() } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                    }

                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if episodes.isEmpty {
                        Text("No episodes yet.").foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(episodes, id: \.id) { e in
                            BrandPodcastRow(
                                episode: e,
                                onEdit: { loadForEdit(e) },
                                onDelete: { deleteEpisode(e) }
                            )
                        }
                    }
                }
                .podcastGlassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchEpisodes() }
        .onChange(of: imageItem) { _ in
            Task {
                if let data = try? await imageItem?.loadTransferable(type: Data.self) {
                    imageData = data
                }
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Save / Update
    private func saveOrUpdateEpisode() async {
        guard let audioURL = audioFileURL else {
            uploadMessage = "Please select an audio file."
            return
        }
        if isPremium && Double(priceText) == nil {
            uploadMessage = "Enter a valid price for premium episodes."
            return
        }

        isUploading = true
        uploadMessage = nil

        let episodeId = editingEpisodeId ?? UUID().uuidString
        let storage = Storage.storage().reference()
        let audioRef = storage.child("brandPodcasts/\(brand.id)/\(episodeId).m4a")
        let imageRef = storage.child("brandPodcastCovers/\(brand.id)/\(episodeId).jpg")

        do {
            // Upload audio
            let audioData = try Data(contentsOf: audioURL)
            _ = try await audioRef.putDataAsync(audioData)
            let audioDL = try await audioRef.downloadURL()

            // Upload image if present
            var imageDLString = ""
            if let imageData {
                _ = try await imageRef.putDataAsync(imageData)
                imageDLString = try await imageRef.downloadURL().absoluteString
            }

            let price = Double(priceText) ?? 0.0
            let now = Date().timeIntervalSince1970

            let episodeData: [String: Any] = [
                "id": episodeId,
                "title": title,
                "description": description,
                "price": price,
                "isPremium": isPremium,
                "releaseDate": releaseDate.timeIntervalSince1970,
                "imageURL": imageDLString,
                "audioURL": audioDL.absoluteString,
                "timestamp": now
            ]

            let db = Database.database().reference()
            try await db.child("brands/\(brand.id)/podcasts/\(episodeId)").setValue(episodeData)
            try await db.child("brands/\(brand.id)/toolsEnabled/podcasts").setValue(true)

            uploadMessage = isEditing ? "✅ Episode updated!" : "✅ Episode uploaded!"
            fetchEpisodes()
            clearForm()
        } catch {
            uploadMessage = "❌ Upload failed: \(error.localizedDescription)"
        }

        isUploading = false
    }

    // MARK: - Fetch list
    private func fetchEpisodes() {
        isLoadingList = true
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("podcasts")

        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandPodcastEpisode] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let ep = BrandPodcastEpisode.from(dict: dict, id: child.key) {
                    temp.append(ep)
                }
            }
            self.episodes = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoadingList = false
        }
    }

    // MARK: - Edit
    private func loadForEdit(_ e: BrandPodcastEpisode) {
        editingEpisodeId = e.id
        title = e.title
        description = e.description
        priceText = e.price > 0 ? String(format: "%.2f", e.price) : ""
        isPremium = e.isPremium
        releaseDate = Date(timeIntervalSince1970: e.releaseDate)
        uploadMessage = nil
        // Keep existing image/audio unless user picks new ones
    }

    // MARK: - Delete
    private func deleteEpisode(_ e: BrandPodcastEpisode) {
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("podcasts")
            .child(e.id)

        ref.removeValue { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                episodes.removeAll { $0.id == e.id }
                if editingEpisodeId == e.id { clearForm() }
            }
        }

        // Optionally delete storage files
        let storage = Storage.storage().reference()
        storage.child("brandPodcasts/\(brand.id)/\(e.id).m4a").delete(completion: nil)
        storage.child("brandPodcastCovers/\(brand.id)/\(e.id).jpg").delete(completion: nil)
    }

    // MARK: - Reset
    private func clearForm() {
        title = ""
        description = ""
        priceText = ""
        isPremium = false
        releaseDate = Date()
        imageItem = nil
        imageData = nil
        audioFileURL = nil
        editingEpisodeId = nil
    }
}

// MARK: - Model (unique type name to avoid collisions)
struct BrandPodcastEpisode: Identifiable {
    let id: String
    let title: String
    let description: String
    let price: Double
    let isPremium: Bool
    let releaseDate: TimeInterval
    let imageURL: String
    let audioURL: String
    let timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> BrandPodcastEpisode? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let price = dict["price"] as? Double,
              let isPremium = dict["isPremium"] as? Bool,
              let releaseDate = dict["releaseDate"] as? TimeInterval,
              let imageURL = dict["imageURL"] as? String,
              let audioURL = dict["audioURL"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        return BrandPodcastEpisode(
            id: id,
            title: title,
            description: description,
            price: price,
            isPremium: isPremium,
            releaseDate: releaseDate,
            imageURL: imageURL,
            audioURL: audioURL,
            timestamp: timestamp
        )
    }
}

// MARK: - Row
private struct BrandPodcastRow: View {
    let episode: BrandPodcastEpisode
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.title).font(.headline).foregroundColor(.white)
                Text(episode.description).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(2)
                HStack(spacing: 12) {
                    if episode.isPremium {
                        Text("$\(episode.price, specifier: "%.2f")").foregroundColor(.green)
                    } else {
                        Text("Free").foregroundColor(.white.opacity(0.7))
                    }
                    Text(Self.formatDate(episode.releaseDate)).foregroundColor(.white.opacity(0.6))
                }
                .font(.footnote)
            }
            Spacer()
            VStack(spacing: 8) {
                Button(action: onEdit) { Image(systemName: "pencil").foregroundColor(.yellow) }
                Button(action: onDelete) { Image(systemName: "trash").foregroundColor(.red) }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    static func formatDate(_ ts: TimeInterval) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - Local “glass” helper (unique)
private extension View {
    func podcastGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Audio Picker (unique name to avoid collisions)
struct PodcastAudioPicker: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio])
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}
