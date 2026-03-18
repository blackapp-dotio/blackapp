import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions
import Charts
import UIKit

struct AGDashboardView: View {

    // ===== Brand & User State =====
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

    // ===== Revenue UX =====
    @State private var monthlyBreakdown: [MonthlyRevenue] = []
    @State private var showRevenueBreakdown = false

    // Click / tap month -> drilldown
    @State private var selectedMonthKey: MonthKey?
    @State private var selectedMonthSummary: MonthSummary?
    @State private var showMonthDrilldownSheet: Bool = false

    // Optional timeframe filter for chart + drilldown context
    enum RevenueRange: String, CaseIterable, Identifiable {
        case last3 = "3M"
        case last6 = "6M"
        case last12 = "12M"
        case ytd = "YTD"
        case all = "All"
        var id: String { rawValue }
    }
    @State private var revenueRange: RevenueRange = .last12

    // ===== Owner Search Sheet =====
    @State private var showOwnerSearchSheet: Bool = false
    @State private var ownerSearchQuery: String = ""

    // IMPORTANT: renamed to avoid collisions with any other SupportMessage type in your project
    @State private var supportMessages: [AGSupportMessage] = []
    @State private var expandedMessageId: String? = nil
    @State private var unreadCount: Int = 0

    @State private var showManageSheet = false
    @State private var manageTarget: NightlifeApplication?
    @State private var actionBusy = false
    @State private var actionError: String?

    // =====================================================
    // MARK: - Access-level fix + Revenue Drilldown Models
    // =====================================================
    //
    // These types MUST NOT be fileprivate if they are used by @State private properties.
    // Keeping them as private/fileprivate triggers:
    // "Property must be declared fileprivate because its type uses a fileprivate type"
    //

    /// MonthKey is used by @State properties; it must be non-fileprivate and Comparable for range filtering.
    struct MonthKey: Hashable, Codable, Comparable, CustomStringConvertible {
        let year: Int
        let month: Int // 1...12

        var description: String { "\(year)-\(String(format: "%02d", month))" }

        /// Preferred initializer used throughout this file.
        init(from date: Date) {
            let cal = Calendar.current
            self.year = cal.component(.year, from: date)
            self.month = cal.component(.month, from: date)
        }

        /// Convenience initializer (kept because you already use MonthKey(year:month:) elsewhere).
        init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return lhs.month < rhs.month
        }

        var startDate: Date {
            var c = DateComponents()
            c.year = year
            c.month = month
            c.day = 1
            return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
        }

        var endDate: Date {
            // start of next month
            var c = DateComponents()
            c.year = year
            c.month = month + 1
            c.day = 1
            return Calendar.current.date(from: c) ?? Date()
        }

