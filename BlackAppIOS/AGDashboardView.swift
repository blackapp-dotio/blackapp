import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions
import Charts
import UIKit

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
    @State private var showManageSheet = false
    @State private var manageTarget: NightlifeApplication?
    @State private var actionBusy = false
    @State private var actionError: String?
    
    // ===== Platform fee (single source of truth) =====
    private let PLATFORM_FEE_RATE: Double = 0.05
    private var platformFeePercentLabel: String { "\(Int(PLATFORM_FEE_RATE * 100))%" }

    struct MonthlyRevenue: Identifiable {
        let id = UUID()
        let month: String
        let value: Double
    }

    // ===== Nightlife Approvals State =====
    enum NLType: String, CaseIterable { case promoter, venue, entertainer }
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
        let suspended: Bool
        let submittedAt: TimeInterval?
    }

    @State private var nlSelectedType: NLType = .promoter
    @State private var nlSelectedStatus: NLStatus = .pending
    @State private var promoterApps: [NightlifeApplication] = []
    @State private var venueApps: [NightlifeApplication] = []
    @State private var entertainerApps: [NightlifeApplication] = []
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
        
        .sheet(isPresented: $showManageSheet) {
            if let app = manageTarget {
                NightlifeManageSheet(
                    app: app,
                    busy: $actionBusy,
                    error: $actionError,
                    onApprove: {
                        switch app.type {
                        case .promoter:    approvePromoter(uid: app.uid)
                        case .entertainer: approveEntertainer(uid: app.uid)
                        case .venue:
                            venueApprovalTargetUid = app.uid
                            approvalVenueId = ""
                            approvalVenueName = app.businessName
                            approvalVenueAddress = ""
                            showVenueApprovalSheet = true
                        }
                    },
                    onReject: { reason in
                        rejectApplication(type: app.type, uid: app.uid, reason: reason)
                    },
                    onSuspend: {
                        suspend(type: app.type, uid: app.uid)
                    },
                    onReinstate: {
                        reinstate(type: app.type, uid: app.uid)
                    },
                    onCopyUID: {
                        UIPasteboard.general.string = app.uid
                    },
                    onEmail: {
                        if let url = URL(string: "mailto:\(app.email)") {
                            UIApplication.shared.open(url)
                        }
                    },
                    onCall: {
                        let phone = app.phone.replacingOccurrences(of: " ", with: "")
                        if let url = URL(string: "tel:\(phone)") {
                            UIApplication.shared.open(url)
                        }
                    }
                )
                .preferredColorScheme(ColorScheme.dark)   // <-- explicit type to fix the .dark error
            } else {
                EmptyView().preferredColorScheme(ColorScheme.dark)
            }
        }
        // ⬇️ ADD THIS to close `var body`:
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
                fetchNightlifeApplications(type: .entertainer, status: .pending) // NEW

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
    
    private func suspendBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.updateChildValues(["suspended": true])
    }

    private func deleteBrand(_ brand: BrandModel) {
        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.removeValue()
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
                Text("• Platform Fee (\(platformFeePercentLabel)): $\(revenueStats.platformEarnings)")
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
                Text("Entertainers").tag(NLType.entertainer)
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

            let items: [NightlifeApplication] = {
                switch nlSelectedType {
                case .promoter:    return promoterApps
                case .venue:       return venueApps
                case .entertainer: return entertainerApps
                }
            }()

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
                            StatusPill(text: app.status.rawValue)
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
                                } else if app.type == .venue {
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
                                } else {
                                    Button("Approve") { approveEntertainer(uid: app.uid) }
                                        .buttonStyle(.borderedProminent)
                                    Button("Reject") {
                                        rejectTarget = (.entertainer, app.uid)
                                        showRejectReasonSheet = true
                                    }.foregroundColor(.red)
                                }
                            } else if nlSelectedStatus == .approved {
                                // Suspend/ Reinstate toggles for approved items
                                if app.suspended {
                                    Button("Reinstate") { reinstate(type: app.type, uid: app.uid) }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("Suspend") { suspend(type: app.type, uid: app.uid) }
                                        .foregroundColor(.yellow)
                                }
                                Button("View") {
                                    manageTarget = app
                                    showManageSheet = true
                                }
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

        private func suspend(type: NLType, uid: String) {
            let fn = functions().httpsCallable("reviewNightlifeApplication")
            fn.call(["type": type.rawValue, "uid": uid, "action": "suspend"]) { _, error in
                if let error = error as NSError? {
                    print("❌ suspend [\(error.domain):\(error.code)] \(error.localizedDescription) details=\(error.userInfo[FunctionsErrorDetailsKey] ?? "nil")")
                    self.actionError = error.localizedDescription
                }
                self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
                self.refreshNightlifePendingCounts()
                self.actionBusy = false
            }
        }

        private func reinstate(type: NLType, uid: String) {
            let fn = functions().httpsCallable("reviewNightlifeApplication")
            fn.call(["type": type.rawValue, "uid": uid, "action": "reinstate"]) { _, error in
                if let error = error as NSError? {
                    print("❌ reinstate [\(error.domain):\(error.code)] \(error.localizedDescription) details=\(error.userInfo[FunctionsErrorDetailsKey] ?? "nil")")
                    self.actionError = error.localizedDescription
                }
                self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
                self.refreshNightlifePendingCounts()
                self.actionBusy = false
            }
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

        ref.observe(.value) { snapshot in
            var monthlyTotals: [Int: Double] = [:]  // 1..12
            var runningTotal: Double = 0

            for case let userSnap as DataSnapshot in snapshot.children {
                for case let purchaseSnap as DataSnapshot in userSnap.children {
                    guard let dict = purchaseSnap.value as? [String: Any] else { continue }

                    let rawAmount = dict["totalAmount"]
                    let amount: Double = (rawAmount as? Double)
                        ?? (rawAmount as? NSNumber)?.doubleValue
                        ?? Double(rawAmount as? String ?? "") ?? 0.0

                    let ts = (dict["timestamp"] as? TimeInterval)
                          ?? (dict["createdAt"] as? TimeInterval)
                          ?? 0

                    runningTotal += amount

                    if ts > 0 {
                        let date = Date(timeIntervalSince1970: ts)
                        let monthIndex = Calendar.current.component(.month, from: date) // 1..12
                        monthlyTotals[monthIndex, default: 0] += amount
                    }
                }
            }

            // Build chart data (Jan..Dec)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "MMM"

            var chartData: [MonthlyRevenue] = []
            for month in 1...12 {
                let name = formatter.shortMonthSymbols[month - 1]
                let value = monthlyTotals[month] ?? 0
                chartData.append(MonthlyRevenue(month: name, value: value))
            }

            let platformEarnings = runningTotal * PLATFORM_FEE_RATE

            DispatchQueue.main.async {
                self.monthlyBreakdown = chartData
                // Live update top-line to reflect DB changes immediately
                self.revenueStats = RevenueStats(
                    monthly: 0,
                    total: runningTotal,
                    platformEarnings: platformEarnings
                )
                print("📊 Live revenue: total=\(runningTotal), fee(\(platformFeePercentLabel))=\(platformEarnings)")
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
        let fn = functions().httpsCallable("getPlatformRevenue")
        fn.call([:]) { result, error in
            if let error = error {
                print("❌ getPlatformRevenue (callable):", error.localizedDescription)
                return
            }
            guard let dict = result?.data as? [String: Any] else { return }

            func toDouble(_ any: Any?) -> Double {
                if let d = any as? Double { return d }
                if let n = any as? NSNumber { return n.doubleValue }
                if let s = any as? String { return Double(s) ?? 0.0 }
                return 0.0
            }

            let totalRevenue = toDouble(dict["totalRevenue"])
            let platformEarnings = toDouble(dict["platformEarnings"])

            DispatchQueue.main.async {
                self.revenueStats = RevenueStats(
                    monthly: 0,
                    total: totalRevenue,
                    platformEarnings: platformEarnings
                )
                print("✅ Revenue (callable): total=\(totalRevenue), earnings=\(platformEarnings)")
            }
        }
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

    // Replace your helper with this explicit return version
    private func functions() -> Functions {
        return Functions.functions(region: "us-central1")
    }
    
    // add this helper next to your other RTDB helpers
    private func approveVenueSelfHeal(uid: String, venueId: String, name: String?, address: String?) {
        let db = Database.database().reference()
        let venueKey = venueId.isEmpty ? uid : venueId   // key venues/<venueKey>; you asked to keep it simple like promoter/venue

        var updates: [String: Any] = [:]

        // application mirror
        updates["venueApplications/\(uid)/status"] = "approved"
        updates["venueApplications/\(uid)/approved"] = true
        updates["venueApplications/\(uid)/reviewedAt"] = ServerValue.timestamp()
        updates["venueApplications/\(uid)/venueId"] = venueKey

        // live venue node (minimal fields you showed)
        updates["venues/\(venueKey)/approved"] = true
        updates["venues/\(venueKey)/approvedAt"] = ServerValue.timestamp()
        updates["venues/\(venueKey)/businessName"] = (name ?? "")
        updates["venues/\(venueKey)/website"] = ""
        updates["venues/\(venueKey)/instagram"] = ""
        updates["venues/\(venueKey)/tiktok"] = ""
        updates["venues/\(venueKey)/description"] = ""
        updates["venues/\(venueKey)/uid"] = uid
        updates["venues/\(venueKey)/sourceApplication"] = "venueApplications"
        if let addr = address, !addr.isEmpty { updates["venues/\(venueKey)/address"] = addr }

        // owner/admin mirrors so your UI can attach permissions
        updates["venueOwners/\(uid)/venueId"] = venueKey
        updates["venueOwners/\(uid)/approved"] = true
        updates["venueOwners/\(uid)/suspended"] = false
        updates["venueOwners/\(uid)/linkedAt"] = ServerValue.timestamp()
        updates["venueAdmins/\(venueKey)/\(uid)"] = true

        db.updateChildValues(updates) { err, _ in
            if let err = err {
                print("❌ approveVenue (self-heal RTDB): \(err.localizedDescription)")
            } else {
                print("🔧 approveVenue (self-heal RTDB) wrote approval for venue=\(venueKey) owner=\(uid)")
            }
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }


    // Replace the whole function with this RTDB version
    private func fetchNightlifeApplications(type: NLType, status: NLStatus, limit: Int = 100) {
        nlIsLoading = true
        nlError = nil

        let node: String
        switch type {
        case .promoter:    node = "promoterApplications"
        case .venue:       node = "venueApplications"
        case .entertainer: node = "entertainerApplications"
        }

        let ref = Database.database().reference().child(node)
        ref.queryOrdered(byChild: "status")
           .queryEqual(toValue: status.rawValue)
           .queryLimited(toFirst: UInt(limit))
           .observeSingleEvent(of: .value) { snapshot in
               var items: [NightlifeApplication] = []

               for case let child as DataSnapshot in snapshot.children {
                   guard let v = child.value as? [String: Any] else { continue }
                   let uid = child.key
                   let fullName = v["fullName"] as? String ?? ""
                   let email = v["email"] as? String ?? ""
                   let phone = v["phone"] as? String ?? ""
                   let businessName = v["businessName"] as? String ?? ""
                   let website = v["website"] as? String
                   let instagram = v["instagram"] as? String
                   let tiktok = v["tiktok"] as? String
                   let desc = v["description"] as? String
                   let stRaw = (v["status"] as? String) ?? "pending"
                   let st = NLStatus(rawValue: stRaw) ?? .pending
                   let suspended = (v["suspended"] as? Bool) ?? false
                   // RTDB timestamp is in ms — divide to seconds for TimeInterval display if you want
                   let submittedMs = (v["submittedAt"] as? TimeInterval)
                   let submittedAt = submittedMs != nil ? submittedMs! / 1000.0 : nil

                   items.append(NightlifeApplication(
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
                       suspended: suspended,
                       submittedAt: submittedAt
                   ))
               }

               DispatchQueue.main.async {
                   switch type {
                   case .promoter:    self.promoterApps = items
                   case .venue:       self.venueApps = items
                   case .entertainer: self.entertainerApps = items
                   }
                   self.nlIsLoading = false
                   self.refreshNightlifePendingCounts()
               }
           }
    }


    // Replace the whole function with this RTDB-based counter
    private func refreshNightlifePendingCounts() {
        func countPending(_ path: String, _ done: @escaping (Int) -> Void) {
            let ref = Database.database().reference().child(path)
            ref.queryOrdered(byChild: "status").queryEqual(toValue: "pending")
                .observeSingleEvent(of: .value) { snap in
                    var c = 0
                    for _ in snap.children { c += 1 }
                    done(c)
                }
        }

        let group = DispatchGroup()
        var p = 0, v = 0, e = 0

        group.enter(); countPending("promoterApplications") { p = $0; group.leave() }
        group.enter(); countPending("venueApplications")    { v = $0; group.leave() }
        group.enter(); countPending("entertainerApplications") { e = $0; group.leave() }

        group.notify(queue: .main) {
            self.pendingCountTotal = p + v + e
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

    // replace your approveVenue() body with this version (only the call/handler changed)
    private func approveVenue(uid: String, venueId: String, name: String?, address: String?) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")

        var payload: [String: Any] = ["type": "venue", "uid": uid, "action": "approve"]
        let trimmedId = venueId.trimmingCharacters(in: .whitespaces)
        if !trimmedId.isEmpty || (name?.isEmpty == false) || (address?.isEmpty == false) {
            payload["venue"] = ["venueId": trimmedId, "name": name ?? "", "address": address ?? ""]
        }

        fn.call(payload) { _, error in
            if let err = error as NSError? {
                let details = err.userInfo[FunctionsErrorDetailsKey] ?? "nil"
                print("❌ approveVenue [\(err.domain):\(err.code)] \(err.localizedDescription) details=\(details)")
                // fallback write so dashboard/state isn’t blocked:
                self.approveVenueSelfHeal(uid: uid, venueId: trimmedId, name: name, address: address)
                return
            }
            print("✅ Venue approved via callable:", uid, "→", trimmedId)
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }

    private func approveEntertainer(uid: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": "entertainer", "uid": uid, "action": "approve"]) { _, error in
            if let error = error {
                print("❌ approveEntertainer (callable):", error.localizedDescription)
                // fall through to self-heal anyway
            } else {
                print("✅ Entertainer approved via callable:", uid)
            }

            // ---- Self-heal: mirror approval to both nodes so the app stops showing "pending"
            let db = Database.database().reference()
            var updates: [String: Any] = [:]

            // application node
            updates["entertainerApplications/\(uid)/status"] = "approved"
            updates["entertainerApplications/\(uid)/approved"] = true
            updates["entertainerApplications/\(uid)/reviewedAt"] = ServerValue.timestamp()

            // live role node
            updates["entertainers/\(uid)/approved"] = true
            updates["entertainers/\(uid)/createdAt"] = ServerValue.timestamp()

            db.updateChildValues(updates) { err, _ in
                if let err = err {
                    print("❌ approveEntertainer (self-heal RTDB): \(err.localizedDescription)")
                } else {
                    print("🔧 approveEntertainer (self-heal RTDB) wrote approval flags for \(uid)")
                }
                // Refresh UI either way
                fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
                refreshNightlifePendingCounts()
            }
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
                    TextField("Venue ID (optional)", text: $venueId) // optional now
                    TextField("Venue Name (optional)", text: $name)
                    TextField("Venue Address (optional)", text: $address)
                }
                Section {
                    Button("Approve") {
                        onApprove(uid,
                                  venueId.trimmingCharacters(in: .whitespaces),
                                  name.isEmpty ? nil : name,
                                  address.isEmpty ? nil : address)
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
private struct NightlifeManageSheet: View {
    let app: AGDashboardView.NightlifeApplication

    @Binding var busy: Bool
    @Binding var error: String?

    var onApprove: () -> Void
    var onReject: (_ reason: String) -> Void
    var onSuspend: () -> Void
    var onReinstate: () -> Void
    var onCopyUID: () -> Void
    var onEmail: () -> Void
    var onCall: () -> Void

    @State private var rejectReason = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Applicant")) {
                    Text("Type: \(app.type.rawValue.capitalized)")
                    Text("Name: \(app.businessName.isEmpty ? app.fullName : app.businessName)")
                    Text("Email: \(app.email)")
                    Text("Phone: \(app.phone)")
                    Text("Status: \(app.status.rawValue)\(app.suspended ? " (Suspended)" : "")")
                    Button("Copy UID") { onCopyUID() }
                }

                Section(header: Text("Contact")) {
                    Button("Email \(app.email)") { onEmail() }
                    Button("Call \(app.phone)") { onCall() }
                }

                Section(header: Text("Actions")) {
                    if app.status == .pending {
                        Button {
                            busy = true; onApprove(); dismiss()
                        } label: {
                            Text("Approve").bold()
                        }
                        .buttonStyle(.borderedProminent)

                        VStack(alignment: .leading) {
                            TextField("Rejection reason (optional)", text: $rejectReason)
                            Button(role: .destructive) {
                                busy = true; onReject(rejectReason); dismiss()
                            } label: { Text("Reject") }
                        }
                    } else if app.status == .approved {
                        if app.suspended {
                            Button("Reinstate") { busy = true; onReinstate(); dismiss() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Suspend") { busy = true; onSuspend(); dismiss() }
                                .foregroundColor(.yellow)
                        }
                    }

                    if let e = error {
                        Text(e).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}
