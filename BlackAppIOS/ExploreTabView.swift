import SwiftUI
import Firebase
import FirebaseDatabase
import SDWebImageSwiftUI
import SafariServices

// MARK: - ExploreTabView

struct ExploreTabView: View {
    @State private var approvedBrands: [BrandModel] = []
    @State private var showNjangiModal: Bool = false

    // 2-up grid for mini apps (scales well as you add more)
    private let miniAppColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // === Mini Apps Section ===
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mini Apps")
                            .font(.title3).bold()
                            .foregroundColor(.white)
                            .padding(.horizontal)

                        LazyVGrid(columns: miniAppColumns, spacing: 16) {

                            // Nightlife mini app — same route as Events tab button
                            NavigationLink {
                                NightlifeHomeView()
                                    // Ensure destination does not suppress back nav
                                    .navigationBarBackButtonHidden(false)
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                NightlifeMiniAppIcon()
                            }

                            // Njangi mini app — loads the existing web experience in a modal
                            Button {
                                showNjangiModal = true
                            } label: {
                                NjangiMiniAppIcon()
                            }

                            // (Room for more mini apps in future…)
                        }
                        .padding(.horizontal)
                    }

                    // === Brands Section (existing logic preserved) ===
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Explore Brands")
                            .font(.title3).bold()
                            .foregroundColor(.white)
                            .padding(.horizontal)

                        LazyVStack(spacing: 20) {
                            ForEach(approvedBrands) { brand in
                                NavigationLink {
                                    BrandStorefrontView(brand: brand)
                                        // Ensure destination does not suppress back nav
                                        .navigationBarBackButtonHidden(false)
                                        .navigationBarTitleDisplayMode(.inline)
                                } label: {
                                    BrandCardView(brand: brand)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top)
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .background(Color.black.ignoresSafeArea())
            // Keep the Explore title visible + consistent on dark backgrounds
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .sheet(isPresented: $showNjangiModal) {
            NjangiSafariModalView()
        }
        .onAppear(perform: fetchApprovedBrands)
    }

    // MARK: - Njangi Safari Modal

    struct NjangiSafariModalView: View {
        private let njangiURL = URL(string: "https://black-app-web.web.app/njangi")!

        var body: some View {
            SafariView(url: njangiURL)
                .ignoresSafeArea()
        }
    }

    // MARK: - SafariView Wrapper

    struct SafariView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            let config = SFSafariViewController.Configuration()
            config.entersReaderIfAvailable = false

            let vc = SFSafariViewController(url: url, configuration: config)
            vc.dismissButtonStyle = .close
            vc.preferredControlTintColor = .white   // fits BlackApp’s look
            return vc
        }

        func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
            // No-op
        }
    }
    // MARK: - Data

    private func fetchApprovedBrands() {
        let ref = Database.database().reference().child("brands")

        ref.observeSingleEvent(of: .value) { snapshot in
            var loadedBrands: [BrandModel] = []

            for case let child as DataSnapshot in snapshot.children {
                guard let dict = child.value as? [String: Any] else { continue }

                // Robust approval/suspension evaluation (works even if older records only have one of these fields)
                let statusRaw = (dict["status"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                let approvedBool = (dict["approved"] as? Bool) ?? false
                let suspendedBool = (dict["suspended"] as? Bool) ?? false

                let isApproved = approvedBool || (statusRaw == "approved")
                let isSuspended = suspendedBool || (statusRaw == "suspended")

                // Hard rule: suspended brands never appear in Explore
                guard isApproved, !isSuspended else { continue }

                // Build BrandModel only after passing filters
                if let brand = BrandModel.from(dict: dict, id: child.key) {
                    loadedBrands.append(brand)
                }
            }

            // Optional: stable ordering (remove if you already sort elsewhere)
            loadedBrands.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self.approvedBrands = loadedBrands
            }
        }
    }

    // MARK: - Brand Card

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
}

// MARK: - Njangi Mini App Icon

struct NjangiMiniAppIcon: View {
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.gray.opacity(0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 120)

                Image("njg") // from /Assets.xcassets/njani/njg.imageset
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(radius: 4)
            }

            Text("Njangi")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            Text("Rotating savings clubs")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(8)
    }
}

