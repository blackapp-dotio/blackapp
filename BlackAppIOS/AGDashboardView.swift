import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions
import Charts

struct AGDashboardView: View {
    // ===== Existing State =====
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
    @State private var showRevenueBreakdown = false
    @State private var supportMessages: [SupportMessage] = []
    @State private var expandedMessageId: String? = nil
    @State private var unreadCount: Int = 0

    struct MonthlyRevenue: Identifiable {
        let id = UUID()
        let month: String
        let value: Double
    }

    // ===== Nightlife Approvals State =====
    enum NLType: String, CaseIterable { case promoter, venue }
    enum NLStatus: String, CaseIterable { case pending = "pending", approved = "approved", rejected = "rejected" }

    struct NightlifeApplication: Identifiable {
        var id: String { uid }
        let uid: String
        let type: NLType
        let fullName: String
        let email: String
        let phone: String
        let businessName: String
        let website: String?
        let instagram: String?
        let tiktok: String?
        let description: String?
        let status: NLStatus
        let submittedAt: TimeInterval?
    }

    @State private var nlSelectedType: NLType = .promoter
    @State private var nlSelectedStatus: NLStatus = .pending
    @State private var promoterApps: [NightlifeApplication] = []
    @State private var venueApps: [NightlifeApplication] = []
    @State private var nlIsLoading = false
    @State private var nlError: String?
    @State private var pendingCountTotal = 0

    // Venue approval sheet
    @State private var showVenueApprovalSheet = false
    @State private var venueApprovalTargetUid: String?
    @State private var approvalVenueId: String = ""
    @State private var approvalVenueName: String = ""
    @State private var approvalVenueAddress: String = ""

