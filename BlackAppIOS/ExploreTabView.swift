import SwiftUI
import Firebase
import FirebaseDatabase
import SDWebImageSwiftUI

struct ExploreTabView: View {
    @State private var approvedBrands: [BrandModel] = []

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(approvedBrands) { brand in
                        NavigationLink(destination: BrandStorefrontView(brand: brand)) {
                            BrandCardView(brand: brand)
                        }
                    }
                }
                .padding(.top)
            }
            .navigationTitle("Explore Brands")
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear(perform: fetchApprovedBrands)
    }

    private func fetchApprovedBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value) { snapshot in
            var loadedBrands: [BrandModel] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key),
                   brand.approved {
                    loadedBrands.append(brand)
                }
            }

            self.approvedBrands = loadedBrands
        }
    }
}

struct BrandCardView: View {
    let brand: BrandModel

    var body: some View {
        HStack(spacing: 12) {
            if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                WebImage(url: url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .shadow(radius: 3)
            } else {
                Image(systemName: "building.2.crop.circle.fill")
                    .resizable()
                    .frame(width: 60, height: 60)
                    .foregroundColor(.gray)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(brand.name)
                    .font(.headline)
                    .foregroundColor(.white)

                if let desc = brand.description, !desc.isEmpty {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                } else {
                    Text("No description available.")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .italic()
                }
            }

            Spacer()
        }
        .padding(.horizontal)
    }
}
