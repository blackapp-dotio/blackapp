import SwiftUI
import FirebaseDatabase
import SDWebImageSwiftUI

struct ExploreTabView: View {
    @State private var approvedBrands: [BrandModel] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            exploreBody
                .navigationTitle("Explore")
                .background(Color.black)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: fetchApprovedBrands)
    }

    @ViewBuilder
    private var exploreBody: some View {
        if isLoading {
            ProgressView("Loading Brands...")
                .padding()
        } else if approvedBrands.isEmpty {
            Text("No brands available right now.")
                .foregroundColor(.gray)
                .padding()
        } else {
            ScrollView {
                brandGrid
                    .padding()
            }
        }
    }

    private var brandGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
            ForEach(approvedBrands) { brand in
                NavigationLink(destination: BrandStorefrontView(brand: brand)) {
                    brandCard(for: brand)
                }
            }
        }
    }

    private func brandCard(for brand: BrandModel) -> some View {
        VStack(spacing: 8) {
            WebImage(url: URL(string: brand.logoURL))
                .resizable()
                .indicator(.activity)
                .aspectRatio(contentMode: .fit)
                .frame(height: 80)
                .clipShape(Circle())

            Text(brand.name)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding()
        .background(Color.black.opacity(0.2))
        .cornerRadius(12)
    }

    private func fetchApprovedBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value, with: { snapshot in
            var loaded: [BrandModel] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key),
                   brand.approved {
                    loaded.append(brand)
                }
            }

            DispatchQueue.main.async {
                self.approvedBrands = loaded.sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
                self.isLoading = false
            }
        })
        }
    }