    // Reject reason sheet
    @State private var showRejectReasonSheet = false
    @State private var rejectTarget: (NLType, String)?
    @State private var rejectReason: String = ""

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
                    if showRevenueBreakdown { revenueDetailBreakdown }
                    revenueChartSection
                }
                if selectedTile == "supportInbox" {
                    supportInboxSection
                }

                // Nightlife approvals screen
                if selectedTile == "nightlifeApprovals" {
                    nightlifeApprovalsSection
                }

                supportTileSection
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
            refreshNightlifePendingCounts()
        }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
        // Sheets
        .sheet(isPresented: $showVenueApprovalSheet) {
            VenueApprovalSheet(
                uid: venueApprovalTargetUid ?? "",
                venueId: $approvalVenueId,
                name: $approvalVenueName,
                address: $approvalVenueAddress,
                onCancel: { showVenueApprovalSheet = false },
                onApprove: { uid, venueId, name, address in
                    approveVenue(uid: uid, venueId: venueId, name: name, address: address)
                    showVenueApprovalSheet = false
                }
            )
        }
        .sheet(isPresented: $showRejectReasonSheet) {
            RejectReasonSheet(
                reason: $rejectReason,
                onCancel: { showRejectReasonSheet = false; rejectReason = "" },
                onSubmit: {
                    if let (type, uid) = rejectTarget {
                        rejectApplication(type: type, uid: uid, reason: rejectReason)
                    }
                    showRejectReasonSheet = false
                    rejectReason = ""
                }
            )
        }
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
            dashboardTile("Nightlife Approvals", value: "\(pendingCountTotal)", tag: "nightlifeApprovals")
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

            case "approvedBrands", "pendingBrands", "suspendedBrands":
                fetchAllBrands()

            case "supportInbox":
                fetchSupportMessages()

            case "revenue":
                fetchRevenueStats()
                fetchMonthlyBreakdown()

            case "nightlifeApprovals":
                nlSelectedType = .promoter
                nlSelectedStatus = .pending
                fetchNightlifeApplications(type: .promoter, status: .pending)
                fetchNightlifeApplications(type: .venue, status: .pending)

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
            ForEach(pendingBrands, id: \.id) { brand in
                brandRow(brand, showApprove: true, showSuspend: true)
            }
        }
    }

    private var approvedBrandSection: some View {
        VStack(alignment: .leading) {
            Text("Approved Brands").font(.title2).bold()
            ForEach(approvedBrands, id: \.id) { brand in
                brandRow(brand, showSuspend: true, showDelete: true)
            }
        }
    }

    private var suspendedBrandSection: some View {
        VStack(alignment: .leading) {
            Text("Suspended Brands").font(.title2).bold()
            ForEach(suspendedBrands, id: \.id) { brand in
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

            ForEach(filteredUsers, id: \.id) { user in
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
                withAnimation { showRevenueBreakdown.toggle() }
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
                                    get: { message.status },
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

    private func formattedDate(from timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    // MARK: - Nightlife Approvals UI

    private var nightlifeApprovalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nightlife Approvals").font(.title2).bold()
                Spacer()
                if nlIsLoading { ProgressView() }
            }

            // Type toggle
            Picker("Type", selection: $nlSelectedType) {
                Text("Promoters").tag(NLType.promoter)
                Text("Venues").tag(NLType.venue)
            }
            .pickerStyle(.segmented)
            .onChange(of: nlSelectedType) { _ in
                fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            }

            // Status filter
            Picker("Status", selection: $nlSelectedStatus) {
                Text("Pending").tag(NLStatus.pending)
                Text("Approved").tag(NLStatus.approved)
                Text("Rejected").tag(NLStatus.rejected)
            }
            .pickerStyle(.segmented)
            .onChange(of: nlSelectedStatus) { _ in
                fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            }

            if let err = nlError {
                Text(err).foregroundColor(.red)
            }

            let items = nlSelectedType == .promoter ? promoterApps : venueApps

            if items.isEmpty {
                Text("No \(nlSelectedStatus.rawValue) \(nlSelectedType.rawValue)s.")
                    .foregroundColor(.gray)
                    .padding(.top, 8)
            } else {
                ForEach(items) { app in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(app.businessName.isEmpty ? app.fullName : app.businessName)
                                .font(.headline)
                            Spacer()
                            StatusPill(text: app.status.rawValue)   // <-- label fixed
                        }
                        Text("\(app.fullName) • \(app.email) • \(app.phone)")
                            .font(.caption)
                            .foregroundColor(.gray)
                        if let d = app.description, !d.isEmpty {
                            Text(d).font(.footnote).foregroundColor(.secondary)
                        }

                        HStack(spacing: 10) {
                            if nlSelectedStatus == .pending {
                                if app.type == .promoter {
                                    Button("Approve") { approvePromoter(uid: app.uid) }
                                        .buttonStyle(.borderedProminent)
                                    Button("Reject") {
                                        rejectTarget = (.promoter, app.uid)
                                        showRejectReasonSheet = true
                                    }.foregroundColor(.red)
                                } else {
                                    Button("Approve") {
                                        venueApprovalTargetUid = app.uid
                                        approvalVenueId = ""
                                        approvalVenueName = app.businessName
                                        approvalVenueAddress = ""
                                        showVenueApprovalSheet = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button("Reject") {
                                        rejectTarget = (.venue, app.uid)
                                        showRejectReasonSheet = true
                                    }.foregroundColor(.red)
                                }
                            } else {
                                Button("View") { /* optional future detail */ }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Firebase Logic (Existing)

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

        URLSession.shared.dataTask(with: url) { data, _, error in
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
                        monthly: 0,
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
                        status: status,
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

    // MARK: - Nightlife Approvals: Function Calls (FIXED to use .call)

    private func functions() -> Functions {
        Functions.functions()
    }

    private func fetchNightlifeApplications(type: NLType, status: NLStatus, limit: Int = 100) {
        nlIsLoading = true
        nlError = nil
        let fn = functions().httpsCallable("listNightlifeApplications")
        fn.call([
            "type": type.rawValue,
            "status": status.rawValue,
            "limit": limit
        ]) { result, error in
            nlIsLoading = false
            if let error = error {
                nlError = "Failed to load: \(error.localizedDescription)"
                return
            }
            guard
                let data = result?.data as? [String: Any],
                let arr = data["items"] as? [[String: Any]]
            else { return }

            let mapped: [NightlifeApplication] = arr.compactMap { dict in
                guard let uid = dict["uid"] as? String else { return nil }
                let fullName = dict["fullName"] as? String ?? ""
                let email = dict["email"] as? String ?? ""
                let phone = dict["phone"] as? String ?? ""
                let businessName = dict["businessName"] as? String ?? ""
                let website = dict["website"] as? String
                let instagram = dict["instagram"] as? String
                let tiktok = dict["tiktok"] as? String
                let desc = dict["description"] as? String
                let st = NLStatus(rawValue: (dict["status"] as? String ?? "pending")) ?? .pending
                let submittedAt = dict["submittedAt"] as? TimeInterval
                return NightlifeApplication(
                    uid: uid,
                    type: type,
                    fullName: fullName,
                    email: email,
                    phone: phone,
                    businessName: businessName,
                    website: website,
                    instagram: instagram,
                    tiktok: tiktok,
                    description: desc,
                    status: st,
                    submittedAt: submittedAt
                )
            }

            DispatchQueue.main.async {
                if type == .promoter {
                    self.promoterApps = mapped
                } else {
                    self.venueApps = mapped
                }
                refreshNightlifePendingCounts()
            }
        }
    }

    private func refreshNightlifePendingCounts() {
        let cached = promoterApps.filter { $0.status == .pending }.count
                    + venueApps.filter { $0.status == .pending }.count
        if cached > 0 {
            self.pendingCountTotal = cached
            return
        }

        let fn = functions().httpsCallable("listNightlifeApplications")
        let group = DispatchGroup()
        var pCount = 0, vCount = 0

        group.enter()
        fn.call(["type": "promoter", "status": "pending", "limit": 200]) { res, _ in
            defer { group.leave() }
            if let data = res?.data as? [String: Any], let arr = data["items"] as? [[String: Any]] { pCount = arr.count }
        }

        group.enter()
        fn.call(["type": "venue", "status": "pending", "limit": 200]) { res, _ in
            defer { group.leave() }
            if let data = res?.data as? [String: Any], let arr = data["items"] as? [[String: Any]] { vCount = arr.count }
        }

        group.notify(queue: .main) {
            self.pendingCountTotal = pCount + vCount
        }
    }

    private func approvePromoter(uid: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": "promoter", "uid": uid, "action": "approve"]) { _, error in
            if let error = error {
                print("❌ approvePromoter:", error.localizedDescription)
                return
            }
            print("✅ Promoter approved:", uid)
            fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            refreshNightlifePendingCounts()
        }
    }

    private func approveVenue(uid: String, venueId: String, name: String?, address: String?) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call([
            "type": "venue",
            "uid": uid,
            "action": "approve",
            "venue": ["venueId": venueId, "name": name ?? "", "address": address ?? ""]
        ]) { _, error in
            if let error = error {
                print("❌ approveVenue:", error.localizedDescription)
                return
            }
            print("✅ Venue approved:", uid, "→", venueId)
            fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            refreshNightlifePendingCounts()
        }
    }

    private func rejectApplication(type: NLType, uid: String, reason: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": type.rawValue, "uid": uid, "action": "reject", "reason": reason]) { _, error in
            if let error = error {
                print("❌ rejectApplication:", error.localizedDescription)
                return
            }
            print("✅ Application rejected:", type.rawValue, uid)
            fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            refreshNightlifePendingCounts()
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

// MARK: - Helper UI Bits

private struct StatusPill: View {
    let text: String
    var color: Color {
        switch text {
        case "approved": return .green
        case "pending": return .orange
        case "rejected": return .red
        default: return .gray
        }
    }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct VenueApprovalSheet: View {
    let uid: String
    @Binding var venueId: String
    @Binding var name: String
    @Binding var address: String
    var onCancel: () -> Void
    var onApprove: (_ uid: String, _ venueId: String, _ name: String?, _ address: String?) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Venue Mapping")) {
                    TextField("Venue ID (required)", text: $venueId)
                    TextField("Venue Name (optional)", text: $name)
                    TextField("Venue Address (optional)", text: $address)
                }
                Section {
                    Button("Approve") {
                        guard !venueId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        onApprove(uid, venueId, name.isEmpty ? nil : name, address.isEmpty ? nil : address)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { onCancel() }
                }
            }
            .navigationTitle("Approve Venue")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct RejectReasonSheet: View {
    @Binding var reason: String
    var onCancel: () -> Void
    var onSubmit: () -> Void
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Reason")) {
                    TextEditor(text: $reason).frame(minHeight: 120)
                }
                Section {
                    Button("Submit Rejection") { onSubmit() }.foregroundColor(.red)
                    Button("Cancel", role: .cancel) { onCancel() }
                }
            }
            .navigationTitle("Reject Application")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
