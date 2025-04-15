import SwiftUI
import SDWebImageSwiftUI

struct BrandDashboardView: View {
    let brand: Brand

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                        WebImage(url: url)
                            .resizable()
                            .indicator(.activity)
                            .scaledToFit()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
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

                    Divider()

                    VStack(spacing: 16) {
                        dashboardLink("Manage Shop", icon: "bag.fill")
                        dashboardLink("Manage Blog", icon: "text.book.closed.fill")
                        dashboardLink("Manage Reservations", icon: "calendar")
                        dashboardLink("Manage Services", icon: "gear")
                    }
                    .padding(.top)
                }
                .padding()
            }
            .navigationTitle("Brand Dashboard")
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func dashboardLink(_ title: String, icon: String) -> some View {
        NavigationLink(destination: Text("\(title) Coming Soon")) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.blue)
                    .clipShape(Circle())

                Text(title)
                    .foregroundColor(.white)
                    .font(.headline)

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
        }
    }
}
