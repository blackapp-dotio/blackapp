import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage

// MARK: - BrandShopFeedView
struct BrandShopFeedView: View {
    var brand: BrandModel
    @State private var products: [BrandProduct] = []
    @State private var isLoading = true
    @EnvironmentObject var authVM: AuthViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(products) { product in
                    ProductCard(brand: brand, product: product)
                        .environmentObject(authVM)
                        .padding(.horizontal)
                }

                if isLoading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else if products.isEmpty {
                    Text("No products available.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .padding(.top)
        }
        .background(
            LinearGradient(gradient: Gradient(colors: [.black, .gray.opacity(0.2)]),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .navigationTitle("\(brand.name) Shop")
        .onAppear {
            fetchProducts()
        }
    }

    func fetchProducts() {
        print("🛍️ Fetching products for brand ID: \(brand.id)")
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("shop")

        ref.observeSingleEvent(of: .value) { snapshot in
            var loadedProducts: [BrandProduct] = []

            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let dict = snap.value as? [String: Any],
                   let item = BrandProduct.flexibleFrom(dict: dict, id: snap.key) {
                    loadedProducts.append(item)
                } else {
                    print("❌ Failed to parse product with ID: \(child)")
                }
            }

            self.products = loadedProducts
            self.isLoading = false
            print("✅ Loaded \(loadedProducts.count) products")
        }
    }
}

// MARK: - BrandProduct Model
struct BrandProduct: Identifiable {
    var id: String
    var title: String
    var description: String
    var price: Double
    var imagePath: String

    static func flexibleFrom(dict: [String: Any], id: String) -> BrandProduct? {
        guard
            let description = dict["description"] as? String,
            let price = dict["price"] as? Double
        else {
            return nil
        }

        let title = dict["title"] as? String ?? description
        let imagePath = dict["imagePath"] as? String ??
                        dict["imageURL"] as? String ?? ""

        guard !imagePath.isEmpty else {
            print("⚠️ Skipping product with empty image path: \(id)")
            return nil
        }

        return BrandProduct(id: id, title: title, description: description, price: price, imagePath: imagePath)
    }
}

// MARK: - Universal Checkout URL Builder
fileprivate enum Checkout {
    /// Hosted universal checkout (Card or PayPal via Braintree)
    static let base = "https://blackapp.io/checkout" // if you rewrote /checkout → /checkout.html

    /// Build a URL for any monetized tool; here used by the Shop feed
    static func url(
        tool: String,
        brandId: String,
        itemId: String,
        title: String,
        price: Double,
        currency: String = "USD",
        imagePath: String?,
        userId: String?,
        allowQty: Bool = true,
        minQty: Int = 1,
        maxQty: Int = 5,
        returnUrl: String = "blackappios://done",
        clientTokenUrl: String? = nil,  // optional override
        chargeUrl: String? = nil        // optional override
    ) -> URL? {
        var comps = URLComponents(string: base)
        var q: [URLQueryItem] = [
            .init(name: "tool", value: tool),
            .init(name: "brandId", value: brandId),
            .init(name: "itemId", value: itemId),
            .init(name: "title", value: title),
            .init(name: "price", value: String(format: "%.2f", price)),
            .init(name: "currency", value: currency),
            .init(name: "allowQty", value: allowQty ? "1" : "0"),
            .init(name: "minQty", value: "\(minQty)"),
            .init(name: "maxQty", value: "\(maxQty)"),
            .init(name: "returnUrl", value: returnUrl)
        ]

        if let imagePath, !imagePath.isEmpty {
            q.append(.init(name: "imagePath", value: imagePath))
        }
        if let userId, !userId.isEmpty {
            q.append(.init(name: "userId", value: userId))
        }
        if let clientTokenUrl, !clientTokenUrl.isEmpty {
            q.append(.init(name: "clientTokenUrl", value: clientTokenUrl))
        }
        if let chargeUrl, !chargeUrl.isEmpty {
            q.append(.init(name: "chargeUrl", value: chargeUrl))
        }

        comps?.queryItems = q
        return comps?.url
    }
}

// MARK: - Product Card
struct ProductCard: View {
    let brand: BrandModel
    let product: BrandProduct

