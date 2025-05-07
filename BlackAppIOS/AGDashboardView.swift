// AGDashboardView.swift (Clean Fix: No ambiguity, all logic intact)

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
            VStack(alignment: .leading, spacing: 20) {
                Text("🛠️ Admin Dashboard")
                    .font(.largeTitle)
                    .bold()

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

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📊 Platform Stats").font(.title2).bold()
            HStack(spacing: 32) {
                statCard(label: "Total Users", value: "\(platformStats.totalUsers)")
                statCard(label: "Total Brands", value: "\(platformStats.totalBrands)")
                statCard(label: "Approved Brands", value: "\(platformStats.approvedBrands)")
            }
        }
    }

    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("💰 Revenue Overview").font(.title2).bold()
            Text("Monthly Revenue: $\(revenueStats.monthly)")
            Text("Total Revenue: $\(revenueStats.total)")
            Text("Real-time tracking from payment logs")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    private var brandApprovalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✅ Approve Pending Brands").font(.title2).bold()
            ForEach(pendingBrands.filter { $0.suspended != true }, id: \ .id) { brand in
                HStack {
                    Text(brand.name)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("👥 Manage Users").font(.title2).bold()

            TextField("Search users by name", text: $searchQuery)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: searchQuery, perform: { _ in
                    filterUsers()
                })

            ForEach(filteredUsers.filter { $0.suspended != true }, id: \ .id) { user in
                HStack {
                    VStack(alignment: .leading) {
                        Text(user.name).bold()
                        Text(user.username ?? "").font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    if superadmins.contains(user.id) {
                        Text("Superadmin")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else if admins.contains(user.id) {
                        Button("Remove Admin") { updateAdminStatus(user.id, makeAdmin: false) }
                            .foregroundColor(.red)
                    } else {
                        Button("Make Admin") { updateAdminStatus(user.id, makeAdmin: true) }
                    }
                    Button("Suspend") { suspendUser(user) }
                        .foregroundColor(.yellow)
                }
                .padding(8)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            }
        }
    }

    private func statCard(label: String, value: String) -> some View {
        VStack {
            Text(value)
                .font(.title)
                .bold()
                .foregroundColor(.green)
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(width: 100, height: 80)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func fetchPendingBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observeSingleEvent(of: .value) { snapshot in
            var results: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   var brand = BrandModel.from(dict: dict, id: child.key) {
                    brand.suspended = dict["suspended"] as? Bool ?? false
                    if brand.approved == false {
                        results.append(brand)
                    }
                }
            }
            self.pendingBrands = results
        }
    }

    private func fetchUsers() {
        let ref = Database.database().reference().child("users")
        ref.observeSingleEvent(of: .value) { snapshot in
            var allUsers: [DashboardUser] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any] {
                    let user = DashboardUser(id: child.key,
                                             name: dict["name"] as? String ?? "Unnamed",
                                             username: dict["username"] as? String,
                                             suspended: dict["suspended"] as? Bool ?? false)
                    allUsers.append(user)
                }
            }
            self.users = allUsers
            self.filteredUsers = allUsers
        }
    }

    private func filterUsers() {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredUsers = users
        } else {
            filteredUsers = users.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
    }

    private func fetchAdminList() {
        let ref = Database.database().reference().child("admin")
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
        logActivity("Approved brand: \(brand.name)")
        pendingBrands.removeAll { $0.id == brand.id }
    }

    private func suspendBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["suspended": true])
        logActivity("Suspended brand: \(brand.name)")
    }

    private func suspendUser(_ user: DashboardUser) {
        let ref = Database.database().reference().child("users").child(user.id)
        ref.updateChildValues(["suspended": true])
        logActivity("Suspended user: \(user.name)")
    }

    private func updateAdminStatus(_ userId: String, makeAdmin: Bool) {
        let ref = Database.database().reference().child("admin").child(userId)
        ref.setValue(makeAdmin)
        if makeAdmin {
            admins.insert(userId)
            logActivity("Granted admin rights to \(userId)")
        } else {
            admins.remove(userId)
            logActivity("Revoked admin rights from \(userId)")
        }
    }

    private func calculatePlatformStats() {
        let ref = Database.database().reference()
        ref.observeSingleEvent(of: .value) { snapshot in
            let totalUsers = snapshot.childSnapshot(forPath: "users").childrenCount
            let totalBrands = snapshot.childSnapshot(forPath: "brands").childrenCount

            var approved = 0
            for case let child as DataSnapshot in snapshot.childSnapshot(forPath: "brands").children {
                if let value = child.value as? [String: Any], value["approved"] as? Bool == true {
                    approved += 1
                }
            }

            self.platformStats = PlatformStats(
                totalUsers: Int(totalUsers),
                totalBrands: Int(totalBrands),
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
                if let log = child.value as? [String: Any],
                   let amount = log["amount"] as? Double,
                   let timestamp = log["timestamp"] as? TimeInterval {
                    total += amount
                    let date = Date(timeIntervalSince1970: timestamp)
                    if Calendar.current.component(.month, from: date) == currentMonth {
                        monthly += amount
                    }
                }
            }
            self.revenueStats = RevenueStats(monthly: Int(monthly), total: Int(total))
        }
    }

    private func logActivity(_ message: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("activityLogs").childByAutoId()
        let entry = ["adminId": uid, "message": message, "timestamp": ServerValue.timestamp()] as [String : Any]
        ref.setValue(entry)
    }
}

// MARK: - Models

struct DashboardUser: Identifiable {
    var id: String
    var name: String
    var username: String?
    var suspended: Bool?
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
