import SwiftUI
import Firebase
import FirebaseStorage
import FirebaseDatabase
import PhotosUI

struct BrandShopConfigView: View {
    var brand: BrandModel
    
    // Form
    @State private var title = ""
    @State private var description = ""
    @State private var price = ""
    @State private var quantity = ""
    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?
    
    // UX
    @State private var isUploading = false
    @State private var uploadMessage = ""
    @State private var products: [BrandShopItemDoc] = []
    @State private var isLoadingList = true
    @State private var editingProductId: String? = nil   // nil = create, non-nil = edit
    
    private var isEditing: Bool { editingProductId != nil }
    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        Double(price) != nil &&
        Int(quantity) != nil
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Product" : "Add New Product")
                        .font(.title2).bold()
                        .foregroundColor(.white)
                    if let id = editingProductId {
                        Text("Editing: \(id)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                // Form
                Group {
                    TextField("Product Title", text: $title)
                    TextField("Description", text: $description)
                    TextField("Price (USD)", text: $price).keyboardType(.decimalPad)
                    TextField("Quantity in Stock", text: $quantity).keyboardType(.numberPad)
                }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                
                // Image
                VStack {
                    Text("Product Image (Optional)")
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
                            .frame(height: 120)
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
                }
                
                // Actions
                HStack(spacing: 12) {
                    Button(isEditing ? "Save Changes" : "Upload Product") {
                        Task { await uploadOrUpdateProduct() }
                    }
                    .disabled(isUploading || !isFormValid)
                    .padding()
                    .background(isEditing ? Color.orange : Color.orange)
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
                
                // Existing products list
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Products", systemImage: "shippingbox.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Button { fetchProducts() } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(.white)
                        }
                    }
                    
                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if products.isEmpty {
                        Text("No products yet.")
                            .foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(products, id: \.id) { item in
                            ProductRow(
                                product: item,
                                onEdit: { loadForEdit(item) },
                                onDelete: { deleteProduct(item) }
                            )
                        }
                    }
                }
                .shopGlassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchProducts() }
        .onChange(of: imageItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    self.imageData = data
                }
            }
        }
    }
    
    // MARK: - Create / Update
    private func uploadOrUpdateProduct() async {
        guard let priceValue = Double(price),
              let quantityValue = Int(quantity) else {
            uploadMessage = "Please fill out all fields correctly."
            return
        }
        
        isUploading = true
        uploadMessage = ""
        
        let productId = editingProductId ?? UUID().uuidString
        let storage = Storage.storage().reference()
        var uploadedImageURL: String = ""
        
        if let imageData {
            let imageRef = storage.child("brandShops/\(brand.id)/\(productId)_image.jpg")
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
        var productData: [String: Any] = [
            "id": productId,
            "title": title,
            "description": description,
            "price": priceValue,
            "quantity": quantityValue,
            "timestamp": now
        ]
        
        if !uploadedImageURL.isEmpty {
            productData["imageURL"] = uploadedImageURL
        } else if !isEditing {
            productData["imageURL"] = ""
        }
        
        let ref = Database.database().reference()
            .child("brands/\(brand.id)/shop/\(productId)")
        
        do {
            try await ref.setValue(productData)
            try await Database.database().reference()
                .child("brands/\(brand.id)/toolsEnabled/shop").setValue(true)
            
            uploadMessage = isEditing ? "✅ Product updated!" : "✅ Product uploaded successfully!"
            fetchProducts()
            clearForm()
        } catch {
            uploadMessage = "❌ Failed to save product: \(error.localizedDescription)"
        }
        
        isUploading = false
    }
    
    // MARK: - Fetch list
    private func fetchProducts() {
        isLoadingList = true
        let ref = Database.database().reference()
            .child("brands").child(brand.id).child("shop")
        
        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandShopItemDoc] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let item = BrandShopItemDoc.from(dict: dict, id: child.key) {
                    temp.append(item)
                }
            }
            self.products = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoadingList = false
        }
    }
    
    // MARK: - Edit
    private func loadForEdit(_ item: BrandShopItemDoc) {
        editingProductId = item.id
        title = item.title
        description = item.description
        price = String(format: "%.2f", item.price)
        quantity = "\(item.quantity)"
        imageItem = nil
        imageData = nil
        uploadMessage = ""
    }
    
    // MARK: - Delete
    private func deleteProduct(_ item: BrandShopItemDoc) {
        let ref = Database.database().reference()
            .child("brands").child(brand.id).child("shop").child(item.id)
        
        ref.removeValue { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                products.removeAll { $0.id == item.id }
                if editingProductId == item.id { clearForm() }
            }
        }
        
        // Best-effort image cleanup
        let storage = Storage.storage().reference()
        storage.child("brandShops/\(brand.id)/\(item.id)_image.jpg").delete(completion: nil)
    }
    
    // MARK: - Reset
    private func clearForm() {
        title = ""
        description = ""
        price = ""
        quantity = ""
        imageItem = nil
        imageData = nil
        editingProductId = nil
    }
}

// MARK: - Unique model to avoid clashes with feed structs
struct BrandShopItemDoc: Identifiable {
    let id: String
    let title: String
    let description: String
    let price: Double
    let quantity: Int
    let imageURL: String
    let timestamp: TimeInterval
    
    static func from(dict: [String: Any], id: String) -> BrandShopItemDoc? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let priceAny = dict["price"],
              let quantityAny = dict["quantity"],
              let timestamp = dict["timestamp"] as? TimeInterval
        else { return nil }
        
        // Handle number types safely (Double, NSNumber, String → Double)
        let price: Double
        if let p = priceAny as? Double {
            price = p
        } else if let p = priceAny as? NSNumber {
            price = p.doubleValue
        } else if let p = priceAny as? String, let val = Double(p) {
            price = val
        } else {
            return nil
        }
        
        let quantity: Int
        if let q = quantityAny as? Int {
            quantity = q
        } else if let q = quantityAny as? NSNumber {
            quantity = q.intValue
        } else if let q = quantityAny as? String, let val = Int(q) {
            quantity = val
        } else {
            return nil
        }
        
        let imageURL = dict["imageURL"] as? String ?? ""
        
        return BrandShopItemDoc(
            id: id,
            title: title,
            description: description,
            price: price,
            quantity: quantity,
            imageURL: imageURL,
            timestamp: timestamp
        )
    }
}

// MARK: - Row UI
private struct ProductRow: View {
    let product: BrandShopItemDoc
    var onEdit: () -> Void
    var onDelete: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(product.title).font(.headline).foregroundColor(.white)
                Text(product.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text("$\(product.price, specifier: "%.2f")")
                        .foregroundColor(.green)
                    Text("Qty: \(product.quantity)")
                        .foregroundColor(.white.opacity(0.85))
                    Text(Self.formatDate(product.timestamp))
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
    func shopGlassCard(cornerRadius: CGFloat = 16) -> some View {
        self.padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
