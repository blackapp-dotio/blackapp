import SwiftUI
import SDWebImageSwiftUI

struct BrandDashboardView: View {
    var brand: BrandModel

    // Full tool list
    let tools: [BrandTool] = [
        .init(name: "Shop", icon: "cart.fill", view: { BrandShopConfigView(brand: $0) }),
        .init(name: "Blog", icon: "doc.text", view: { BrandBlogConfigView(brand: $0) }),
        .init(name: "Bookings", icon: "calendar.badge.clock", view: { BrandBookingsConfigView(brand: $0) }),
        .init(name: "Services", icon: "wrench.and.screwdriver", view: { BrandServicesConfigView(brand: $0) }),
        .init(name: "Podcast", icon: "mic.fill", view: { BrandPodcastConfigView(brand: $0) }),
        .init(name: "Music", icon: "music.note", view: { BrandMusicConfigView(brand: $0) }),
        .init(name: "Vlog", icon: "video.circle.fill", view: { BrandVlogConfigView(brand: $0) })
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Brand Logo
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

                    // Brand Name and Description
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

                    // Tool Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Manage Tools")
                            .font(.headline)
                            .foregroundColor(.white)

                        ForEach(tools, id: \.name) { tool in
                            HStack {
                                Label(tool.name, systemImage: tool.icon)
                                Spacer()
                                NavigationLink(destination: tool.view(brand)) {
                                    Text("Configure")
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
}

// MARK: - Tool Abstraction

struct BrandTool {
    let name: String
    let icon: String
    let view: (BrandModel) -> AnyView

    init<V: View>(name: String, icon: String, view: @escaping (BrandModel) -> V) {
        self.name = name
        self.icon = icon
        self.view = { AnyView(view($0)) }
    }
}
