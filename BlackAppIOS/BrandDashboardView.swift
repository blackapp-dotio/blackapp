import SwiftUI
import SDWebImageSwiftUI

struct BrandDashboardView: View {
    var brand: BrandModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                    WebImage(url: url)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 5)
                } else {
                    Image(systemName: "building.2.crop.circle.fill")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.gray)
                }

                Text(brand.name)
                    .font(.title)
                    .bold()
                    .foregroundColor(.white)

                if let desc = brand.description, !desc.isEmpty {
                    Text(desc)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }

                Divider().background(Color.white.opacity(0.2))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Manage Tools").font(.headline).foregroundColor(.white)

                    ForEach(["Shop", "Blog", "Bookings", "Services"], id: \.self) { tool in
                        HStack {
                            Label(tool, systemImage: "gear")
                            Spacer()
                            Button("Configure") {
                                // Navigate to setup
                            }
                        }
                        .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Brand Dashboard")
    }
}
