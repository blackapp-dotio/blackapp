import SwiftUI
import Firebase
import FirebaseStorage
import FirebaseDatabase
import FirebaseAuth
import PhotosUI

struct BrandVlogConfigView: View {
    var brand: BrandModel

    // Form
    @State private var title = ""
    @State private var description = ""
    @State private var isMusicVideo = false
    @State private var isPremium = false
    @State private var price = ""

    @State private var videoItem: PhotosPickerItem?
    @State private var videoData: Data?
    @State private var thumbnailItem: PhotosPickerItem?
    @State private var thumbnailData: Data?

    // UX
    @State private var isUploading = false
    @State private var uploadMessage = ""

    // Manage existing
    @State private var vlogs: [VlogDoc] = []
    @State private var isLoadingList = true
    @State private var editingVlogId: String? = nil // nil = create

    private var isEditing: Bool { editingVlogId != nil }
    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!isPremium || Double(price) != nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Vlog" : "Upload New Vlog")
                        .font(.title2).bold()
                        .foregroundColor(.white)
                    if let id = editingVlogId {
                        Text("Editing: \(id)").font(.footnote).foregroundColor(.white.opacity(0.6))
                    }
                }

                // Form
                Group {
                    TextField("Vlog Title", text: $title)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Description", text: $description)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Toggle("Is this a music video?", isOn: $isMusicVideo)
                        .foregroundColor(.white)

                    Toggle("Premium (paid to watch)", isOn: $isPremium)
                        .foregroundColor(.white)

                    if isPremium {
                        TextField("Price (USD)", text: $price)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }

                // Thumbnail
                VStack(alignment: .leading, spacing: 8) {
                    Text("Thumbnail (Optional)").foregroundColor(.white)
                    PhotosPicker(selection: $thumbnailItem, matching: .images) {
                        Text(thumbnailData == nil ? "Select Image" : "Change Image")
                            .padding(.horizontal).padding(.vertical, 8)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    if let thumbnailData, let uiImage = UIImage(data: thumbnailData) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFit().frame(height: 100).cornerRadius(10)
                    }
                }

                // Video
                VStack(alignment: .leading, spacing: 8) {
                    Text("Video File (MP4, MOV)").foregroundColor(.white)
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Text(videoData == nil ? "Select Video" : "Change Video")
                            .padding(.horizontal).padding(.vertical, 8)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }
                    if let videoData {
                        Text("Video Ready: \(Double(videoData.count) / 1_000_000, specifier: "%.2f") MB")
                            .foregroundColor(.green)
                    } else if !isEditing {
                        Text("Select a video to upload").foregroundColor(.white.opacity(0.6))
                    }
                }

                if isUploading {
                    ProgressView(isEditing ? "Saving..." : "Uploading...")
                        .foregroundColor(.white)
                }

                HStack(spacing: 12) {
                    Button(isEditing ? "Save Changes" : "Upload & Save") {
                        uploadOrUpdateVlog()
                    }
                    .disabled(isUploading || !isFormValid || (!isEditing && videoData == nil))
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)

                    if isEditing {
                        Button("Cancel") { clearForm() }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }

                if !uploadMessage.isEmpty {
                    Text(uploadMessage).foregroundColor(.white).padding(.top, 4)
                }

                Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 8)

                // Existing vlogs
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Vlogs", systemImage: "film.fill")
                            .font(.headline).foregroundColor(.white)
                        Spacer()
                        Button { fetchVlogs() } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                    }

                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if vlogs.isEmpty {
                        Text("No vlogs yet.").foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(vlogs, id: \.id) { vlog in
                            VlogRow(
                                vlog: vlog,
                                onEdit: { loadForEdit(vlog) },
                                onDelete: { deleteVlog(vlog) }
                            )
                        }
                    }
                }
                .vlogGlassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchVlogs() }
        .onChange(of: videoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    self.videoData = data
                }
            }
        }
        .onChange(of: thumbnailItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    self.thumbnailData = data
                }
            }
        }
    }

    // MARK: - Create/Update
    private func uploadOrUpdateVlog() {
        guard let uid = Auth.auth().currentUser?.uid else {
            uploadMessage = "Missing user."
            return
        }

        isUploading = true
        uploadMessage = ""

        let vlogId = editingVlogId ?? UUID().uuidString
        let storageRef = Storage.storage().reference()

        // Uploads are conditional: only replace if user picked a new file.
        func uploadVideoIfNeeded(completion: @escaping (String?) -> Void) {
            guard let data = videoData else { completion(nil); return }
            let videoRef = storageRef.child("brandVlogs/\(brand.id)/\(vlogId).mp4")
            videoRef.putData(data, metadata: nil) { _, error in
                if let error = error {
                    uploadMessage = "Video upload failed: \(error.localizedDescription)"
                    isUploading = false
                    return
                }
                videoRef.downloadURL { url, _ in
                    completion(url?.absoluteString)
                }
            }
        }

        func uploadThumbIfNeeded(completion: @escaping (String?) -> Void) {
            guard let data = thumbnailData else { completion(nil); return }
            let thumbRef = storageRef.child("brandVlogs/\(brand.id)/\(vlogId)_thumb.jpg")
            thumbRef.putData(data, metadata: nil) { _, _ in
                thumbRef.downloadURL { url, _ in
                    completion(url?.absoluteString)
                }
            }
        }

        // Fetch current node if editing to preserve existing URLs
        let vlogRef = Database.database().reference().child("brands/\(brand.id)/vlogs/\(vlogId)")
        vlogRef.observeSingleEvent(of: .value) { snap in
            var currentVideoURL = (snap.value as? [String: Any])?["videoURL"] as? String ?? ""
            var currentThumbURL = (snap.value as? [String: Any])?["thumbnailURL"] as? String ?? ""

            let dispatch = DispatchGroup()

            var newVideoURL: String?
            var newThumbURL: String?

            dispatch.enter()
            uploadVideoIfNeeded { url in
                newVideoURL = url
                dispatch.leave()
            }

            dispatch.enter()
            uploadThumbIfNeeded { url in
                newThumbURL = url
                dispatch.leave()
            }

            dispatch.notify(queue: .main) {
                // Build write payload
                let ts = Date().timeIntervalSince1970
                let priceVal = Double(price) ?? 0.0

                var vlogData: [String: Any] = [
                    "id": vlogId,
                    "title": title,
                    "description": description,
                    "isMusicVideo": isMusicVideo,
                    "isPremium": isPremium,
                    "price": priceVal,
                    "timestamp": ts,
                    "uploaderId": uid
                ]

                // Keep existing URLs if not replaced
                vlogData["videoURL"] = newVideoURL ?? currentVideoURL
                vlogData["thumbnailURL"] = newThumbURL ?? currentThumbURL

                vlogRef.setValue(vlogData) { error, _ in
                    if let error = error {
                        uploadMessage = "Failed to save vlog: \(error.localizedDescription)"
                    } else {
                        let toolsRef = Database.database().reference().child("brands/\(brand.id)/toolsEnabled")
                        toolsRef.child("vlogs").setValue(true)
                        toolsRef.child("vlog").setValue(true) // be liberal: set both
                        uploadMessage = isEditing ? "✅ Vlog updated!" : "✅ Vlog uploaded!"
                        fetchVlogs()
                        clearForm()
                    }
                    isUploading = false
                }
            }
        }
    }

    // MARK: - Fetch list
    private func fetchVlogs() {
        isLoadingList = true
        let ref = Database.database().reference().child("brands").child(brand.id).child("vlogs")
        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [VlogDoc] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let item = VlogDoc.from(dict: dict, id: child.key) {
                    temp.append(item)
                }
            }
            self.vlogs = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoadingList = false
        }
    }

    // MARK: - Edit
    private func loadForEdit(_ item: VlogDoc) {
        editingVlogId = item.id
        title = item.title
        description = item.description
        isMusicVideo = item.isMusicVideo
        isPremium = item.isPremium
        price = item.price > 0 ? String(format: "%.2f", item.price) : ""
        videoItem = nil
        videoData = nil
        thumbnailItem = nil
        thumbnailData = nil
        uploadMessage = ""
    }

    // MARK: - Delete
    private func deleteVlog(_ item: VlogDoc) {
        let ref = Database.database().reference()
            .child("brands").child(brand.id).child("vlogs").child(item.id)

        ref.removeValue { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                vlogs.removeAll { $0.id == item.id }
                if editingVlogId == item.id { clearForm() }
            }
        }

        // Best-effort storage cleanup
        let storage = Storage.storage().reference()
        storage.child("brandVlogs/\(brand.id)/\(item.id).mp4").delete(completion: nil)
        storage.child("brandVlogs/\(brand.id)/\(item.id)_thumb.jpg").delete(completion: nil)
    }

    // MARK: - Reset
    private func clearForm() {
        title = ""
        description = ""
        isMusicVideo = false
        isPremium = false
        price = ""
        videoItem = nil
        videoData = nil
        thumbnailItem = nil
        thumbnailData = nil
        editingVlogId = nil
    }
}

