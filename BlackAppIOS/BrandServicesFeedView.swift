import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage

// MARK: - BrandServicesFeedView
struct BrandServicesFeedView: View {
    var brand: BrandModel
    @State private var services: [BrandService] = []
    @State private var isLoading = true
    @EnvironmentObject var authVM: AuthViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(services) { service in
                    ServiceCard(service: service, brand: brand, authVM: authVM)
                        .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else if services.isEmpty {
                    Text("No services listed yet.")
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
        .navigationTitle("\(brand.name) Services")
        .onAppear { fetchServices() }
    }

    func fetchServices() {
        let ref = Database.database().reference()
            .child("brands").child(brand.id).child("services")

        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandService] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let service = BrandService.flexibleFrom(dict: dict, id: child.key) {
                    temp.append(service)
                }
            }
            self.services = temp
            self.isLoading = false
        }
    }
}

// MARK: - BrandService Model
struct BrandService: Identifiable {
    var id: String
    var title: String
    var description: String
    var price: Double
    var imagePath: String?

    static func flexibleFrom(dict: [String: Any], id: String) -> BrandService? {
        guard let description = dict["description"] as? String,
              let price = dict["price"] as? Double else { return nil }

        let title = dict["title"] as? String ?? description
        let imagePath = dict["imagePath"] as? String ?? dict["imageURL"] as? String

        return BrandService(id: id, title: title, description: description, price: price, imagePath: imagePath)
    }
}

// MARK: - Universal Checkout URL Builder
fileprivate enum Checkout {
    /// Hosted universal checkout (Card or PayPal via Braintree)
    static let base = "https://blackapp.io/checkout" // if you used a rewrite, keep it as /checkout

    /// Build a URL for any monetized tool (here we use `services`)
    static func url(
        tool: String,
        brandId: String,
        itemId: String,
        title: String,
        price: Double,
        currency: String = "USD",
        imagePath: String?,
        userId: String?,
        allowQty: Bool = false,
        minQty: Int = 1,
        maxQty: Int = 1,
        returnUrl: String = "blackappios://done",
        clientTokenUrl: String? = nil,   // optional: override where the page fetches Braintree client tokens
        chargeUrl: String? = nil         // optional: override where the page posts charges
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

// MARK: - Service Card
struct ServiceCard: View {
    let service: BrandService
    let brand: BrandModel
    let authVM: AuthViewModel
    @State private var imageURL: URL?
    @State private var isSaved = false
    @State private var showShare = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = imageURL {
                AsyncImage(url: imageURL) { img in
                    img
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Text(service.title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(service.description)
                .font(.body)
                .foregroundColor(.gray)
                .lineLimit(3)

            HStack {
                Text("$\(service.price, specifier: "%.2f")")
                    .font(.headline)
                    .foregroundColor(.green)

                Spacer()

                Button(action: openCheckout) {
                    Text("Book Now")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.8))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 24) {
                Button(action: toggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundColor(isSaved ? .red : .white)
                        .font(.title2)
                }

                Button(action: { showShare = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                        .font(.title2)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear {
            loadImage()
            checkIfSaved()
        }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: [
                service.title,
                URL(string: "https://blackappios.web.app/service.html?serviceId=\(service.id)")!
            ])
        }
    }

    // MARK: Actions

    /// Opens the universal checkout with the service pre-filled
    private func openCheckout() {
        // If users must be signed in to pay, early-exit when uid is missing.
        // Otherwise remove this guard to allow guest checkout (the checkout will store under purchases/guest).
        // Here we keep your original requirement that user is logged in first.
        guard let userId = authVM.currentUser?.uid else { return }

        let url = Checkout.url(
            tool: "services",
            brandId: brand.id,
            itemId: service.id,
            title: service.title,
            price: service.price,
            currency: "USD",
            imagePath: service.imagePath,
            userId: userId,
            allowQty: false,      // services are typically 1 per order
            minQty: 1,
            maxQty: 1,
            returnUrl: "blackappios://done"
            // If your token/charge endpoints are not same-origin as blackapp.io, pass overrides:
            // clientTokenUrl: "https://blackapp.io/api/client_token",
            // chargeUrl: "https://blackapp.io/api/charge_braintree"
        )

        if let url { openURL(url) }
    }

    private func loadImage() {
        guard let path = service.imagePath, !path.isEmpty else { return }
        if path.starts(with: "http") {
            self.imageURL = URL(string: path)
        } else {
            let ref = Storage.storage().reference(withPath: path)
            ref.downloadURL { url, _ in
                self.imageURL = url
            }
        }
    }

    private func toggleSave() {
        guard let userId = authVM.currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("savedServices").child(userId).child(service.id)

        if isSaved {
            ref.removeValue()
            isSaved = false
        } else {
            let data: [String: Any] = [
                "title": service.title,
                "price": service.price,
                "imagePath": service.imagePath ?? "",
                "timestamp": Date().timeIntervalSince1970
            ]
            ref.setValue(data)
            isSaved = true
        }
    }

    private func checkIfSaved() {
        guard let userId = authVM.currentUser?.uid else { return }
        let ref = Database.database().reference()
            .child("savedServices").child(userId).child(service.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }
}
