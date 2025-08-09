import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseStorage

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
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
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
        let ref = Database.database().reference().child("brands").child(brand.id).child("services")
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

// MARK: - Service Card
struct ServiceCard: View {
    let service: BrandService
    let brand: BrandModel
    let authVM: AuthViewModel
    @State private var imageURL: URL?
    @State private var isSaved = false
    @State private var showShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = imageURL {
                AsyncImage(url: imageURL) { img in
                    img.resizable().scaledToFill()
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

                Button(action: {
                    guard let userId = authVM.currentUser?.uid else { return }
                    PurchaseManager.shared.startCheckout(
                        buyerId: userId,
                        sellerId: brand.ownerId,
                        basePrice: service.price,
                        itemType: "service",
                        itemId: service.id,
                        itemTitle: service.title,
                        itemImageURL: service.imagePath ?? ""
                    )
                }) {
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

    func loadImage() {
        guard let path = service.imagePath, !path.isEmpty else { return }
        if path.starts(with: "http") {
            self.imageURL = URL(string: path)
        } else {
            let ref = Storage.storage().reference(withPath: path)
            ref.downloadURL { url, _ in self.imageURL = url }
        }
    }

    func toggleSave() {
        guard let userId = authVM.currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedServices").child(userId).child(service.id)

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

    func checkIfSaved() {
        guard let userId = authVM.currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedServices").child(userId).child(service.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }
}
