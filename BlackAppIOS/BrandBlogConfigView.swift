import SwiftUI
import Firebase
import FirebaseStorage
import FirebaseDatabase
import PhotosUI
import FirebaseAuth

struct BrandBlogConfigView: View {
    var brand: BrandModel

    // Form fields
    @State private var title = ""
    @State private var bodyText = ""
    @State private var isPremium = false
    @State private var priceString = "" // keep as string for TextField, parse to Double
    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?

    // Edit state
    @State private var editingPost: BlogPost? = nil
    @State private var previousImageURL: String? = nil

    // UI state
    @State private var isUploading = false
    @State private var uploadMessage = ""
    @State private var posts: [BlogPost] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: - Header
                Text(editingPost == nil ? "Write a Blog Post" : "Edit Blog Post")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // MARK: - Form
                formSection

                // MARK: - Publish / Update Button
                Button(editingPost == nil ? "Publish Post" : "Save Changes") {
                    upsertBlogPost()
                }
                .disabled(isUploading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isPremium && (Double(priceString) ?? 0) <= 0))
                .padding()
                .background(isUploading ? Color.gray : Color.cyan)
                .foregroundColor(.white)
                .cornerRadius(10)

                if isUploading {
                    ProgressView("Uploading...")
                        .tint(.white)
                }

                if !uploadMessage.isEmpty {
                    Text(uploadMessage)
                        .foregroundColor(.white)
                        .padding(.top, 4)
                }

                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)

                // MARK: - Existing Posts (Manage)
                HStack {
                    Text("Your Posts")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    if isLoading {
                        ProgressView().tint(.white)
                    }
                }

                if posts.isEmpty && !isLoading {
                    Text("No posts yet. Publish your first blog above.")
                        .foregroundColor(.white.opacity(0.7))
                }

                VStack(spacing: 12) {
                    ForEach(posts) { post in
                        BlogManageRow(
                            post: post,
                            onEdit: { startEditing(post) },
                            onDelete: { deletePost(post) }
                        )
                    }
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: imageItem) { newItem in
            Task {
                guard let newItem else { return }
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    self.imageData = data
                }
            }
        }
        .onAppear {
            fetchPosts()
        }
        .toolbar {
            if editingPost != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel Edit") { clearForm() }
                }
            }
        }
    }

    // MARK: - Form Section
    private var formSection: some View {
        Group {
            TextField("Post Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Post Body")
                    .foregroundColor(.white)
                TextEditor(text: $bodyText)
                    .frame(height: 160)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.2))
                    )
            }

            Toggle("Premium post (paid)", isOn: $isPremium)
                .foregroundColor(.white)

            if isPremium {
                HStack {
                    Text("Price")
                        .foregroundColor(.white)
                    TextField("e.g., 2.99", text: $priceString)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(spacing: 8) {
                Text("Cover Image (Optional)")
                    .foregroundColor(.white)

                PhotosPicker(selection: $imageItem, matching: .images) {
                    Text("Select Image")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }

                if let imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 120)
                        .cornerRadius(10)
                } else if let prev = previousImageURL, !prev.isEmpty {
                    // show previously uploaded image when editing
                    AsyncImage(url: URL(string: prev)) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(height: 120)
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Create/Update
    private func upsertBlogPost() {
        isUploading = true
        uploadMessage = ""

        // Ensure user is allowed (owner or admin). Minimal guard here; your rules also restrict.
        if let uid = Auth.auth().currentUser?.uid, uid != brand.ownerId {
            print("⚠️ Non-owner attempting to write. UID: \(uid) ≠ brand.ownerId: \(brand.ownerId)")
        }

        let postId = editingPost?.id ?? UUID().uuidString
        let ref = Database.database().reference()
        let timestamp = Date().timeIntervalSince1970

        func finishSave(imageURL: String) {
            let price = Double(priceString) ?? 0
            let post: [String: Any] = [
                "id": postId,
                "title": title,
                "body": bodyText,                          // 🔑 matches your DB: "body"
                "imageURL": imageURL,
                "timestamp": timestamp,
                "isPremium": isPremium,
                "price": price
            ]

            let path = "brands/\(brand.id)/blog/\(postId)"
            ref.child(path).setValue(post) { error, _ in
                if let error = error {
                    uploadMessage = "❌ Failed to save post: \(error.localizedDescription)"
                    isUploading = false
                    return
                }

                // Mark tool enabled
                ref.child("brands/\(brand.id)/toolsEnabled/blog").setValue(true)

                // If we replaced an image, delete the old one
                if let oldURL = previousImageURL, oldURL != imageURL, !oldURL.isEmpty {
                    deleteImageAtURLString(oldURL)
                }

                uploadMessage = editingPost == nil ? "✅ Blog post published!" : "✅ Changes saved!"
                isUploading = false
                clearForm()
                fetchPosts()
            }
        }

        // If a new image is selected, upload it. Else reuse previous (if any).
        if let imageData = imageData {
            let imageRef = Storage.storage().reference().child("brandBlogs/\(brand.id)/\(postId)_image.jpg")
            imageRef.putData(imageData, metadata: nil) { _, error in
                if let error = error {
                    uploadMessage = "❌ Image upload failed: \(error.localizedDescription)"
                    isUploading = false
                    return
                }
                imageRef.downloadURL { url, _ in
                    finishSave(imageURL: url?.absoluteString ?? "")
                }
            }
        } else {
            // keep previous image (if editing) or none (if creating)
            finishSave(imageURL: previousImageURL ?? "")
        }
    }

    // MARK: - Delete
    private func deletePost(_ post: BlogPost) {
        let ref = Database.database().reference()
        let path = "brands/\(brand.id)/blog/\(post.id)"

        // Delete DB node
        ref.child(path).removeValue { error, _ in
            if let error = error {
                print("❌ Failed to delete post \(post.id): \(error.localizedDescription)")
                return
            }
            print("🗑️ Deleted post \(post.id)")

            // Delete image if any
            if let imageURL = post.imageURL, !imageURL.isEmpty {
                deleteImageAtURLString(imageURL)
            }

            // Refresh UI
            posts.removeAll { $0.id == post.id }
        }
    }

    private func deleteImageAtURLString(_ urlString: String) {
        let storage = Storage.storage()
        if let ref = try? storage.reference(forURL: urlString) {
            ref.delete { error in
                if let error = error {
                    print("⚠️ Image delete warning: \(error.localizedDescription)")
                } else {
                    print("🧹 Deleted old image from Storage.")
                }
            }
        }
    }

    // MARK: - Fetch Existing
    private func fetchPosts() {
        isLoading = true
        let ref = Database.database().reference().child("brands").child(brand.id).child("blog")

        ref.observeSingleEvent(of: .value) { snapshot in
            var arr: [BlogPost] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let p = BlogPost.from(dict: dict, id: child.key) {
                    arr.append(p)
                } else {
                    print("❌ Failed to parse blog post for key \(child.key)")
                }
            }

            posts = arr.sorted(by: { $0.timestamp > $1.timestamp })
            isLoading = false
            print("✅ Loaded \(posts.count) blog posts for brand \(brand.id)")
        }
    }

    // MARK: - Edit helpers
    private func startEditing(_ post: BlogPost) {
        editingPost = post
        title = post.title
        bodyText = post.body
        isPremium = post.isPremium
        priceString = post.price > 0 ? String(format: "%.2f", post.price) : ""
        previousImageURL = post.imageURL
        imageData = nil
        imageItem = nil
    }

    private func clearForm() {
        editingPost = nil
        title = ""
        bodyText = ""
        isPremium = false
        priceString = ""
        imageItem = nil
        imageData = nil
        previousImageURL = nil
    }
}

// MARK: - Minimal row for management
private struct BlogManageRow: View {
    let post: BlogPost
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title)
                    .foregroundColor(.white)
                    .font(.headline)

                Text(Date(timeIntervalSince1970: post.timestamp), style: .date)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                if post.isPremium {
                    Text(String(format: "Premium • $%.2f", post.price))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            Menu {
                Button("Edit", action: onEdit)
                Button(role: .destructive, action: onDelete) {
                    Text("Delete")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Model for config screen (matches DB keys)
struct BlogPost: Identifiable {
    let id: String
    let title: String
    let body: String      // 🔑 "body" matches your DB
    let imageURL: String?
    let timestamp: TimeInterval
    let isPremium: Bool
    let price: Double

    static func from(dict: [String: Any], id: String) -> BlogPost? {
        guard let title = dict["title"] as? String,
              let body = dict["body"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }
        let imageURL = dict["imageURL"] as? String
        let isPremium = dict["isPremium"] as? Bool ?? false
        let price = dict["price"] as? Double ?? 0.0

        return BlogPost(
            id: id,
            title: title,
            body: body,
            imageURL: imageURL,
            timestamp: timestamp,
            isPremium: isPremium,
            price: price
        )
    }
}
