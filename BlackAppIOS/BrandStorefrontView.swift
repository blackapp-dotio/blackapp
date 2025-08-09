import SwiftUI
import SDWebImageSwiftUI

struct BrandStorefrontView: View {
    var brand: BrandModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Brand Logo
                if let logoURL = brand.logoURL, let url = URL(string: logoURL) {
                    WebImage(url: url)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(radius: 8)
                } else {
                    Image(systemName: "building.2.crop.circle.fill")
                        .resizable()
                        .frame(width: 120, height: 120)
                        .foregroundColor(.gray)
                }

                // Brand Name
                Text(brand.name)
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)

                // Description
                if let desc = brand.description, !desc.isEmpty {
                    Text(desc)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Divider().background(Color.white.opacity(0.3))

                // Tool Buttons
                VStack(spacing: 16) {
                    if brand.configuredTools.contains("shop") {
                        storefrontTile(label: "Shop", icon: "bag.fill") {
                            BrandShopFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("services") {
                        storefrontTile(label: "Services", icon: "wrench.and.screwdriver") {
                            BrandServicesFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("blog") {
                        storefrontTile(label: "Blog", icon: "text.book.closed") {
                            BrandBlogFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("bookings") {
                        storefrontTile(label: "Bookings", icon: "calendar") {
                            BrandBookingsFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("podcast") {
                        storefrontTile(label: "Podcasts", icon: "mic.fill") {
                            BrandPodcastFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("vlog") {
                        storefrontTile(label: "Vlogs", icon: "video.fill") {
                            BrandVlogFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("music") {
                        storefrontTile(label: "Music", icon: "music.note") {
                            BrandMusicFeedView(brand: brand)
                        }
                    }

                    if brand.configuredTools.contains("console") {
                        storefrontTile(label: "Console", icon: "gamecontroller.fill") {
                            BrandConsoleFeedView(brand: brand)
                        }
                    }
                }
                .padding(.top)
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Storefront")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Stylized Navigation Tile
    @ViewBuilder
    func storefrontTile<Destination: View>(label: String, icon: String, destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.white)
                Text(label)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding()
            .background(
                BlurView(style: .systemThinMaterialDark)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Futuristic Liquid Glass Modifier
extension View {
    func glassBackground(cornerRadius: CGFloat = 16) -> some View {
        self
            .padding()
            .background(
                BlurView(style: .systemUltraThinMaterialDark)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
    }
}

// MARK: - BlurView for Glass Effect
struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
