import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase

struct AGDashboardView: View {
    @State private var pendingBrands: [BrandModel] = []
    @State private var users: [DashboardUser] = []
    @State private var filteredUsers: [DashboardUser] = []
    @State private var searchQuery: String = ""
    @State private var admins: Set<String> = []
    @State private var superadmins: Set<String> = []
    @State private var platformStats: PlatformStats = .empty
    @State private var revenueStats: RevenueStats = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("🛠️ AG Dashboard")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                statsSection
                Divider()
                revenueSection
                Divider()
                brandApprovalSection
                Divider()
                userManagementSection
            }
            .padding()
        }
        .onAppear {
            fetchPendingBrands()
            fetchUsers()
            fetchAdminList()
            fetchSuperAdminList()
            calculatePlatformStats()
            fetchRevenueStats()
        }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - UI Sections

    private var statsSection: some View {
        VStack(alignment: .leading) {
            Text("📊 Platform Stats").font(.title2).bold()
            HStack(spacing: 32) {
                statCard(label: "Users", value: "\(platformStats.totalUsers)")
                statCard(label: "Brands", value: "\(platformStats.totalBrands)")
                statCard(label: "Approved", value: "\(platformStats.approvedBrands)")
            }
        }
    }

    private var revenueSection: some View {
        VStack(alignment: .leading) {
            Text("💰 Revenue").font(.title2).bold()
            Text("Monthly: $\(revenueStats.monthly)")
            Text("Total: $\(revenueStats.total)")
                .foregroundColor(.green)
        }
    }

    private var brandApprovalSection: some View {
        VStack(alignment: .leading) {
            Text("✅ Approve Brands").font(.title2).bold()
            ForEach(pendingBrands.filter { !$0.suspended }, id: \.id) { brand in
                HStack {
                    Text(brand.name)
                        .bold()
                        .foregroundColor(.white)
                    Spacer()
                    Button("Approve") { approveBrand(brand) }
                        .buttonStyle(.borderedProminent)
                    Button("Suspend") { suspendBrand(brand) }
                        .foregroundColor(.yellow)
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            }
        }
    }

    private var userManagementSection: some View {
        VStack(alignment: .leading) {
            Text("👥 Manage Users").font(.title2).bold()
            TextField("Search users", text: $searchQuery)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: searchQuery) { _ in filterUsers() }

            ForEach(filteredUsers.filter { !$0.suspended }, id: \.id) { user in
                HStack {
                    VStack(alignment: .leading) {
                        Text(user.name).bold()
                        if let username = user.username {
                            Text(username).font(.caption).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    if superadmins.contains(user.id) {
                        Text("Superadmin").foregroundColor(.green)
                    } else if admins.contains(user.id) {
                        Button("Remove Admin") {
                            updateAdminStatus(user.id, makeAdmin: false)
                        }.foregroundColor(.red)
                    } else {
                        Button("Make Admin") {
                            updateAdminStatus(user.id, makeAdmin: true)
                        }
                    }
                    Button("Suspend") {
                        suspendUser(user)
                    }.foregroundColor(.yellow)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }

    private func statCard(label: String, value: String) -> some View {
        VStack {
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(width: 100, height: 80)
        .background(Color.blue.opacity(0.2))
        .cornerRadius(12)
    }

    // MARK: - Logic Functions

    private func fetchPendingBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value) { snapshot in
            var brands: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key),
                   brand.approved == false {
                    brands.append(brand)
                }
            }
            self.pendingBrands = brands
        }
    }

    private func fetchUsers() {
        let ref = Database.database().reference().child("users")
        ref.observeSingleEvent(of: .value) { snapshot in
            var results: [DashboardUser] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any] {
                    let user = DashboardUser(
                        id: child.key,
                        name: dict["name"] as? String ?? "Unnamed",
                        username: dict["username"] as? String,
                        suspended: dict["suspended"] as? Bool ?? false
                    )
                    results.append(user)
                }
            }
            self.users = results
            self.filteredUsers = results
        }
    }

    private func fetchAdminList() {
        let ref = Database.database().reference().child("admins")
        ref.observeSingleEvent(of: .value) { snapshot in
            if let dict = snapshot.value as? [String: Bool] {
                self.admins = Set(dict.compactMap { $0.value ? $0.key : nil })
            }
        }
    }

    private func fetchSuperAdminList() {
        let ref = Database.database().reference().child("superadmin")
        ref.observeSingleEvent(of: .value) { snapshot in
            if let dict = snapshot.value as? [String: Bool] {
                self.superadmins = Set(dict.compactMap { $0.value ? $0.key : nil })
            }
        }
    }

    private func approveBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["approved": true])
        pendingBrands.removeAll { $0.id == brand.id }
    }

    private func suspendBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["suspended": true])
    }

    private func suspendUser(_ user: DashboardUser) {
        let ref = Database.database().reference().child("users").child(user.id)
        ref.updateChildValues(["suspended": true])
    }

    private func updateAdminStatus(_ userId: String, makeAdmin: Bool) {
        let ref = Database.database().reference().child("admins").child(userId)
        ref.setValue(makeAdmin)
        if makeAdmin {
            admins.insert(userId)
        } else {
            admins.remove(userId)
        }
    }

    private func filterUsers() {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            filteredUsers = users
        } else {
            filteredUsers = users.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    private func calculatePlatformStats() {
        let ref = Database.database().reference()
        ref.observeSingleEvent(of: .value) { snapshot in
            let userCount = snapshot.childSnapshot(forPath: "users").childrenCount
            let brandCount = snapshot.childSnapshot(forPath: "brands").childrenCount

            var approved = 0
            for case let child as DataSnapshot in snapshot.childSnapshot(forPath: "brands").children {
                if let dict = child.value as? [String: Any],
                   dict["approved"] as? Bool == true {
                    approved += 1
                }
            }

            self.platformStats = PlatformStats(
                totalUsers: Int(userCount),
                totalBrands: Int(brandCount),
                approvedBrands: approved
            )
        }
    }

    private func fetchRevenueStats() {
        let ref = Database.database().reference().child("paymentLogs")
        var total: Double = 0
        var monthly: Double = 0
        let currentMonth = Calendar.current.component(.month, from: Date())

        ref.observeSingleEvent(of: .value) { snapshot in
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let amount = dict["amount"] as? Double,
                   let timestamp = dict["timestamp"] as? TimeInterval {
                    total += amount
                    let date = Date(timeIntervalSince1970: timestamp)
                    if Calendar.current.component(.month, from: date) == currentMonth {
                        monthly += amount
                    }
                }
            }
            self.revenueStats = RevenueStats(
                monthly: Int(monthly),
                total: Int(total)
            )
        }
    }
}

// MARK: - Dashboard Models

struct DashboardUser: Identifiable {
    var id: String
    var name: String
    var username: String?
    var suspended: Bool
}

struct PlatformStats {
    var totalUsers: Int
    var totalBrands: Int
    var approvedBrands: Int

    static let empty = PlatformStats(totalUsers: 0, totalBrands: 0, approvedBrands: 0)
}

struct RevenueStats {
    var monthly: Int
    var total: Int

    static let empty = RevenueStats(monthly: 0, total: 0)
}
