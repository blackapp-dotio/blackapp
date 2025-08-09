import SwiftUI
import Firebase
import FirebaseStorage
import FirebaseDatabase
import PhotosUI

struct BrandServicesConfigView: View {
    var brand: BrandModel

    // Form state
    @State private var title = ""
    @State private var description = ""
    @State private var category = ""
    @State private var price = ""
    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?

    // UX
    @State private var isUploading = false
    @State private var uploadMessage = ""
    @State private var services: [BrandServiceDoc] = []
    @State private var isLoadingList = true
    @State private var editingServiceId: String? = nil

    private var isEditing: Bool { editingServiceId != nil }
    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        Double(price) != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Service" : "Add a New Service")
                        .font(.title2).bold()
                        .foregroundColor(.white)
                    if let id = editingServiceId {
                        Text("Editing: \(id)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Group {
                    TextField("Service Title", text: $title)
                    TextField("Description", text: $description)
                    TextField("Category (optional)", text: $category)
                    TextField("Price (USD)", text: $price)
                        .keyboardType(.decimalPad)
                }
                .textFieldStyle(RoundedBorderTextFieldStyle())

                // Image picker
                VStack {
                    Text("Service Icon (Optional)")
                        .foregroundColor(.white)
                    PhotosPicker(selection: $imageItem, matching: .images) {
                        Text(imageData == nil ? "Select Image" : "Change Image")
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                    }

                    if let imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                            .cornerRadius(10)
                    }
                }

                if isUploading {
                    ProgressView(isEditing ? "Saving changes..." : "Uploading...")
                        .foregroundColor(.white)
                }

                if !uploadMessage.isEmpty {
                    Text(uploadMessage)
                        .foregroundColor(.white)
                        .padding(.top, 4)
                }

                // Actions
                HStack(spacing: 12) {
                    Button(isEditing ? "Save Changes" : "Upload Service") {
                        Task { await uploadOrUpdateService() }
                    }
                    .disabled(isUploading || !isFormValid)
                    .padding()
                    .background(isEditing ? Color.orange : Color.pink)
                    .foregroundColor(.white)
                    .cornerRadius(10)

                    if isEditing {
                        Button("Cancel") {
                            clearForm()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 8)

                // Existing services list
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Services", systemImage: "wrench.and.screwdriver.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Button { fetchServices() } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                    }

                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if services.isEmpty {
                        Text("No services yet.")
                            .foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(services, id: \.id) { svc in
                            ServiceRow(
                                service: svc,
                                onEdit: { loadForEdit(svc) },
                                onDelete: { deleteService(svc) }
                            )
                        }
                    }
                }
                .serviceGlassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchServices() }
        .onChange(of: imageItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    self.imageData = data
                }
            }
        }
    }

    // MARK: - Upload / Update
    private func uploadOrUpdateService() async {
        guard let priceVal = Double(price) else {
            uploadMessage = "Fill in all required fields correctly."
            return
        }

        isUploading = true
        uploadMessage = ""

        let serviceId = editingServiceId ?? UUID().uuidString
        let storageRef = Storage.storage().reference()

        var uploadedImageURL: String = ""
        if let imageData {
            let imageRef = storageRef.child("brandServices/\(brand.id)/\(serviceId)_icon.jpg")
            do {
                _ = try await imageRef.putDataAsync(imageData)
                uploadedImageURL = try await imageRef.downloadURL().absoluteString
            } catch {
                uploadMessage = "❌ Image upload failed: \(error.localizedDescription)"
                isUploading = false
                return
            }
        }

        let now = Date().timeIntervalSince1970
        var serviceData: [String: Any] = [
            "id": serviceId,
            "title": title,
            "description": description,
            "category": category,
            "price": priceVal,
            "timestamp": now
        ]

        if !uploadedImageURL.isEmpty {
            serviceData["imageURL"] = uploadedImageURL
        } else if isEditing == false {
            // If creating and no image provided, keep empty
            serviceData["imageURL"] = ""
        }

        let ref = Database.database().reference()
            .child("brands/\(brand.id)/services/\(serviceId)")

        do {
            try await ref.setValue(serviceData)
            try await Database.database().reference()
                .child("brands/\(brand.id)/toolsEnabled/services").setValue(true)

            uploadMessage = isEditing ? "✅ Service updated successfully!" : "✅ Service uploaded successfully!"
            fetchServices()
            clearForm()
        } catch {
            uploadMessage = "❌ Failed to save service: \(error.localizedDescription)"
        }

        isUploading = false
    }

    // MARK: - Fetch list
    private func fetchServices() {
        isLoadingList = true
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("services")

        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandServiceDoc] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let svc = BrandServiceDoc.from(dict: dict, id: child.key) {
                    temp.append(svc)
                }
            }
            self.services = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoadingList = false
        }
    }

    // MARK: - Edit
    private func loadForEdit(_ svc: BrandServiceDoc) {
        editingServiceId = svc.id
        title = svc.title
        description = svc.description
        category = svc.category
        price = String(format: "%.2f", svc.price)
        imageItem = nil
        imageData = nil
        uploadMessage = ""
    }

    // MARK: - Delete
    private func deleteService(_ svc: BrandServiceDoc) {
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("services")
            .child(svc.id)

        ref.removeValue { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                services.removeAll { $0.id == svc.id }
                if editingServiceId == svc.id { clearForm() }
            }
        }

        // Try to delete icon (optional)
        let storage = Storage.storage().reference()
        storage.child("brandServices/\(brand.id)/\(svc.id)_icon.jpg").delete(completion: nil)
    }

    // MARK: - Reset
    private func clearForm() {
        title = ""
        description = ""
        category = ""
        price = ""
        imageItem = nil
        imageData = nil
        editingServiceId = nil
    }
}

// MARK: - Model (unique name to avoid collisions with feed)
struct BrandServiceDoc: Identifiable {
    let id: String
    let title: String
    let description: String
    let category: String
    let price: Double
    let imageURL: String
    let timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> BrandServiceDoc? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let category = dict["category"] as? String? ?? "",
              let price = (dict["price"] as? NSNumber)?.doubleValue ?? dict["price"] as? Double,
              let timestamp = dict["timestamp"] as? TimeInterval
        else {
            return nil
        }

        let imageURL = dict["imageURL"] as? String ?? ""
        return BrandServiceDoc(
            id: id,
            title: title,
            description: description,
            category: category,
            price: price,
            imageURL: imageURL,
            timestamp: timestamp
        )
    }
}

// MARK: - Row UI
private struct ServiceRow: View {
    let service: BrandServiceDoc
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(service.title).font(.headline).foregroundColor(.white)
                if !service.category.isEmpty {
                    Text(service.category).font(.caption).foregroundColor(.white.opacity(0.7))
                }
                Text(service.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text("$\(service.price, specifier: "%.2f")")
                        .foregroundColor(.green)
                    Text(Self.formatDate(service.timestamp))
                        .foregroundColor(.white.opacity(0.6))
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
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - Local glass helper (unique name)
private extension View {
    func serviceGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
