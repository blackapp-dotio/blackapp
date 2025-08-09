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
    @State private var showRevenueBreakdown = false // 👈 NEW
    @State private var supportMessages: [SupportMessage] = []
    @State private var expandedMessageId: String? = nil
    @State private var unreadCount: Int = 0

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
                if selectedTile == "revenue" {
                    revenueSection
                    if showRevenueBreakdown {
                        revenueDetailBreakdown
                    }
                    revenueChartSection
                }
                if selectedTile == "supportInbox" {
                    supportInboxSection
                }
                
                supportTileSection // ✅ new support dashboard area

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
            fetchMonthlyBreakdown()
            fetchSupportMessages()
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
            dashboardTile("Support Inbox", value: "\(supportMessages.count)", tag: "supportInbox")
            
        }
    }
    
    private var supportTileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Support")
                .font(.headline)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Support Inbox")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.white)
                        Text("\(unreadCount) unread")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)

                NavigationLink(destination: SupportBoardView()) {
                    HStack {
                        Text("Open Support Dashboard")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal)
        }
    }

    private func dashboardTile(_ title: String, value: String, tag: String) -> some View {
        Button(action: {
            selectedTile = tag
            
            switch tag {
            case "users":
                fetchUsers()
                fetchAdminList()
                fetchSuperAdminList()
            case "approvedBrands":
                fetchAllBrands()
            case "pendingBrands":
                fetchAllBrands()
            case "suspendedBrands":
                fetchAllBrands()
            case "supportInbox":
                fetchSupportMessages()
            case "revenue":
                fetchRevenueStats()
                fetchMonthlyBreakdown()
            default:
                break
            }
        }) {
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
            Text("Revenue Report")
                .font(.title2)
                .bold()
            
            Button(action: {
                withAnimation {
                    showRevenueBreakdown.toggle()
                }
            }) {
                HStack {
                    Text(showRevenueBreakdown ? "Hide Breakdown" : "Show Breakdown")
                        .foregroundColor(.blue)
                    Spacer()
                    Image(systemName: showRevenueBreakdown ? "chevron.up" : "chevron.down")
                        .foregroundColor(.blue)
                }
                .padding(.vertical, 6)
            }
            
            Text("Platform Earnings: $\(revenueStats.platformEarnings)")
                .foregroundColor(.blue)
            
            Text("Total Sales: $\(revenueStats.total)")
                .foregroundColor(.green)
        }
    }
    
    private var revenueDetailBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(Color.gray)
            Text("💡 Revenue Breakdown")
                .font(.headline)
                .padding(.bottom, 4)
            
            Group {
                Text("🟢 Event Ticket Sales")
                    .bold()
                Text("• Gross Revenue: $\(revenueStats.total)")
                Text("• Platform Fee (2%): $\(revenueStats.platformEarnings)")
                Text("• Net to Sellers: $\(revenueStats.total - revenueStats.platformEarnings)")
            }
            .font(.caption)
            .padding(.leading, 4)
            
            Divider().background(Color.gray)
            
            Text("🧠 More insights like brand revenue and tips will appear here soon.")
                .font(.footnote)
                .foregroundColor(.gray)
        }
        .padding(.top, 4)
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
    private var supportInboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("📥 Support Inbox")
                .font(.title2)
                .bold()
                .padding(.horizontal)
            
            if supportMessages.isEmpty {
                Text("No support messages yet.")
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            } else {
                ForEach(supportMessages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: {
                            withAnimation {
                                expandedMessageId = expandedMessageId == message.id ? nil : message.id
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("🧑‍💻 User: \(message.userId.prefix(6))")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                    
                                    Text("📩 \(message.text.prefix(50))...")
                                        .font(.body)
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Image(systemName: expandedMessageId == message.id ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.white)
                            }
                            .padding()
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(10)
                        }
                        
                        if expandedMessageId == message.id {
                            VStack(alignment: .leading, spacing: 8) {
                                Divider()
                                Text("📬 Full Message:")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                
                                Text(message.text)
                                    .font(.body)
                                    .foregroundColor(.white)
                                
                                Text("🕒 \(formattedDate(from: message.timestamp))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                
                                Picker("Status", selection: Binding<String>(
                                    get: { message.status ?? "Backlog" },
                                    set: { newStatus in
                                        updateSupportMessageStatus(messageId: message.id, newStatus: newStatus)
                                    }
                                )) {
                                    ForEach(["Backlog", "Started", "In Progress", "Resolved"], id: \.self) {
                                        Text($0)
                                    }
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .padding(.top)
                            }
                            .padding()
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
    private func formattedDate(from timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
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
    
    // MARK: - Fetch Monthly Breakdown
    
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
    
    // MARK: - Suspend User
    
    private func suspendUser(_ user: DashboardUser) {
        let ref = Database.database().reference().child("users").child(user.id)
        ref.updateChildValues(["suspended": true])
    }
    
    // MARK: - Admin Status Update
    
    private func updateAdminStatus(_ userId: String, makeAdmin: Bool) {
        let ref = Database.database().reference().child("admins").child(userId)
        ref.setValue(makeAdmin)
        if makeAdmin {
            admins.insert(userId)
        } else {
            admins.remove(userId)
        }
    }
    
    // MARK: - Filter Users
    
    private func filterUsers() {
        filteredUsers = searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        ? users
        : users.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }
    
    // MARK: - Calculate Platform Stats
    
    private func calculatePlatformStats() {
        let ref = Database.database().reference()
        ref.observe(.value) { snapshot in
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
    
    // MARK: - Fetch Revenue Stats
    
    private func fetchRevenueStats() {
        guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/getPlatformRevenue") else {
            print("❌ Invalid URL for getPlatformRevenue")
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("❌ Network error while fetching revenue stats: \(error.localizedDescription)")
                return
            }
            
            guard let data = data else {
                print("❌ No data returned from revenue endpoint")
                return
            }
            
            do {
                struct RevenueResponse: Decodable {
                    let platformEarnings: String
                    let totalRevenue: String
                    let ticketsSold: Int
                    let totalEvents: Int
                }
                
                let decoded = try JSONDecoder().decode(RevenueResponse.self, from: data)
                
                DispatchQueue.main.async {
                    let totalRevenue = Double(decoded.totalRevenue) ?? 0.0
                    let platformEarnings = Double(decoded.platformEarnings) ?? 0.0
                    
                    self.revenueStats = RevenueStats(
                        monthly: 0, // Replace later if needed
                        total: totalRevenue,
                        platformEarnings: platformEarnings
                    )
                    
                    print("✅ Revenue updated: total=\(totalRevenue), earnings=\(platformEarnings)")
                }
            } catch {
                print("❌ Failed to decode revenue response: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Fetch Support Messages
    
    private func fetchSupportMessages() {
        let ref = Database.database().reference().child("supportMessages")
        
        ref.observeSingleEvent(of: .value) { snapshot in
            var messages: [SupportMessage] = []
            var unread = 0
            
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let message = dict["message"] as? String,
                   let timestamp = dict["timestamp"] as? TimeInterval,
                   let userId = dict["userId"] as? String {

                    let name = dict["name"] as? String
                    let email = dict["email"] as? String
                    let status = dict["status"] as? String ?? "unread"
                    let safeName = name ?? "Unknown"
                    let safeEmail = email ?? "N/A"

                    if status == "unread" {
                        unread += 1
                    }

                    messages.append(SupportMessage(
                        id: child.key,
                        userId: userId,
                        text: message,
                        timestamp: timestamp,
                        status: status,       // 👈 Correct order
                        name: safeName,
                        email: safeEmail
                    ))
                }
            }

            DispatchQueue.main.async {
                self.supportMessages = messages.sorted { $0.timestamp > $1.timestamp }
                self.unreadCount = unread
                print("✅ Loaded \(messages.count) support messages | \(unread) unread")
            }
        }
    }



    
    // MARK: - Update Support Message Status
    
    private func updateSupportMessageStatus(messageId: String, newStatus: String) {
        let ref = Database.database().reference().child("supportMessages").child(messageId)
        
        ref.updateChildValues(["status": newStatus]) { error, _ in
            if let error = error {
                print("❌ Failed to update status: \(error.localizedDescription)")
            } else {
                print("✅ Support message status updated to: \(newStatus)")
                fetchSupportMessages()
            }
        }
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
        var total: Double
        var platformEarnings: Double
        
        static let empty = RevenueStats(monthly: 0, total: 0.0, platformEarnings: 0.0)
    }
    
    struct AGMonthlyRevenue {
        var month: String
        var value: Double
    }
    
    struct SupportMessage: Identifiable {
        var id: String
        var userId: String
        var text: String
        var timestamp: TimeInterval
        var status: String
        var name: String
        var email: String
    }
}

