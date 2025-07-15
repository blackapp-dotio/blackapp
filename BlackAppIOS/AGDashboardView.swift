import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import Charts

struct AGDashboardView: View {
    @State private var pendingBrands: [BrandModel] = []
    @State private var approvedBrands: [BrandModel] = []
    @State private var suspendedBrands: [BrandModel] = []
    @State private var users: [DashboardUser] = []
    @State private var filteredUsers: [DashboardUser] = []
    @State private var searchQuery: String = ""
    @State private var admins: Set<String> = []
    @State private var superadmins: Set<String> = []
    @State private var platformStats: PlatformStats = .empty
    @State private var revenueStats: RevenueStats = .empty
    @State private var selectedTile: String? = nil
    @State private var monthlyBreakdown: [MonthlyRevenue] = []


    struct MonthlyRevenue: Identifiable {
        let id = UUID()
        let month: String
        let value: Double
    }

    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AG Dashboard")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)
                
                tileGridSection
                
                if selectedTile == "users" { userManagementSection }
                if selectedTile == "pendingBrands" { brandApprovalSection }
                if selectedTile == "approvedBrands" { approvedBrandSection }
                if selectedTile == "suspendedBrands" { suspendedBrandSection }
                if selectedTile == "revenue" { revenueSection }
                if selectedTile == "revenue" {
                    revenueSection
                    revenueChartSection
                }
            }
            .padding()
        }
        .onAppear {
            fetchAllBrands()
            fetchUsers()
            fetchAdminList()
            fetchSuperAdminList()
            calculatePlatformStats()
            fetchRevenueStats()
            fetchMonthlyBreakdown() // 👈 Add this here
        }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
    }
    
    // MARK: - Tile Grid
    
    private var tileGridSection: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 2), spacing: 20) {
            dashboardTile("Users", value: "\(platformStats.totalUsers)", tag: "users")
            dashboardTile("Brands", value: "\(platformStats.totalBrands)", tag: "approvedBrands")
            dashboardTile("Pending Brands", value: "\(pendingBrands.count)", tag: "pendingBrands")
            dashboardTile("Suspended Brands", value: "\(suspendedBrands.count)", tag: "suspendedBrands")
            dashboardTile("Revenue", value: "$\(revenueStats.total)", tag: "revenue")
        }
    }
    
    private func dashboardTile(_ title: String, value: String, tag: String) -> some View {
        Button(action: { selectedTile = tag }) {
            VStack(spacing: 8) {
                Text(value).font(.title).bold().foregroundColor(.white)
                Text(title).font(.caption).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Color.blue.opacity(0.2))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Brand Sections
    
    private var brandApprovalSection: some View {
        VStack(alignment: .leading) {
            Text("Pending Brand Approvals").font(.title2).bold()
            ForEach(pendingBrands, id: \..id) { brand in
                brandRow(brand, showApprove: true, showSuspend: true)
            }
        }
    }
    
    private var approvedBrandSection: some View {
        VStack(alignment: .leading) {
            Text("Approved Brands").font(.title2).bold()
            ForEach(approvedBrands, id: \..id) { brand in
                brandRow(brand, showSuspend: true, showDelete: true)
            }
        }
    }
    
    private var suspendedBrandSection: some View {
        VStack(alignment: .leading) {
            Text("Suspended Brands").font(.title2).bold()
            ForEach(suspendedBrands, id: \..id) { brand in
                brandRow(brand, showApprove: true, showDelete: true)
            }
        }
    }
    
    private func brandRow(_ brand: BrandModel, showApprove: Bool = false, showSuspend: Bool = false, showDelete: Bool = false) -> some View {
        HStack {
            Text(brand.name).bold().foregroundColor(.white)
            Spacer()
            if showApprove { Button("Approve") { approveBrand(brand) }.buttonStyle(.borderedProminent) }
            if showSuspend { Button("Suspend") { suspendBrand(brand) }.foregroundColor(.yellow) }
            if showDelete { Button("Delete") { deleteBrand(brand) }.foregroundColor(.red) }
        }
        .padding(8)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }
    
    private var userManagementSection: some View {
        VStack(alignment: .leading) {
            Text("Manage Users").font(.title2).bold()
            TextField("Search users", text: $searchQuery)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: searchQuery) { _ in filterUsers() }
            
            ForEach(filteredUsers, id: \..id) { user in
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
                        Button("Remove Admin") { updateAdminStatus(user.id, makeAdmin: false) }.foregroundColor(.red)
                    } else {
                        Button("Make Admin") { updateAdminStatus(user.id, makeAdmin: true) }
                    }
                    Button("Suspend") { suspendUser(user) }.foregroundColor(.yellow)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
        }
    }
    
    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Revenue Report").font(.title2).bold()
            Text("Platform Earnings: $\(revenueStats.platformEarnings)").foregroundColor(.blue)
            Text("Monthly Sales: $\(revenueStats.monthly)")
            Text("Total Sales: $\(revenueStats.total)").foregroundColor(.green)
            
        }
    }
    
    private var revenueChartSection: some View {
        VStack(alignment: .leading) {
            Text("Monthly Revenue Chart")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)

            Chart(monthlyBreakdown) {
                BarMark(
                    x: .value("Month", $0.month),
                    y: .value("Revenue", $0.value)
                )
                .foregroundStyle(.blue.gradient)
            }
            .frame(height: 200)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    // MARK: - Firebase Logic
    
    private func fetchAllBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observe(.value) { snapshot in
            var pending: [BrandModel] = []
            var approved: [BrandModel] = []
            var suspended: [BrandModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let brand = BrandModel.from(dict: dict, id: child.key) {
                    if brand.suspended {
                        suspended.append(brand)
                    } else if brand.approved {
                        approved.append(brand)
                    } else {
                        pending.append(brand)
                    }
                }
            }
            self.pendingBrands = pending
            self.approvedBrands = approved
            self.suspendedBrands = suspended
        }
    }
    
    private func approveBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["approved": true, "suspended": false])
    }
    
    private func suspendBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["suspended": true])
    }
    
    private func deleteBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.removeValue()
    }
    
    private func fetchUsers() {
        let ref = Database.database().reference().child("users")
        ref.observe(.value) { snapshot in
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
        ref.observe(.value) { snapshot in
            if let dict = snapshot.value as? [String: Bool] {
                self.admins = Set(dict.compactMap { $0.value ? $0.key : nil })
            }
        }
    }
    
    private func fetchSuperAdminList() {
        let ref = Database.database().reference().child("superadmin")
        ref.observe(.value) { snapshot in
            if let dict = snapshot.value as? [String: Bool] {
                self.superadmins = Set(dict.compactMap { $0.value ? $0.key : nil })
            }
        }
    }
    
    private func fetchMonthlyBreakdown() {
        let ref = Database.database().reference().child("purchases")
        var monthlyTotals: [Int: Double] = [:]

        ref.observeSingleEvent(of: .value) { snapshot in
            for case let userSnap as DataSnapshot in snapshot.children {
                for case let purchaseSnap as DataSnapshot in userSnap.children {
                    if let dict = purchaseSnap.value as? [String: Any],
                       let amount = dict["totalAmount"] as? Double,
                       let timestamp = dict["timestamp"] as? TimeInterval {
                        let date = Date(timeIntervalSince1970: timestamp)
                        let monthIndex = Calendar.current.component(.month, from: date)
                        monthlyTotals[monthIndex, default: 0] += amount
                    }
                }
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "MMM"

            var chartData: [MonthlyRevenue] = []

            for month in 1...12 {
                let monthName = formatter.shortMonthSymbols[month - 1]
                let value = monthlyTotals[month] ?? 0
                chartData.append(MonthlyRevenue(month: monthName, value: value))
            }

            DispatchQueue.main.async {
                self.monthlyBreakdown = chartData
            }
        }
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
        filteredUsers = searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? users : users.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }
    
    private func calculatePlatformStats() {
        let ref = Database.database().reference()
        ref.observe(.value) { snapshot in
            let userCount = snapshot.childSnapshot(forPath: "users").childrenCount
            let brandCount = snapshot.childSnapshot(forPath: "brands").childrenCount
            
            var approved = 0
            for case let child as DataSnapshot in snapshot.childSnapshot(forPath: "brands").children {
                if let dict = child.value as? [String: Any], dict["approved"] as? Bool == true {
                    approved += 1
                }
            }
            self.platformStats = PlatformStats(totalUsers: Int(userCount), totalBrands: Int(brandCount), approvedBrands: approved)
        }
    }
    
    private func fetchRevenueStats() {
        guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/getPlatformRevenue") else { return }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let total = Int((json["totalRevenue"] as? String ?? "0")) ?? 0
                        let earnings = Int((json["platformEarnings"] as? String ?? "0")) ?? 0
                        let monthly = 0 // Optional: implement later if backend supports monthly breakdown
                        
                        DispatchQueue.main.async {
                            self.revenueStats = RevenueStats(monthly: monthly, total: total, platformEarnings: earnings)
                        }
                    }
                } catch {
                    print("❌ Revenue parsing error: \(error)")
                }
            } else if let error = error {
                print("❌ Network error while fetching revenue stats: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Models
    
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
        var platformEarnings: Int
        
        static let empty = RevenueStats(monthly: 0, total: 0, platformEarnings: 0)
    }
}