        /// Display label used by charts and drilldowns.
        var label: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US")
            df.dateFormat = "MMM yyyy"
            return df.string(from: startDate)
        }
    }

    // ===== Brand Owner Lookup (for contact + vetting) =====
    struct BrandOwnerInfo {
        let uid: String
        let name: String
        let username: String?
        let email: String?
        let stripeAccountId: String?
        let stripeOnboardingComplete: Bool
        let stripeChargesEnabled: Bool
    }

    // ===== Brand Application Meta (from RTDB dict, not BrandModel) =====
    struct BrandMeta {
        let businessCategory: String?
        let purpose: String?
        let usagePlan: String?
        let status: String?
    }

    @State private var brandMeta: [String: BrandMeta] = [:]
    @State private var brandOwners: [String: BrandOwnerInfo] = [:]

    // ===== Platform fee (single source of truth) =====
    private let PLATFORM_FEE_RATE: Double = 0.05
    private var platformFeePercentLabel: String { "\(Int(PLATFORM_FEE_RATE * 100))%" }

    // ===== Revenue detail counts =====
    @State private var totalPurchases: Int = 0
    @State private var uniqueBuyersCount: Int = 0

    // Local computed drilldown stats (from RTDB purchases) — supports refund UI now
    struct MonthSummary {
        let key: MonthKey
        let gross: Double
        let platformFee: Double
        let netToSellers: Double

        // Refund UI prep (works if backend writes these fields later)
        let refundedCount: Int
        let refundedAmount: Double
        let netAfterRefunds: Double

        let purchaseCount: Int
        let uniqueBuyers: Int

        // Small “smart” breakdowns (futuristic/usable)
        let typeCounts: [String: Int]          // ticket vs table
        let topEvents: [(title: String, amount: Double, count: Int)]
    }

    // Monthly chart item
    struct MonthlyRevenue: Identifiable {
        let id = UUID()
        let label: String        // e.g., "Jan 2026"
        let value: Double        // gross for that month
        let key: MonthKey
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

    // Internal caches so drilldown is instant and does not re-query
    @State private var _monthGrossCache: [MonthKey: Double] = [:]
    @State private var _monthPurchaseCountCache: [MonthKey: Int] = [:]
    @State private var _monthBuyerIdsCache: [MonthKey: Set<String>] = [:]
    @State private var _monthRefundedCountCache: [MonthKey: Int] = [:]
    @State private var _monthRefundAmountCache: [MonthKey: Double] = [:]
    @State private var _monthTypeCountsCache: [MonthKey: [String: Int]] = [:]
    @State private var _monthEventAggCache: [MonthKey: [String: (amount: Double, count: Int)]] = [:]

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

                if selectedTile == "supportInbox" { supportInboxSection }
                if selectedTile == "nightlifeApprovals" { nightlifeApprovalsSection }

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
            fetchMonthlyBreakdown()          // Chart + local stats (refund-ready)
            fetchSupportMessages()
            refreshNightlifePendingCounts()
        }
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())

        // ===== Sheets =====
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

        .sheet(isPresented: $showOwnerSearchSheet) {
            NavigationStack {
                SearchView(initialQuery: ownerSearchQuery, initialScope: .people)
                    .navigationTitle("Find Brand Owner")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showOwnerSearchSheet = false }
                        }
                    }
            }
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
                    onSuspend: { suspend(type: app.type, uid: app.uid) },
                    onReinstate: { reinstate(type: app.type, uid: app.uid) },
                    onCopyUID: { UIPasteboard.general.string = app.uid },
                    onEmail: {
                        if let url = URL(string: "mailto:\(app.email)") { UIApplication.shared.open(url) }
                    },
                    onCall: {
                        let phone = app.phone.replacingOccurrences(of: " ", with: "")
                        if let url = URL(string: "tel:\(phone)") { UIApplication.shared.open(url) }
                    }
                )
                .preferredColorScheme(.dark)
            } else {
                EmptyView().preferredColorScheme(.dark)
            }
        }

        .sheet(isPresented: $showMonthDrilldownSheet) {
            MonthRevenueDrilldownSheet(
                summary: selectedMonthSummary,
                platformFeePercentLabel: platformFeePercentLabel
            )
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Tile Grid

    private var tileGridSection: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 2), spacing: 20) {
            dashboardTile("Users", value: "\(platformStats.totalUsers)", tag: "users")
            dashboardTile("Brands", value: "\(platformStats.totalBrands)", tag: "approvedBrands")
            dashboardTile("Pending Brands", value: "\(pendingBrands.count)", tag: "pendingBrands")
            dashboardTile("Suspended Brands", value: "\(suspendedBrands.count)", tag: "suspendedBrands")
            dashboardTile("Revenue", value: String(format: "$%.2f", revenueStats.total), tag: "revenue")
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
                fetchNightlifeApplications(type: .entertainer, status: .pending)

            default:
                break
            }
        }) {
            VStack(spacing: 10) {
                Text(value)
                    .font(.title2)
                    .bold()
                    .foregroundColor(.white)

                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.70))
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Brand Sections

    private var brandApprovalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending Brand Approvals").font(.title2).bold()

            if pendingBrands.isEmpty {
                Text("No pending brands at the moment.").foregroundColor(.gray)
            }

            ForEach(pendingBrands, id: \.id) { brand in
                brandCard(brand, showApprove: true, showSuspend: true, showDelete: false)
            }
        }
    }

    private var approvedBrandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approved Brands").font(.title2).bold()

            if approvedBrands.isEmpty {
                Text("No approved brands yet.").foregroundColor(.gray)
            }

            ForEach(approvedBrands, id: \.id) { brand in
                brandCard(brand, showApprove: false, showSuspend: true, showDelete: true)
            }
        }
    }

    private var suspendedBrandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suspended Brands").font(.title2).bold()

            if suspendedBrands.isEmpty {
                Text("No suspended brands.").foregroundColor(.gray)
            }

            ForEach(suspendedBrands, id: \.id) { brand in
                brandCard(brand, showApprove: true, showSuspend: false, showDelete: true)
            }
        }
    }

    // MARK: - Brand Card (vetting + contact)

    private func brandCard(
        _ brand: BrandModel,
        showApprove: Bool,
        showSuspend: Bool,
        showDelete: Bool
    ) -> some View {

        let ownerInfo = brandOwners[brand.ownerId]
        let meta = brandMeta[brand.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(brand.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    if let cat = meta?.businessCategory,
                       !cat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(cat).font(.caption).foregroundColor(.blue)
                    }

                    if let status = meta?.status,
                       !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(status.capitalized)
                            .font(.caption2)
                            .foregroundColor(
                                status == "approved" ? .green :
                                (status == "suspended" ? .yellow : .orange)
                            )
                    }
                }

                Spacer()

                if let info = ownerInfo {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(info.name).font(.subheadline).foregroundColor(.white)

                        if let username = info.username, !username.isEmpty {
                            Text("@\(username)").font(.caption).foregroundColor(.gray)
                        }

                        if info.stripeChargesEnabled || info.stripeOnboardingComplete {
                            Text("Stripe: Live").font(.caption2).foregroundColor(.green)
                        } else if (info.stripeAccountId ?? "").isEmpty {
                            Text("Stripe: Not Connected").font(.caption2).foregroundColor(.red)
                        } else {
                            Text("Stripe: Pending").font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
            }

            if let desc = brand.description, !desc.isEmpty {
                Text(desc)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.9))
            }

            if let purpose = meta?.purpose,
               !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Purpose").font(.caption2).bold().foregroundColor(.gray)
                    Text(purpose).font(.footnote).foregroundColor(.white.opacity(0.9))
                }
            }

            if let usage = meta?.usagePlan,
               !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How They’ll Use BlackApp").font(.caption2).bold().foregroundColor(.gray)
                    Text(usage).font(.footnote).foregroundColor(.white.opacity(0.9))
                }
            }

            HStack(spacing: 10) {

                if let info = ownerInfo {
                    if let email = info.email, !email.isEmpty {
                        Button {
                            if let url = URL(string: "mailto:\(email)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Email", systemImage: "envelope")
                        }
                        .font(.caption)
                    }

                    Button {
                        if let info = ownerInfo {
                            if let u = info.username, !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ownerSearchQuery = u.hasPrefix("@") ? u : "@\(u)"
                            } else if !info.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ownerSearchQuery = info.name
                            } else {
                                ownerSearchQuery = String(brand.ownerId.prefix(8))
                            }
                        } else {
                            ownerSearchQuery = String(brand.ownerId.prefix(8))
                        }

                        print("🔎 [AGDashboard] Search owner tapped: query=\(ownerSearchQuery) ownerId=\(brand.ownerId)")
                        showOwnerSearchSheet = true
                    } label: {
                        Label("Search Owner", systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()

                if showApprove {
                    Button("Approve") { approveBrand(brand) }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                }

                if showSuspend {
                    Button("Suspend") { suspendBrand(brand) }
                        .foregroundColor(.yellow)
                        .font(.caption)
                }

                if showDelete {
                    Button("Delete") { deleteBrand(brand) }
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding(.top, 6)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .cornerRadius(14)
    }

    private func suspendBrand(_ brand: BrandModel) {
        actionBusy = true
        actionError = nil

        let ref = Database.database().reference().child("brands").child(brand.id)
        let updates: [String: Any] = [
            "suspended": true,
            "approved": false,
            "status": "suspended",
            "updatedAt": ServerValue.timestamp()
        ]

        ref.updateChildValues(updates) { error, _ in
            DispatchQueue.main.async {
                self.actionBusy = false
                if let error = error {
                    self.actionError = error.localizedDescription
                    print("❌ [AGDashboard] suspendBrand failed brandId=\(brand.id) err=\(error.localizedDescription)")
                } else {
                    print("✅ [AGDashboard] suspendBrand ok brandId=\(brand.id)")
                }
            }
        }
    }

    private func approveBrand(_ brand: BrandModel) {
        actionBusy = true
        actionError = nil

        let ref = Database.database().reference().child("brands").child(brand.id)
        let updates: [String: Any] = [
            "approved": true,
            "suspended": false,
            "status": "approved",
            "reviewedAt": ServerValue.timestamp(),
            "updatedAt": ServerValue.timestamp()
        ]

        ref.updateChildValues(updates) { error, _ in
            DispatchQueue.main.async {
                self.actionBusy = false
                if let error = error {
                    self.actionError = error.localizedDescription
                    print("❌ [AGDashboard] approveBrand failed brandId=\(brand.id) err=\(error.localizedDescription)")
                } else {
                    print("✅ [AGDashboard] approveBrand ok brandId=\(brand.id)")
                }
            }
        }
    }

    private func deleteBrand(_ brand: BrandModel) {
        actionBusy = true
        actionError = nil

        let ref = Database.database().reference().child("brands").child(brand.id)
        ref.removeValue { error, _ in
            DispatchQueue.main.async {
                self.actionBusy = false
                if let error = error {
                    self.actionError = error.localizedDescription
                    print("❌ [AGDashboard] deleteBrand failed brandId=\(brand.id) err=\(error.localizedDescription)")
                } else {
                    print("✅ [AGDashboard] deleteBrand ok brandId=\(brand.id)")
                }
            }
        }
    }


    // MARK: - User Management Section

    private var userManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Users").font(.title2).bold()

            TextField("Search users", text: $searchQuery)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: searchQuery) { _ in filterUsers() }

            ForEach(filteredUsers, id: \.id) { user in
                HStack {
                    VStack(alignment: .leading) {
                        Text(user.name).bold().foregroundColor(.white)
                        if let username = user.username, !username.isEmpty {
                            Text(username).font(.caption).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    if superadmins.contains(user.id) {
                        Text("Superadmin").foregroundColor(.green)
                    } else if admins.contains(user.id) {
                        Button("Remove Admin") { updateAdminStatus(user.id, makeAdmin: false) }
                            .foregroundColor(.red)
                    } else {
                        Button("Make Admin") { updateAdminStatus(user.id, makeAdmin: true) }
                    }
                    Button("Suspend") { suspendUser(user) }.foregroundColor(.yellow)
                }
                .padding(10)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(14)
            }
        }
    }

    // MARK: - Revenue Sections

    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Revenue Report").font(.title2).bold()
                Spacer()
            }

            Picker("Range", selection: $revenueRange) {
                ForEach(RevenueRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: revenueRange) { _ in
                fetchMonthlyBreakdown()
            }

            Button(action: { withAnimation { showRevenueBreakdown.toggle() } }) {
                HStack {
                    Text(showRevenueBreakdown ? "Hide Breakdown" : "Show Breakdown").foregroundColor(.blue)
                    Spacer()
                    Image(systemName: showRevenueBreakdown ? "chevron.up" : "chevron.down").foregroundColor(.blue)
                }
                .padding(.vertical, 6)
            }

            HStack(spacing: 14) {
                revenueMetricCard(title: "Platform Earnings (\(platformFeePercentLabel))",
                                  value: String(format: "$%.2f", revenueStats.platformEarnings),
                                  icon: "banknote",
                                  tint: .blue)

                revenueMetricCard(title: "Gross Sales",
                                  value: String(format: "$%.2f", revenueStats.total),
                                  icon: "chart.line.uptrend.xyaxis",
                                  tint: .green)
            }

            Text("Tip: Tap a month bar to open a detailed breakdown.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.60))
                .padding(.top, 4)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .cornerRadius(16)
    }

    private func revenueMetricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(2)
            }

            Text(value)
                .font(.title3.bold())
                .foregroundColor(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .cornerRadius(14)
    }

    private var revenueDetailBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(Color.gray)

            Text("Revenue Breakdown").font(.headline).padding(.bottom, 4)

            Group {
                Text("Event Ticket & Table Sales").bold()
                Text("• Gross Revenue: \(String(format: "$%.2f", revenueStats.total))")
                Text("• Platform Fee (\(platformFeePercentLabel)): \(String(format: "$%.2f", revenueStats.platformEarnings))")
                Text("• Net to Sellers: \(String(format: "$%.2f", (revenueStats.total - revenueStats.platformEarnings)))")
            }
            .font(.caption)
            .padding(.leading, 4)

            Divider().background(Color.gray)

            Group {
                Text("Volume").bold()
                Text("• Total Purchases: \(totalPurchases)")
                Text("• Unique Buyers: \(uniqueBuyersCount)")
            }
            .font(.caption)
            .padding(.leading, 4)

            Divider().background(Color.gray)

            Text("Refund tracking UI is now supported. Once backend starts writing refund fields (status/refundedAt/refundAmount), the drilldown will show accurate refund totals.")
                .font(.footnote)
                .foregroundColor(.gray)
        }
        .padding(.top, 4)
    }

    private var revenueChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monthly Revenue Chart").font(.title2).bold()

            if monthlyBreakdown.isEmpty {
                Text("No chart data yet.").foregroundColor(.gray)
            } else {
                Chart(monthlyBreakdown) { m in
                    BarMark(
                        x: .value("Month", m.label),
                        y: .value("Revenue", m.value)
                    )
                    .cornerRadius(6)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel().foregroundStyle(Color.white.opacity(0.65))
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(Color.white.opacity(0.65))
                    }
                }
                .frame(height: 220)
                .padding(12)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(16)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        let origin = geo[proxy.plotAreaFrame].origin
                                        let location = CGPoint(
                                            x: value.location.x - origin.x,
                                            y: value.location.y - origin.y
                                        )

                                        // Determine the nearest month label by x position
                                        if let label: String = proxy.value(atX: location.x) {
                                            if let hit = monthlyBreakdown.first(where: { $0.label == label }) {
                                                openMonthDrilldown(hit.key)
                                            } else {
                                                openClosestMonthByX(locationX: location.x, proxy: proxy, geo: geo)
                                            }
                                        } else {
                                            openClosestMonthByX(locationX: location.x, proxy: proxy, geo: geo)
                                        }
                                    }
                            )
                    }
                }
            }
        }
    }

    private func openClosestMonthByX(locationX: CGFloat, proxy: ChartProxy, geo: GeometryProxy) {
        guard !monthlyBreakdown.isEmpty else { return }
        let plot = geo[proxy.plotAreaFrame]
        let x = max(0, min(plot.size.width, locationX))
        let idx = Int(round((CGFloat(monthlyBreakdown.count - 1) * (x / max(1, plot.size.width)))))
        let safeIdx = max(0, min(monthlyBreakdown.count - 1, idx))
        openMonthDrilldown(monthlyBreakdown[safeIdx].key)
    }

    private func openMonthDrilldown(_ key: MonthKey) {
        selectedMonthKey = key
        selectedMonthSummary = buildMonthSummary(for: key)
        showMonthDrilldownSheet = true
    }

    // MARK: - Support Inbox

    private var supportInboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Support Inbox")
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
                                    Text("User: \(message.userId.prefix(6))")
                                        .font(.subheadline)
                                        .foregroundColor(.white)

                                    Text("\(message.text.prefix(50))...")
                                        .font(.body)
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Image(systemName: expandedMessageId == message.id ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.white)
                            }
                            .padding()
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            .cornerRadius(14)
                        }
                        .buttonStyle(.plain)

                        if expandedMessageId == message.id {
                            VStack(alignment: .leading, spacing: 8) {
                                Divider()

                                Text("Full Message:")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                Text(message.text)
                                    .font(.body)
                                    .foregroundColor(.white)

                                Text("\(formattedDate(from: message.timestamp))")
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
                                .pickerStyle(.segmented)
                                .padding(.top)
                            }
                            .padding()
                            .background(Color.black.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .cornerRadius(14)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private var supportTileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Support").font(.headline).padding(.horizontal)

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
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(14)

                NavigationLink(destination: SupportBoardView()) {
                    HStack {
                        Text("Open Support Dashboard")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .cornerRadius(14)
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

            Picker("Type", selection: $nlSelectedType) {
                Text("Promoters").tag(NLType.promoter)
                Text("Venues").tag(NLType.venue)
                Text("Entertainers").tag(NLType.entertainer)
            }
            .pickerStyle(.segmented)
            .onChange(of: nlSelectedType) { _ in
                fetchNightlifeApplications(type: nlSelectedType, status: nlSelectedStatus)
            }

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
                                    }
                                    .foregroundColor(.red)

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
                                    }
                                    .foregroundColor(.red)

                                } else {
                                    Button("Approve") { approveEntertainer(uid: app.uid) }
                                        .buttonStyle(.borderedProminent)
                                    Button("Reject") {
                                        rejectTarget = (.entertainer, app.uid)
                                        showRejectReasonSheet = true
                                    }
                                    .foregroundColor(.red)
                                }
                            } else if nlSelectedStatus == .approved {
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
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .cornerRadius(14)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Firebase Logic

    private func fetchAllBrands() {
        let ref = Database.database().reference().child("brands")
        ref.observe(.value) { snapshot in
            var pending: [BrandModel] = []
            var approved: [BrandModel] = []
            var suspended: [BrandModel] = []
            var ownerIds: Set<String> = []
            var metaMap: [String: BrandMeta] = [:]

            for case let child as DataSnapshot in snapshot.children {
                guard
                    let dict = child.value as? [String: Any],
                    let brand = BrandModel.from(dict: dict, id: child.key)
                else { continue }

                ownerIds.insert(brand.ownerId)

                let businessCategory = dict["businessCategory"] as? String
                let purpose = dict["applicationPurpose"] as? String
                let usagePlan = dict["applicationUsagePlan"] as? String
                let status = dict["status"] as? String

                metaMap[brand.id] = BrandMeta(
                    businessCategory: businessCategory,
                    purpose: purpose,
                    usagePlan: usagePlan,
                    status: status
                )

                if brand.suspended { suspended.append(brand) }
                else if brand.approved { approved.append(brand) }
                else { pending.append(brand) }
            }

            self.pendingBrands = pending
            self.approvedBrands = approved
            self.suspendedBrands = suspended
            self.brandMeta = metaMap

            self.fetchBrandOwners(ownerIds: Array(ownerIds))
        }
    }

    private func fetchBrandOwners(ownerIds: [String]) {
        guard !ownerIds.isEmpty else {
            self.brandOwners = [:]
            return
        }

        let ref = Database.database().reference().child("users")
        ref.observeSingleEvent(of: .value) { snapshot in
            var map: [String: BrandOwnerInfo] = [:]

            for uid in ownerIds {
                let child = snapshot.childSnapshot(forPath: uid)
                guard child.exists(), let dict = child.value as? [String: Any] else { continue }

                let name = (dict["name"] as? String) ?? "Unnamed"
                let username = dict["username"] as? String
                let email = dict["email"] as? String

                let stripeId = dict["stripeAccountId"] as? String
                let onboardingComplete = dict["stripeOnboardingComplete"] as? Bool ?? false
                let chargesEnabled = dict["stripeChargesEnabled"] as? Bool ?? false

                map[uid] = BrandOwnerInfo(
                    uid: uid,
                    name: name,
                    username: username,
                    email: email,
                    stripeAccountId: stripeId,
                    stripeOnboardingComplete: onboardingComplete,
                    stripeChargesEnabled: chargesEnabled
                )
            }

            DispatchQueue.main.async {
                self.brandOwners = map
            }
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
            } else {
                self.admins = []
            }
        }
    }

    private func fetchSuperAdminList() {
        let root = Database.database().reference()

        func apply(_ snapshot: DataSnapshot) {
            if let dict = snapshot.value as? [String: Bool] {
                self.superadmins = Set(dict.compactMap { $0.value ? $0.key : nil })
            } else {
                self.superadmins = []
            }
        }

        root.child("superadmins").observeSingleEvent(of: .value) { snap in
            if snap.exists() {
                apply(snap)
            } else {
                root.child("superadmin").observeSingleEvent(of: .value) { snap2 in
                    apply(snap2)
                }
            }
        }
    }

    // MARK: - Monthly Breakdown (Refund-ready + Range filter + Drilldown)

    private func fetchMonthlyBreakdown() {
        let ref = Database.database().reference().child("purchases")

        ref.observe(.value) { snapshot in
            // Aggregates by MonthKey (year+month)
            var monthGross: [MonthKey: Double] = [:]
            var monthPurchaseCount: [MonthKey: Int] = [:]
            var monthBuyerIds: [MonthKey: Set<String>] = [:]

            // Refund UI prep aggregates
            var monthRefundedCount: [MonthKey: Int] = [:]
            var monthRefundAmount: [MonthKey: Double] = [:]

            // Smart breakdown aggregates
            var monthTypeCounts: [MonthKey: [String: Int]] = [:]
            var monthEventAgg: [MonthKey: [String: (amount: Double, count: Int)]] = [:]

            // Global rollups
            var runningTotal: Double = 0
            var purchaseCount: Int = 0
            var buyerIdsAll: Set<String> = []

            for case let userSnap as DataSnapshot in snapshot.children {
                let buyerId = userSnap.key

                for case let purchaseSnap as DataSnapshot in userSnap.children {
                    guard let dict = purchaseSnap.value as? [String: Any] else { continue }

                    let amount = toDouble(dict["totalAmount"])
                    let ts = normalizeUnixTime(dict["timestamp"])
                        ?? normalizeUnixTime(dict["createdAt"])
                        ?? normalizeUnixTime(dict["purchasedAt"])
                        ?? 0

                    runningTotal += amount
                    purchaseCount += 1
                    buyerIdsAll.insert(buyerId)

                    let status = (dict["status"] as? String)
                        ?? (dict["paymentStatus"] as? String)
                        ?? "succeeded"

                    let isRefunded = isRefundStatus(status: status, dict: dict)

                    // Drilldown-friendly fields
                    let purchaseType = ((dict["type"] as? String) ?? (dict["purchaseType"] as? String) ?? "ticket")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()

                    let eventTitle = ((dict["eventTitle"] as? String)
                                      ?? (dict["eventName"] as? String)
                                      ?? "Event")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if ts > 0 {
                        let date = Date(timeIntervalSince1970: ts)
                        let key = MonthKey(from: date) // ✅ fixed (was MonthKey(date:))

                        monthGross[key, default: 0] += amount
                        monthPurchaseCount[key, default: 0] += 1
                        monthBuyerIds[key, default: []].insert(buyerId)

                        var typeMap = monthTypeCounts[key] ?? [:]
                        typeMap[purchaseType.isEmpty ? "ticket" : purchaseType, default: 0] += 1
                        monthTypeCounts[key] = typeMap

                        var evMap = monthEventAgg[key] ?? [:]
                        let cur = evMap[eventTitle] ?? (0, 0)
                        evMap[eventTitle] = (cur.amount + amount, cur.count + 1)
                        monthEventAgg[key] = evMap

                        if isRefunded {
                            monthRefundedCount[key, default: 0] += 1
                            let refundAmount = max(0, toDouble(dict["refundAmount"]))
                            monthRefundAmount[key, default: 0] += (refundAmount > 0 ? refundAmount : amount)
                        }
                    }
                }
            }

            // Convert to chart points
            let allKeys = monthGross.keys.sorted() // ascending
            let rangedKeys = applyRangeFilter(allKeys)

            let chartData: [MonthlyRevenue] = rangedKeys.map { key in
                MonthlyRevenue(label: key.label, value: monthGross[key] ?? 0, key: key)
            }

            let platformEarnings = runningTotal * PLATFORM_FEE_RATE

            DispatchQueue.main.async {
                self.monthlyBreakdown = chartData
                self.revenueStats = RevenueStats(monthly: 0, total: runningTotal, platformEarnings: platformEarnings)
                self.totalPurchases = purchaseCount
                self.uniqueBuyersCount = buyerIdsAll.count

                if let k = self.selectedMonthKey {
                    self.selectedMonthSummary = self.buildMonthSummary(
                        for: k,
                        monthGross: monthGross,
                        monthPurchaseCount: monthPurchaseCount,
                        monthBuyerIds: monthBuyerIds,
                        monthRefundedCount: monthRefundedCount,
                        monthRefundAmount: monthRefundAmount,
                        monthTypeCounts: monthTypeCounts,
                        monthEventAgg: monthEventAgg
                    )
                }

                // Cache for instant drilldown
                self._monthGrossCache = monthGross
                self._monthPurchaseCountCache = monthPurchaseCount
                self._monthBuyerIdsCache = monthBuyerIds
                self._monthRefundedCountCache = monthRefundedCount
                self._monthRefundAmountCache = monthRefundAmount
                self._monthTypeCountsCache = monthTypeCounts
                self._monthEventAggCache = monthEventAgg
            }
        }
    }

    private func buildMonthSummary(for key: MonthKey) -> MonthSummary? {
        return buildMonthSummary(
            for: key,
            monthGross: _monthGrossCache,
            monthPurchaseCount: _monthPurchaseCountCache,
            monthBuyerIds: _monthBuyerIdsCache,
            monthRefundedCount: _monthRefundedCountCache,
            monthRefundAmount: _monthRefundAmountCache,
            monthTypeCounts: _monthTypeCountsCache,
            monthEventAgg: _monthEventAggCache
        )
    }

    private func buildMonthSummary(
        for key: MonthKey,
        monthGross: [MonthKey: Double],
        monthPurchaseCount: [MonthKey: Int],
        monthBuyerIds: [MonthKey: Set<String>],
        monthRefundedCount: [MonthKey: Int],
        monthRefundAmount: [MonthKey: Double],
        monthTypeCounts: [MonthKey: [String: Int]],
        monthEventAgg: [MonthKey: [String: (amount: Double, count: Int)]]
    ) -> MonthSummary? {

        let gross = monthGross[key] ?? 0
        let purchaseCount = monthPurchaseCount[key] ?? 0
        let uniqueBuyers = monthBuyerIds[key]?.count ?? 0

        let platformFee = gross * PLATFORM_FEE_RATE
        let netToSellers = max(0, gross - platformFee)

        let refundedCount = monthRefundedCount[key] ?? 0
        let refundedAmount = monthRefundAmount[key] ?? 0

        let netAfterRefunds = max(0, gross - refundedAmount)

        let typeCounts = monthTypeCounts[key] ?? [:]
        let eventMap = monthEventAgg[key] ?? [:]

        let topEvents = eventMap
            .map { (title: $0.key, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
            .prefix(6)
            .map { ($0.title, $0.amount, $0.count) }

        return MonthSummary(
            key: key,
            gross: gross,
            platformFee: platformFee,
            netToSellers: netToSellers,
            refundedCount: refundedCount,
            refundedAmount: refundedAmount,
            netAfterRefunds: netAfterRefunds,
            purchaseCount: purchaseCount,
            uniqueBuyers: uniqueBuyers,
            typeCounts: typeCounts,
            topEvents: Array(topEvents)
        )
    }

    private func applyRangeFilter(_ keysSortedAscending: [MonthKey]) -> [MonthKey] {
        guard revenueRange != .all else { return keysSortedAscending }

        let cal = Calendar.current
        let now = Date()
        let monthStartNow = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let startDate: Date? = {
            switch revenueRange {
            case .last3:  return cal.date(byAdding: .month, value: -2, to: monthStartNow)
            case .last6:  return cal.date(byAdding: .month, value: -5, to: monthStartNow)
            case .last12: return cal.date(byAdding: .month, value: -11, to: monthStartNow)
            case .ytd:    return cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1))
            case .all:    return nil
            }
        }()

        guard let start = startDate else { return keysSortedAscending }

        let startKey = MonthKey(from: start) // ✅ fixed (was MonthKey(date:))
        return keysSortedAscending.filter { $0 >= startKey } // ✅ MonthKey is Comparable now
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

            self.platformStats = PlatformStats(
                totalUsers: Int(userCount),
                totalBrands: Int(brandCount),
                approvedBrands: approved
            )
        }
    }

    private func fetchRevenueStats() {
        let fn = functions().httpsCallable("getPlatformRevenue")
        fn.call([:]) { result, error in
            if let error = error {
                print("❌ getPlatformRevenue (callable):", error.localizedDescription)
                return
            }
            guard let dict = result?.data as? [String: Any] else { return }

            let totalRevenue = toDouble(dict["totalRevenue"])
            let platformEarnings = toDouble(dict["platformEarnings"])

            DispatchQueue.main.async {
                self.revenueStats = RevenueStats(monthly: 0, total: totalRevenue, platformEarnings: platformEarnings)
            }
        }
    }

    // MARK: - Support Messages

    private func fetchSupportMessages() {
        let ref = Database.database().reference().child("supportMessages")

        ref.observeSingleEvent(of: .value) { snapshot in
            var messages: [AGSupportMessage] = []
            var unread = 0

            for case let child as DataSnapshot in snapshot.children {
                guard let dict = child.value as? [String: Any] else { continue }

                let message = dict["message"] as? String ?? ""
                let timestamp = dict["timestamp"] as? TimeInterval ?? 0
                let userId = dict["userId"] as? String ?? ""

                let name = dict["name"] as? String ?? "Unknown"
                let email = dict["email"] as? String ?? "N/A"
                let status = dict["status"] as? String ?? "unread"

                if status == "unread" { unread += 1 }

                messages.append(AGSupportMessage(
                    id: child.key,
                    userId: userId,
                    text: message,
                    timestamp: timestamp,
                    status: status,
                    name: name,
                    email: email
                ))
            }

            DispatchQueue.main.async {
                self.supportMessages = messages.sorted { $0.timestamp > $1.timestamp }
                self.unreadCount = unread
            }
        }
    }

    private func updateSupportMessageStatus(messageId: String, newStatus: String) {
        let ref = Database.database().reference().child("supportMessages").child(messageId)
        ref.updateChildValues(["status": newStatus]) { error, _ in
            if let error = error {
                print("❌ Failed to update status:", error.localizedDescription)
            } else {
                self.fetchSupportMessages()
            }
        }
    }

    // MARK: - Admin / User helpers

    private func suspendUser(_ user: DashboardUser) {
        let ref = Database.database().reference().child("users").child(user.id)
        ref.updateChildValues(["suspended": true])
    }

    private func updateAdminStatus(_ userId: String, makeAdmin: Bool) {
        let ref = Database.database().reference().child("admins").child(userId)
        ref.setValue(makeAdmin)
        if makeAdmin { admins.insert(userId) } else { admins.remove(userId) }
    }

    private func filterUsers() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredUsers = q.isEmpty ? users : users.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Nightlife Approvals: Functions

    private func functions() -> Functions {
        return Functions.functions(region: "us-central1")
    }

    private func suspend(type: NLType, uid: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": type.rawValue, "uid": uid, "action": "suspend"]) { _, error in
            if let error = error as NSError? {
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
                self.actionError = error.localizedDescription
            }
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
            self.actionBusy = false
        }
    }

    private func approveVenueSelfHeal(uid: String, venueId: String, name: String?, address: String?) {
        let db = Database.database().reference()
        let venueKey = venueId.isEmpty ? uid : venueId

        var updates: [String: Any] = [:]

        updates["venueApplications/\(uid)/status"] = "approved"
        updates["venueApplications/\(uid)/approved"] = true
        updates["venueApplications/\(uid)/reviewedAt"] = ServerValue.timestamp()
        updates["venueApplications/\(uid)/venueId"] = venueKey

        updates["venues/\(venueKey)/approved"] = true
        updates["venues/\(venueKey)/approvedAt"] = ServerValue.timestamp()
        updates["venues/\(venueKey)/businessName"] = (name ?? "")
        updates["venues/\(venueKey)/uid"] = uid
        if let addr = address, !addr.isEmpty { updates["venues/\(venueKey)/address"] = addr }

        updates["venueOwners/\(uid)/venueId"] = venueKey
        updates["venueOwners/\(uid)/approved"] = true
        updates["venueOwners/\(uid)/suspended"] = false
        updates["venueOwners/\(uid)/linkedAt"] = ServerValue.timestamp()
        updates["venueAdmins/\(venueKey)/\(uid)"] = true

        db.updateChildValues(updates) { _, _ in
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }

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

    private func refreshNightlifePendingCounts() {
        func countPending(_ path: String, _ done: @escaping (Int) -> Void) {
            let ref = Database.database().reference().child(path)
            ref.queryOrdered(byChild: "status").queryEqual(toValue: "pending")
                .observeSingleEvent(of: .value) { snap in
                    // ✅ iterate snapshot.children (not snapshot.value.children)
                    var c = 0
                    for _ in snap.children { c += 1 }
                    done(c)
                }
        }

        let group = DispatchGroup()
        var p = 0, v = 0, e = 0

        group.enter(); countPending("promoterApplications") { p = $0; group.leave() }
        group.enter(); countPending("venueApplications") { v = $0; group.leave() }
        group.enter(); countPending("entertainerApplications") { e = $0; group.leave() }

        group.notify(queue: .main) {
            self.pendingCountTotal = p + v + e
        }
    }

    private func approvePromoter(uid: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": "promoter", "uid": uid, "action": "approve"]) { _, error in
            if let error = error { print("❌ approvePromoter:", error.localizedDescription) }
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }

    private func approveVenue(uid: String, venueId: String, name: String?, address: String?) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")

        var payload: [String: Any] = ["type": "venue", "uid": uid, "action": "approve"]
        let trimmedId = venueId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedId.isEmpty || (name?.isEmpty == false) || (address?.isEmpty == false) {
            payload["venue"] = ["venueId": trimmedId, "name": name ?? "", "address": address ?? ""]
        }

        fn.call(payload) { _, error in
            if let err = error as NSError? {
                let details = err.userInfo[FunctionsErrorDetailsKey] ?? "nil"
                print("❌ approveVenue [\(err.domain):\(err.code)] \(err.localizedDescription) details=\(details)")
                self.approveVenueSelfHeal(uid: uid, venueId: trimmedId, name: name, address: address)
                return
            }
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }

    private func approveEntertainer(uid: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": "entertainer", "uid": uid, "action": "approve"]) { _, _ in
            let db = Database.database().reference()
            var updates: [String: Any] = [:]
            updates["entertainerApplications/\(uid)/status"] = "approved"
            updates["entertainerApplications/\(uid)/approved"] = true
            updates["entertainerApplications/\(uid)/reviewedAt"] = ServerValue.timestamp()
            updates["entertainers/\(uid)/approved"] = true
            updates["entertainers/\(uid)/createdAt"] = ServerValue.timestamp()

            db.updateChildValues(updates) { _, _ in
                self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
                self.refreshNightlifePendingCounts()
            }
        }
    }

    private func rejectApplication(type: NLType, uid: String, reason: String) {
        let fn = functions().httpsCallable("reviewNightlifeApplication")
        fn.call(["type": type.rawValue, "uid": uid, "action": "reject", "reason": reason]) { _, error in
            if let error = error { print("❌ rejectApplication:", error.localizedDescription) }
            self.fetchNightlifeApplications(type: self.nlSelectedType, status: self.nlSelectedStatus)
            self.refreshNightlifePendingCounts()
        }
    }

    // MARK: - Helpers (Revenue decoding + refund readiness)

    private func toDouble(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) ?? 0.0 }
        return 0.0
    }

    /// Normalize UNIX timestamp: supports seconds or milliseconds.
    private func normalizeUnixTime(_ any: Any?) -> TimeInterval? {
        guard let any = any else { return nil }
        let v: Double = {
            if let t = any as? TimeInterval { return t }
            if let d = any as? Double { return d }
            if let n = any as? NSNumber { return n.doubleValue }
            if let s = any as? String { return Double(s) ?? 0 }
            return 0
        }()
        if v <= 0 { return nil }
        if v > 2_000_000_000_000 { return v / 1000.0 }
        return v
    }

    private func isRefundStatus(status: String, dict: [String: Any]) -> Bool {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "refunded" || s == "refund" || s == "reversed" || s == "charge_refunded" { return true }
        if normalizeUnixTime(dict["refundedAt"]) != nil { return true }
        if toDouble(dict["refundAmount"]) > 0 { return true }
        if let rid = dict["stripeRefundId"] as? String, !rid.isEmpty { return true }
        return false
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

    struct AGSupportMessage: Identifiable {
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
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .foregroundColor(.white.opacity(0.90))
    }
}