// MARK: - Doc model (unique type)
struct VlogDoc: Identifiable {
    let id: String
    let title: String
    let description: String
    let videoURL: String
    let thumbnailURL: String
    let isMusicVideo: Bool
    let isPremium: Bool
    let price: Double
    let timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> VlogDoc? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let videoURL = dict["videoURL"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval
        else { return nil }

        let thumbnailURL = dict["thumbnailURL"] as? String ?? ""
        let isMusicVideo = dict["isMusicVideo"] as? Bool ?? false
        let isPremium = dict["isPremium"] as? Bool ?? false

        // Handle price safely (Double / NSNumber / String)
        let priceAny = dict["price"]
        let price: Double
        if let p = priceAny as? Double { price = p }
        else if let p = priceAny as? NSNumber { price = p.doubleValue }
        else if let p = priceAny as? String, let val = Double(p) { price = val }
        else { price = 0 }

        return VlogDoc(
            id: id,
            title: title,
            description: description,
            videoURL: videoURL,
            thumbnailURL: thumbnailURL,
            isMusicVideo: isMusicVideo,
            isPremium: isPremium,
            price: price,
            timestamp: timestamp
        )
    }
}

// MARK: - Row UI
private struct VlogRow: View {
    let vlog: VlogDoc
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(vlog.title).font(.headline).foregroundColor(.white)
                    if vlog.isPremium {
                        Text("$\(vlog.price, specifier: "%.2f")")
                            .font(.subheadline).foregroundColor(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.12)).cornerRadius(6)
                    }
                }
                Text(vlog.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if vlog.isMusicVideo {
                        Label("Music Video", systemImage: "music.note")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    Text(Self.formatDate(vlog.timestamp))
                        .font(.caption).foregroundColor(.white.opacity(0.6))
                }
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
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - Local glass helper
private extension View {
    func vlogGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
