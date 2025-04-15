import SwiftUI
import FirebaseAuth
import FirebaseDatabase

struct BrandDetailView: View {
    let brand: Brand

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                    AsyncImage(url: url) { image in
                        image.resizable()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(brand.name)
                    .font(.title)
                    .bold()

                Text(brand.description)
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Divider()

                Text("Manage Your Brand")
                    .font(.headline)
                    .padding(.top)

                VStack(spacing: 16) {
                    NavigationLink(destination: Text("Configure Shop View")) {
                        ToolTileView(title: "Shop", systemImage: "bag")
                    }

                    NavigationLink(destination: Text("Configure Blog View")) {
                        ToolTileView(title: "Blog", systemImage: "doc.text")
                    }

                    NavigationLink(destination: Text("Configure Bookings View")) {
                        ToolTileView(title: "Reservations / Booking", systemImage: "calendar")
                    }

                    NavigationLink(destination: Text("Configure Services View")) {
                        ToolTileView(title: "Services", systemImage: "wrench.and.screwdriver")
                    }
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle("Brand Backend")
        .preferredColorScheme(.dark)
    }
}

struct ToolTileView: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .resizable()
                .frame(width: 30, height: 30)
                .foregroundColor(.blue)

            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color.black.opacity(0.15))
        .cornerRadius(12)
    }
}
