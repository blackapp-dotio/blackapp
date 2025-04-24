import SwiftUI
import FirebaseFirestore

struct AGDashboardView: View {
    @State private var pendingBrands: [Brand] = []
    @State private var appStats: [String: Int] = [:]
    @State private var admins: [String] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Admin Dashboard")
                        .font(.largeTitle.bold())

                    // Pending Brand Approvals
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pending Brand Approvals")
                            .font(.headline)

                        ForEach(pendingBrands) { brand in
                            HStack {
                                if let url = URL(string: brand.logoURL ?? "") {
                                    AsyncImage(url: url) { image in
                                        image.resizable().frame(width: 40, height: 40).clipShape(Circle())
                                    } placeholder: {
                                        Circle().fill(Color.gray.opacity(0.4)).frame(width: 40, height: 40)
                                    }
                                }

                                Text(brand.name)
                                    .font(.subheadline)

                                Spacer()

                                Button("Approve") {
                                    approveBrand(brand)
                                }
                                .foregroundColor(.green)
                            }
                        }
                    }

                    Divider()

                    // App Stats
                    VStack(alignment: .leading, spacing: 8) {
                        Text("App Usage Statistics")
                            .font(.headline)

                        ForEach(appStats.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack {
                                Text(key.capitalized + ":")
                                Spacer()
                                Text("\(value)")
                            }
                        }
                    }

                    Divider()

                    // Admin List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Platform Admins")
                            .font(.headline)

                        ForEach(admins, id: \.self) { email in
                            HStack {
                                Text(email)
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AG Dashboard")
            .onAppear {
                fetchDashboardData()
            }
        }
    }

    func fetchDashboardData() {
        let db = Firestore.firestore()

        // Load Pending Brands
        db.collection("brands").whereField("isApproved", isEqualTo: false).getDocuments { snapshot, _ in
            self.pendingBrands = snapshot?.documents.compactMap { doc in
                try? doc.data(as: Brand.self)
            } ?? []
        }

        // Load App Stats
        db.collection("stats").document("counts").getDocument { doc, _ in
            if let data = doc?.data() as? [String: Int] {
                self.appStats = data
            }
        }

        // Load Admins
        db.collection("admins").getDocuments { snapshot, _ in
            self.admins = snapshot?.documents.compactMap { $0.documentID } ?? []
        }

        self.isLoading = false
    }

    func approveBrand(_ brand: Brand) {
        let db = Firestore.firestore()
        db.collection("brands").document(brand.id).updateData(["isApproved": true])
        self.pendingBrands.removeAll { $0.id == brand.id }
    }
}