// MARK: - Month Drilldown Sheet (refund UI included; backend can fill later)

private struct MonthRevenueDrilldownSheet: View {
    let summary: AGDashboardView.MonthSummary?
    let platformFeePercentLabel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary?.key.label ?? "Month")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text("Tap-to-drilldown revenue intelligence")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.65))
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                if let s = summary {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {

                            HStack(spacing: 12) {
                                metricCard("Gross", String(format: "$%.2f", s.gross), "chart.bar.fill", .green)
                                metricCard("Platform (\(platformFeePercentLabel))", String(format: "$%.2f", s.platformFee), "banknote.fill", .blue)
                            }

                            HStack(spacing: 12) {
                                metricCard("Net to Sellers", String(format: "$%.2f", s.netToSellers), "arrow.down.right.circle.fill", .white)
                                metricCard("Purchases", "\(s.purchaseCount)", "cart.fill", .white)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Refunds")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                HStack(spacing: 12) {
                                    metricCard("Refunded Count", "\(s.refundedCount)", "arrow.uturn.backward.circle.fill", .red)
                                    metricCard("Refund Amount", String(format: "$%.2f", s.refundedAmount), "creditcard.fill", .red)
                                }

                                HStack(spacing: 12) {
                                    metricCard("Net After Refunds", String(format: "$%.2f", s.netAfterRefunds), "shield.lefthalf.filled", .white)
                                    metricCard("Unique Buyers", "\(s.uniqueBuyers)", "person.2.fill", .white)
                                }

                                Text("Note: Refund totals will become authoritative once backend writes status/refundedAt/refundAmount consistently.")
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.60))
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            .cornerRadius(16)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Mix")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                if s.typeCounts.isEmpty {
                                    Text("No type data found.")
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.65))
                                } else {
                                    ForEach(s.typeCounts.keys.sorted(), id: \.self) { k in
                                        HStack {
                                            Text(k.uppercased())
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.white.opacity(0.85))
                                            Spacer()
                                            Text("\(s.typeCounts[k] ?? 0)")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.white.opacity(0.85))
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            .cornerRadius(16)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Top Events")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                if s.topEvents.isEmpty {
                                    Text("No event titles recorded in purchases yet.")
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.65))
                                } else {
                                    ForEach(Array(s.topEvents.enumerated()), id: \.offset) { _, row in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .lineLimit(2)
                                            HStack {
                                                Text("\(row.count) sales")
                                                    .font(.caption)
                                                    .foregroundColor(.white.opacity(0.70))
                                                Spacer()
                                                Text(String(format: "$%.2f", row.amount))
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundColor(.white.opacity(0.90))
                                            }
                                        }
                                        .padding(.vertical, 6)

                                        Divider().background(Color.white.opacity(0.10))
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                            .cornerRadius(16)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                    }
                } else {
                    Spacer()
                    Text("No month data available.")
                        .foregroundColor(.white.opacity(0.70))
                    Spacer()
                }
            }
        }
    }

    private func metricCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(tint)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(2)
            }
            Text(value)
                .font(.title3.bold())
                .foregroundColor(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .cornerRadius(14)
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
                    TextField("Venue ID (optional)", text: $venueId)
                    TextField("Venue Name (optional)", text: $name)
                    TextField("Venue Address (optional)", text: $address)
                }
                Section {
                    Button("Approve") {
                        onApprove(
                            uid,
                            venueId.trimmingCharacters(in: .whitespacesAndNewlines),
                            name.isEmpty ? nil : name,
                            address.isEmpty ? nil : address
                        )
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
                        Button { busy = true; onApprove(); dismiss() } label: { Text("Approve").bold() }
                            .buttonStyle(.borderedProminent)

                        VStack(alignment: .leading) {
                            TextField("Rejection reason (optional)", text: $rejectReason)
                            Button(role: .destructive) { busy = true; onReject(rejectReason); dismiss() } label: { Text("Reject") }
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