    @State private var imageURL: URL?
    @State private var isSaved = false
    @State private var showShareSheet = false

    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Top actions row (Save + Share)
            HStack(spacing: 16) {
                Button(action: toggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .imageScale(.large)
                        .foregroundColor(isSaved ? .red : .white)
                }
                .buttonStyle(.plain)

                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .imageScale(.large)
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Image
            if let imageURL = imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.1)))
                .shadow(radius: 8)
            }

            // Text
            Text(product.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(product.description)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(2)

            // Price + Buy
            HStack {
                Text("$\(product.price, specifier: "%.2f")")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.green)

                Spacer()

                Button {
                    // Require login like your original flow; if you want guest checkout, remove this guard
                    guard let userId = (authVM.currentUser?.uid ?? authVM.user?.uid) else {
                        print("❌ No user logged in")
                        return
                    }

                    let url = Checkout.url(
                        tool: "shop",
                        brandId: brand.id,
                        itemId: product.id,
                        title: product.title,
                        price: product.price,
                        currency: "USD",
                        imagePath: product.imagePath,
                        userId: userId,
                        allowQty: true,     // shoppers can buy multiple
                        minQty: 1,
                        maxQty: 5,
                        returnUrl: "blackappios://done"
                        // If your token/charge endpoints live elsewhere, pass overrides:
                        // clientTokenUrl: "https://blackapp.io/api/client_token",
                        // chargeUrl: "https://blackapp.io/api/charge_braintree"
                    )

                    if let url { openURL(url) }
                } label: {
                    Text("Buy Now")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear {
            loadImage()
            checkSavedStatus() // keep UI in sync on load
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: shareItems())
        }
    }

    // MARK: - Save / Share

    private func savedRef(for uid: String) -> DatabaseReference {
        Database.database().reference()
            .child("savedProducts")
            .child(uid)
            .child(product.id)
    }

    private func toggleSave() {
        guard let uid = (authVM.currentUser?.uid ?? authVM.user?.uid) else { return }
        let ref = savedRef(for: uid)

        if isSaved {
            ref.removeValue()
            isSaved = false
        } else {
            // keep it light; you can store more fields if you want
            let data: [String: Any] = [
                "title": product.title,
                "description": product.description,
                "price": product.price,
                "imagePath": product.imagePath,
                "brandId": brand.id,
                "timestamp": Date().timeIntervalSince1970
            ]
            ref.setValue(data)
            isSaved = true
        }
    }

    private func checkSavedStatus() {
        guard let uid = (authVM.currentUser?.uid ?? authVM.user?.uid) else { return }
        savedRef(for: uid).observeSingleEvent(of: .value) { snap in
            isSaved = snap.exists()
        }
    }

    private func shareItems() -> [Any] {
        var items: [Any] = []
        items.append("🛍️ Check out “\(product.title)” from \(brand.name) on BlackApp!")
        if let url = hostedProductURL() { items.append(url) }
        if let img = imageURL { items.append(img) }
        return items
    }

    private func hostedProductURL() -> URL? {
        // replace with your real hosted URL pattern when ready
        URL(string: "https://blackappios.web.app/product.html?brandId=\(brand.id)&productId=\(product.id)")
    }

    // MARK: - Image

    private func loadImage() {
        if product.imagePath.starts(with: "http") {
            self.imageURL = URL(string: product.imagePath)
        } else {
            let ref = Storage.storage().reference(withPath: product.imagePath)
            ref.downloadURL { url, error in
                if let url = url {
                    self.imageURL = url
                } else {
                    print("❌ Failed to load image for product \(product.id): \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }
}

/*// MARK: - Native Share Sheet (keep commented if you already define ActivityView elsewhere)
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
*/
