import SwiftUI
import SDWebImageSwiftUI

struct BrandStorefrontView: View {
    var brand: BrandModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                    WebImage(url: url)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 5)
                } else {
                    Image(systemName: "building.2.crop.circle.fill")
                        .resizable()
                        .frame(width: 120, height: 120)
                        .foregroundColor(.gray)
                }

                Text(brand.name)
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)

                if let desc = brand.description, !desc.isEmpty {
                    Text(desc)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Divider().background(Color.white.opacity(0.2))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Shop")
                    Text("Services")
                    Text("Blog")
                    Text("Bookings")
                }
                .foregroundColor(.white)
                .padding(.horizontal)
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Storefront")
        .navigationBarTitleDisplayMode(.inline)
    }
}
