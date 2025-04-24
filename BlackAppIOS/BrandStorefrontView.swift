import SwiftUI
import SDWebImageSwiftUI

struct BrandStorefrontView: View {
    let brand: BrandModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Logo
                if !brand.logoURL.isEmpty, let url = URL(string: brand.logoURL) {
                    WebImage(url: url)                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .cornerRadius(12)
                }

                // Name & Description
                Text(brand.name)
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)

                Text(brand.description)
                    .font(.body)
                    .foregroundColor(.gray)

                Divider()

                // 🛍️ Products Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("🛍️ Products")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("List of products offered by the brand will appear here.")
                        .foregroundColor(.gray)
                }

                Divider()

                // 🧰 Services Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("🧰 Services")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("List of services provided by the brand will appear here.")
                        .foregroundColor(.gray)
                }

                Divider()

                // 📝 Blog Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("📝 Blog")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Latest blog posts from this brand will be shown here.")
                        .foregroundColor(.gray)
                }

                Divider()

                // 📅 Booking/Reservation Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("📅 Bookings")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Reservation or table booking tools will be displayed here.")
                        .foregroundColor(.gray)
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
