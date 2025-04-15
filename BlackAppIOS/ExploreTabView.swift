import SwiftUI
import FirebaseDatabase

struct ExploreTabView: View {
    @State private var approvedBrands: [Brand] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading Brands...")
                } else if approvedBrands.isEmpty {
                    Text("No brands are available at this time.")
                        .foregroundColor(.gray)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 20) {
                            ForEach(approvedBrands) { brand in
                                NavigationLink(destination: BrandStorefrontView(brand: brand)) {
                                    VStack {
                                        if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                                            AsyncImage(url: url) { image in
                                                image.resizable()
                                                    .aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                Color.gray
                                            }
                                            .frame(width: 100, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }

                                        Text(brand.name)
                                            .foregroundColor(.white)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .padding()
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(12)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Explore")
            .onAppear {
                fetchApprovedBrands()
            }
        }
        .preferredColorScheme(.dark)
    }

    func fetchApprovedBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value) { snapshot in
            var loaded: [Brand] = []

            for case let child as DataSnapshot in snapshot.children {
                if let data = child.value as? [String: Any],
                   let name = data["name"] as? String,
                   let desc = data["description"] as? String,
                   let userId = data["userId"] as? String,
                   let approved = data["approved"] as? Bool,
                   approved == true {

                    let brand = Brand(
                        id: child.key,
                        name: name,
                        description: desc,
                        logoURL: data["logoURL"] as? String,
                        userId: userId,
                        approved: approved,
                        timestamp: data["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                    )

                    loaded.append(brand)
                }
            }

            DispatchQueue.main.async {
                self.approvedBrands = loaded
                self.isLoading = false
            }
        }
    }
}
