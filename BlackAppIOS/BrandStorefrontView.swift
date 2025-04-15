import SwiftUI
import SDWebImageSwiftUI

struct BrandStorefrontView: View {
    let brand: Brand

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let logo = brand.logoURL, let url = URL(string: logo) {
                    WebImage(url: url)
                        .resizable()
                        .indicator(.activity)
                        .transition(.fade(duration: 0.5))
                        .scaledToFit()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 30)
                }

                Text(brand.name)
                    .font(.title)
                    .bold()

                if !brand.description.isEmpty {
                    Text(brand.description)
                        .font(.body)
                        .foregroundColor(.gray)
                        .padding(.horizontal)
                }

                // Placeholder for storefront tools like Shop, Blog, Services
                VStack(spacing: 20) {
                    Text("This is the public storefront")
                        .font(.headline)

                    Button("Explore Products") {
                        // To be implemented
                    }

                    Button("Book a Reservation") {
                        // To be implemented
                    }
                }
                .padding()
            }
            .padding(.bottom, 50)
        }
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}
