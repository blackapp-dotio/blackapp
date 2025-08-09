import SwiftUI
import PhotosUI
import Firebase
import FirebaseDatabase
import FirebaseStorage
import UniformTypeIdentifiers
import UIKit

struct BrandMusicConfigView: View {
    var brand: BrandModel

    // Form state
    @State private var title = ""
    @State private var description = ""
    @State private var priceText = ""
    @State private var isPremium = false
    @State private var releaseDate = Date()

    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?

    @State private var audioFileURL: URL?
    @State private var showAudioPicker = false

    // UX state
    @State private var isUploading = false
    @State private var uploadMessage: String?
    @State private var tracks: [BrandMusicTrack] = []
    @State private var isLoadingList = true
    @State private var editingTrackId: String? = nil

    private var isEditing: Bool { editingTrackId != nil }
    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        audioFileURL != nil &&
        (Double(priceText) != nil || priceText.isEmpty) // allow 0 when empty if not premium
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {

                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Music Track" : "Upload Music")
                        .font(.title2).bold().foregroundColor(.white)
                    if let id = editingTrackId {
                        Text("Editing: \(id)")
                            .font(.footnote).foregroundColor(.white.opacity(0.6))
                    }
                }

                // Form
                Group {
                    TextField("Track Title", text: $title)
                    TextField("Description", text: $description)

                    Toggle("Premium (requires purchase)", isOn: $isPremium)
                        .foregroundColor(.white)

                    HStack {
                        TextField("Price (e.g. 4.99)", text: $priceText)
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
                    Button {
                        showAudioPicker = true
                    } label: {
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
                    AudioPicker { url in
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
                    Button(isEditing ? "Save Changes" : "Upload Music") {
                        Task { await saveOrUpdateTrack() }
                    }
                    .disabled(isUploading || !isFormValid || (isPremium && Double(priceText) == nil))
                    .padding()
                    .background(isEditing ? Color.orange : Color.blue)
                    .cornerRadius(10)
                    .foregroundColor(.white)

                    if isEditing {
                        Button("Cancel") {
                            clearForm()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)

                // Existing tracks
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Tracks", systemImage: "music.note.list")
                            .foregroundColor(.white)
                            .font(.headline)
                        Spacer()
                        Button { fetchTracks() } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                    }

                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if tracks.isEmpty {
                        Text("No tracks yet.").foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(tracks, id: \.id) { t in
                            BrandMusicRow(
                                track: t,
                                onEdit: { loadForEdit(t) },
                                onDelete: { deleteTrack(t) }
                            )
                        }
                    }
                }
                .glassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchTracks() }
        .onChange(of: imageItem) { _ in
            Task {
                if let data = try? await imageItem?.loadTransferable(type: Data.self) {
                    imageData = data
                }
            }
        }
        .navigationTitle("Music")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Save / Update
    private func saveOrUpdateTrack() async {
        guard let audioURL = audioFileURL else {
            uploadMessage = "Please select an audio file."
            return
        }
        if isPremium && Double(priceText) == nil {
            uploadMessage = "Enter a valid price for premium content."
            return
        }

        isUploading = true
        uploadMessage = nil

        let trackId = editingTrackId ?? UUID().uuidString
        let storage = Storage.storage().reference()
        let audioRef = storage.child("brandMusic/\(brand.id)/\(trackId).m4a")
        let imageRef = storage.child("brandMusicCovers/\(brand.id)/\(trackId).jpg")

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

            let musicData: [String: Any] = [
                "id": trackId,
                "title": title,
                "description": description,
                "price": price,
                "isPremium": isPremium,
                "releaseDate": releaseDate.timeIntervalSince1970,
                "imageURL": imageDLString,
                "audioURL": audioDL.absoluteString,
                "timestamp": now
            ]

            let dbRef = Database.database().reference()
            try await dbRef.child("brands/\(brand.id)/music/\(trackId)").setValue(musicData)
            // ensure tool shows up
            try await dbRef.child("brands/\(brand.id)/toolsEnabled/music").setValue(true)

            uploadMessage = isEditing ? "✅ Track updated!" : "✅ Music uploaded successfully!"
            fetchTracks()
            clearForm()
        } catch {
            uploadMessage = "❌ Upload failed: \(error.localizedDescription)"
        }

        isUploading = false
    }

    // MARK: - Fetch list
    private func fetchTracks() {
        isLoadingList = true
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("music")

        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandMusicTrack] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let t = BrandMusicTrack.from(dict: dict, id: child.key) {
                    temp.append(t)
                }
            }
            self.tracks = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoadingList = false
        }
    }

    // MARK: - Edit
    private func loadForEdit(_ t: BrandMusicTrack) {
        editingTrackId = t.id
        title = t.title
        description = t.description
        priceText = t.price > 0 ? String(format: "%.2f", t.price) : ""
        isPremium = t.isPremium
        releaseDate = Date(timeIntervalSince1970: t.releaseDate)
        uploadMessage = nil
    }

    // MARK: - Delete
    private func deleteTrack(_ t: BrandMusicTrack) {
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("music")
            .child(t.id)

        ref.removeValue { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                tracks.removeAll { $0.id == t.id }
                if editingTrackId == t.id { clearForm() }
            }
        }

        // Optionally delete storage files too
        let storage = Storage.storage().reference()
        storage.child("brandMusic/\(brand.id)/\(t.id).m4a").delete(completion: nil)
        storage.child("brandMusicCovers/\(brand.id)/\(t.id).jpg").delete(completion: nil)
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
        editingTrackId = nil
    }
}

// MARK: - Model (unique name to avoid collisions)
struct BrandMusicTrack: Identifiable {
    let id: String
    let title: String
    let description: String
    let price: Double
    let isPremium: Bool
    let releaseDate: TimeInterval
    let imageURL: String
    let audioURL: String
    let timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> BrandMusicTrack? {
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
        return BrandMusicTrack(
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
private struct BrandMusicRow: View {
    let track: BrandMusicTrack
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title).font(.headline).foregroundColor(.white)
                Text(track.description).font(.subheadline).foregroundColor(.white.opacity(0.8)).lineLimit(2)
                HStack(spacing: 12) {
                    if track.isPremium {
                        Text("$\(track.price, specifier: "%.2f")").foregroundColor(.green)
                    } else {
                        Text("Free").foregroundColor(.white.opacity(0.7))
                    }
                    Text(Self.formatDate(track.releaseDate)).foregroundColor(.white.opacity(0.6))
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

// MARK: - Local glass helper
private extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        self.padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Audio Picker
struct AudioPicker: UIViewControllerRepresentable {
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
