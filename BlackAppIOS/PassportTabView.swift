import SwiftUI
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import FirebaseStorage
import UIKit

// =====================================================
// MARK: - PassportTabView (VIP / Tickets / Star Power)
// Focus: Hide/Delete passport items + UI prepped for refunds
// Data source: RTDB purchases/{uid}/{purchaseId}
// Hide: purchases/{uid}/{purchaseId}/hidden = true (+hiddenAt)
// Delete: remove purchases/{uid}/{purchaseId}
// =====================================================
struct PassportTabView: View {

    // MARK: Data
    @State private var inviteCount: Int = 0
    @State private var tickets: [PassportTicketItem] = []
    @State private var isLoading: Bool = true
    @State private var errorText: String?

    // MARK: UI
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    @State private var selectedTicket: PassportTicketItem?

    // Action UI
    @State private var pendingActionItem: PassportTicketItem?
    @State private var showActionsDialog: Bool = false
    @State private var showConfirmDelete: Bool = false
    @State private var toastText: String?

    // MARK: Computed
    private var uid: String? { Auth.auth().currentUser?.uid }
    private var inviteLink: String {
        let id = uid ?? ""
        return "https://blackapp.io/invite?ref=\(id)"
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        headerRow

                        starPowerCard

                        myTicketsSection

                        upcomingSection

                        inviteSection

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Passport…")
                            .foregroundColor(.white.opacity(0.85))
                            .font(.subheadline)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let t = toastText, !t.isEmpty {
                    VStack {
                        Spacer()
                        Text(t)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                            .padding(.bottom, 16)
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
            .onAppear { reloadPassport() }

            .sheet(isPresented: $showShareSheet) {
                PassportActivityView(activityItems: shareItems)
            }

            .sheet(item: $selectedTicket) { item in
                PassportTicketDetailView(
                    item: item,
                    onHide: { hideTicket(item) },
                    onDelete: { confirmDelete(item) }
                )
                .preferredColorScheme(.dark)
            }

            .confirmationDialog("Ticket Options",
                                isPresented: $showActionsDialog,
                                titleVisibility: .visible) {
                Button("Hide from Passport") {
                    if let item = pendingActionItem { hideTicket(item) }
                }
                Button("Delete permanently", role: .destructive) {
                    if let item = pendingActionItem { confirmDelete(item) }
                }
                Button("Cancel", role: .cancel) {}
            }

            .alert("Delete Ticket?", isPresented: $showConfirmDelete) {
                Button("Delete", role: .destructive) {
                    if let item = pendingActionItem { deleteTicket(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the receipt from Passport and cannot be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // =====================================================
    // MARK: - Header
    // =====================================================
    private var headerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                Image(systemName: "shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Passport")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Your access, tickets, and Star Power")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.70))
            }

            Spacer()

            Button {
                shareItems = [inviteLink]
                showShareSheet = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    // =====================================================
    // MARK: - Star Power
    // =====================================================
    private var starPowerCard: some View {
        let sp = StarPowerLogic(inviteCount: inviteCount)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Star Power")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(sp.colorName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }

            Text("Determined by invites. Every 5 invites advances your color.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.70))

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: sp.rainbowColors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 14)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))

                GeometryReader { geo in
                    let x = max(0, min(geo.size.width - 10, geo.size.width * sp.progress))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: .white.opacity(0.55), radius: 8, x: 0, y: 0)
                        .offset(x: x, y: 2)
                }
                .frame(height: 14)
            }

            HStack(spacing: 12) {
                statPill(title: "Invites", value: "\(inviteCount)")
                statPill(title: "Next in", value: sp.nextInText)
                statPill(title: "Level", value: sp.levelText)
            }
        }
        .padding(14)
        .background(passportCardBackground)
        .overlay(passportCardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.70))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // =====================================================
    // MARK: - Tickets Grid
    // =====================================================
    private var myTicketsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Tickets")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if !tickets.isEmpty {
                    Text("\(tickets.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            if let err = errorText, !err.isEmpty {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red.opacity(0.9))
            }

            if !isLoading && tickets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "ticket")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                    Text("No tickets yet.")
                        .foregroundColor(.white.opacity(0.85))
                        .font(.subheadline.weight(.semibold))
                    Text("When you buy tickets on BlackApp, your flyers will show here.")
                        .foregroundColor(.white.opacity(0.65))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(passportCardBackground)
                .overlay(passportCardBorder)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(tickets) { item in
                        PassportTicketCard(item: item) {
                            selectedTicket = item
                        }
                        // Action entry points
                        .contextMenu {
                            Button {
                                pendingActionItem = item
                                hideTicket(item)
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }

                            Button(role: .destructive) {
                                pendingActionItem = item
                                confirmDelete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .onLongPressGesture {
                            pendingActionItem = item
                            showActionsDialog = true
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    // =====================================================
    // MARK: - Upcoming (secondary strip)
    // =====================================================
    private var upcomingSection: some View {
        // Refund UI is prepped, but until backend marks refunds,
        // this behaves as a normal upcoming filter.
        let upcoming = tickets.filter { $0.isUpcoming && !$0.isRefunded }.prefix(10)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            if upcoming.isEmpty {
                Text("Your upcoming tickets will appear here.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(upcoming)) { item in
                            PassportUpcomingCard(item: item) {
                                selectedTicket = item
                            }
                            .contextMenu {
                                Button {
                                    pendingActionItem = item
                                    hideTicket(item)
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }

                                Button(role: .destructive) {
                                    pendingActionItem = item
                                    confirmDelete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.top, 4)
    }

    // =====================================================
    // MARK: - Invite CTA
    // =====================================================
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invite Friends")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            Text("Share your invite link. Every successful signup increases your Star Power.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.70))

            VStack(alignment: .leading, spacing: 10) {
                Text(inviteLink)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = inviteLink
                        showToast("Copied")
                    } label: {
                        passportButtonLabel(title: "Copy", icon: "doc.on.doc")
                    }
                    .buttonStyle(.plain)

                    Button {
                        shareItems = ["Join me on BlackApp:", inviteLink]
                        showShareSheet = true
                    } label: {
                        passportButtonLabel(title: "Share", icon: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(passportCardBackground)
        .overlay(passportCardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 4)
    }

    private func passportButtonLabel(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundColor(.white)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // =====================================================
    // MARK: - Styling
    // =====================================================
    private var passportCardBackground: some View {
        LinearGradient(
            colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(.ultraThinMaterial.opacity(0.10))
    }

    private var passportCardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
    }

    // =====================================================
    // MARK: - Loaders
    // =====================================================
    private func reloadPassport() {
        errorText = nil
        isLoading = true
        tickets = []
        fetchInviteCount()
        fetchPurchases()
    }

    private func fetchInviteCount() {
        guard let uid = uid else { return }

        Firestore.firestore()
            .collection("users").document(uid)
            .getDocument { snap, _ in
                let data = snap?.data() ?? [:]

                let fsCountInt: Int = {
                    if let v = data["inviteCount"] as? Int { return v }
                    if let v = data["inviteCount"] as? Double { return Int(v) }
                    if let v = data["inviteCount"] as? NSNumber { return v.intValue }
                    return 0
                }()

                if fsCountInt > 0 {
                    DispatchQueue.main.async { self.inviteCount = fsCountInt }
                    return
                }

                Database.database().reference()
                    .child("users").child(uid).child("inviteCount")
                    .observeSingleEvent(of: .value) { s in
                        let r: Int = {
                            if let v = s.value as? Int { return v }
                            if let v = s.value as? Double { return Int(v) }
                            if let v = s.value as? NSNumber { return v.intValue }
                            return 0
                        }()
                        DispatchQueue.main.async { self.inviteCount = r }
                    }
            }
    }

    private func fetchPurchases() {
        guard let uid = uid else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorText = "You must be signed in to view Passport."
            }
            return
        }

        let ref = Database.database().reference().child("purchases").child(uid)
        ref.observeSingleEvent(of: .value) { snap in
            var out: [PassportTicketItem] = []

            for case let child as DataSnapshot in snap.children {
                guard let dict = child.value as? [String: Any] else { continue }

                // Skip hidden (soft-deleted)
                let hidden: Bool = {
                    if let b = dict["hidden"] as? Bool { return b }
                    if let n = dict["hidden"] as? NSNumber { return n.boolValue }
                    if let s = dict["hidden"] as? String { return (s as NSString).boolValue }
                    return false
                }()
                if hidden { continue }

                out.append(PassportTicketItem.fromFallbackDict(id: child.key, dict: dict))
            }

            out.sort { $0.eventTimeUnix > $1.eventTimeUnix }

            DispatchQueue.main.async {
                self.tickets = out
                self.isLoading = false
            }
        }
    }

    // =====================================================
    // MARK: - Hide / Delete actions
    // =====================================================
    private func hideTicket(_ item: PassportTicketItem) {
        guard let uid = uid else { return }

        // Optimistic UI
        tickets.removeAll { $0.id == item.id }
        showToast("Hidden")

        let ref = Database.database().reference()
            .child("purchases").child(uid).child(item.id)

        let payload: [String: Any] = [
            "hidden": true,
            "hiddenAt": Date().timeIntervalSince1970
        ]

        ref.updateChildValues(payload) { err, _ in
            if let err = err {
                DispatchQueue.main.async {
                    self.errorText = "Couldn’t hide ticket. \(err.localizedDescription)"
                    self.reloadPassport()
                }
            }
        }
    }

    private func confirmDelete(_ item: PassportTicketItem) {
        pendingActionItem = item
        showConfirmDelete = true
    }

    private func deleteTicket(_ item: PassportTicketItem) {
        guard let uid = uid else { return }

        // Optimistic UI
        tickets.removeAll { $0.id == item.id }
        showToast("Deleted")

        let ref = Database.database().reference()
            .child("purchases").child(uid).child(item.id)

        ref.removeValue { err, _ in
            if let err = err {
                DispatchQueue.main.async {
                    self.errorText = "Couldn’t delete ticket. \(err.localizedDescription)"
                    self.reloadPassport()
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
            withAnimation(.easeInOut(duration: 0.15)) { toastText = nil }
        }
    }
}

// =====================================================
// MARK: - Star Power Logic
// =====================================================
fileprivate struct StarPowerLogic {
    let inviteCount: Int

    let rainbowColors: [Color] = [
        .white, .red, .orange, .yellow, .green, .blue,
        Color(red: 75/255, green: 0/255, blue: 130/255),
        .purple
    ]

    private var maxLevel: Int { max(0, rainbowColors.count - 1) }

    var level: Int {
        let raw = inviteCount / 5
        return min(maxLevel, max(0, raw))
    }

    var colorName: String {
        switch level {
        case 0: return "White"
        case 1: return "Red"
        case 2: return "Orange"
        case 3: return "Yellow"
        case 4: return "Green"
        case 5: return "Blue"
        case 6: return "Indigo"
        default: return "Violet"
        }
    }

    var nextInText: String {
        if level >= maxLevel { return "MAX" }
        let nextThreshold = (level + 1) * 5
        let remaining = max(0, nextThreshold - inviteCount)
        return "\(remaining)"
    }

    var levelText: String {
        if level >= maxLevel { return "MAX" }
        return "\(level)/\(maxLevel)"
    }

    var progress: CGFloat {
        if maxLevel == 0 { return 0 }
        if level >= maxLevel { return 1.0 }

        let base = CGFloat(level) / CGFloat(maxLevel)
        let withinBucket = inviteCount % 5
        let micro = CGFloat(withinBucket) / 5.0
        let step = 1.0 / CGFloat(maxLevel)
        return max(0, min(1.0, base + (micro * step)))
    }
}

// =====================================================
// MARK: - Ticket Model used by Passport
// Refund UI prepped only: looks for "status" == "refunded"
// but will not break if backend does not set it.
// =====================================================
struct PassportTicketItem: Identifiable, Equatable {
    let id: String

    let eventId: String
    let eventTitle: String
    let eventImagePath: String

    let type: String
    let quantity: Int
    let totalAmount: Double

    let eventTimeUnix: TimeInterval
    let purchasedAtUnix: TimeInterval

    // Refund UI prep (optional fields)
    let status: String
    let refundedAtUnix: TimeInterval
    let refundAmount: Double

    var isRefunded: Bool {
        let s = status.lowercased()
        return s == "refunded" || s == "refund" || s == "reversed"
    }

    var isUpcoming: Bool {
        guard eventTimeUnix > 0 else { return true }
        return Date().timeIntervalSince1970 < eventTimeUnix
    }

    var eventDate: Date? {
        guard eventTimeUnix > 0 else { return nil }
        return Date(timeIntervalSince1970: eventTimeUnix)
    }

    static func fromFallbackDict(id: String, dict: [String: Any]) -> PassportTicketItem {
        let eventId = (dict["eventId"] as? String) ?? ""
        let title = (dict["eventTitle"] as? String)
            ?? (dict["eventName"] as? String)
            ?? "Event"

        let imagePath = (dict["eventImagePath"] as? String)
            ?? (dict["imagePath"] as? String)
            ?? ""

        let type = (dict["type"] as? String) ?? (dict["purchaseType"] as? String) ?? "ticket"

        let qty: Int = {
            if let i = dict["quantity"] as? Int { return i }
            if let n = dict["quantity"] as? NSNumber { return n.intValue }
            if let d = dict["quantity"] as? Double { return Int(d) }
            if let s = dict["quantity"] as? String { return Int(s) ?? 0 }
            return 0
        }()

        let total: Double = {
            if let d = dict["totalAmount"] as? Double { return d }
            if let i = dict["totalAmount"] as? Int { return Double(i) }
            if let n = dict["totalAmount"] as? NSNumber { return n.doubleValue }
            if let d = dict["totalWithFee"] as? Double { return d }
            if let s = dict["totalAmount"] as? String { return Double(s) ?? 0 }
            return 0
        }()

        let eventTime: Double = {
            if let d = dict["eventTime"] as? Double { return d }
            if let i = dict["eventTime"] as? Int { return Double(i) }
            if let n = dict["eventTime"] as? NSNumber { return n.doubleValue }
            if let d = dict["eventTimeUnix"] as? Double { return d }
            if let s = dict["eventTime"] as? String { return Double(s) ?? 0 }
            return 0
        }()

        let purchasedAt: Double = {
            if let d = dict["purchasedAt"] as? Double { return d }
            if let i = dict["purchasedAt"] as? Int { return Double(i) }
            if let n = dict["purchasedAt"] as? NSNumber { return n.doubleValue }
            if let d = dict["timestamp"] as? Double { return d }
            if let s = dict["purchasedAt"] as? String { return Double(s) ?? Date().timeIntervalSince1970 }
            return Date().timeIntervalSince1970
        }()

        // Refund UI prep fields
        let status: String = {
            if let s = dict["status"] as? String { return s }
            if let s = dict["paymentStatus"] as? String { return s }
            return "succeeded"
        }()

        let refundedAt: Double = {
            if let d = dict["refundedAt"] as? Double { return d }
            if let i = dict["refundedAt"] as? Int { return Double(i) }
            if let n = dict["refundedAt"] as? NSNumber { return n.doubleValue }
            if let s = dict["refundedAt"] as? String { return Double(s) ?? 0 }
            return 0
        }()

        let refundAmount: Double = {
            if let d = dict["refundAmount"] as? Double { return d }
            if let i = dict["refundAmount"] as? Int { return Double(i) }
            if let n = dict["refundAmount"] as? NSNumber { return n.doubleValue }
            if let s = dict["refundAmount"] as? String { return Double(s) ?? 0 }
            return 0
        }()

        return PassportTicketItem(
            id: id,
            eventId: eventId,
            eventTitle: title,
            eventImagePath: imagePath,
            type: type,
            quantity: qty,
            totalAmount: total,
            eventTimeUnix: eventTime,
            purchasedAtUnix: purchasedAt,
            status: status,
            refundedAtUnix: refundedAt,
            refundAmount: refundAmount
        )
    }
}

// =====================================================
// MARK: - Ticket Card
// =====================================================
fileprivate struct PassportTicketCard: View {
    let item: PassportTicketItem
    let onTap: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                PassportStorageImageView(imagePath: item.eventImagePath)
                    .frame(height: 210)
                    .clipped()

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 92)
                .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        pill(text: item.type.uppercased(), tint: .white.opacity(0.12))

                        // Refund UI prepared (won’t show unless backend sets status)
                        if item.isRefunded {
                            pill(text: "REFUNDED", tint: .red.opacity(0.25))
                        } else {
                            pill(text: item.isUpcoming ? "UPCOMING" : "PAST",
                                 tint: item.isUpcoming ? .green.opacity(0.18) : .white.opacity(0.10))
                        }
                        Spacer()
                    }

                    Text(item.eventTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    if let d = item.eventDate {
                        Text(Self.dateFormatter.string(from: d))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.82))
                    } else {
                        Text("Ticket")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.82))
                    }

                    HStack {
                        Text("Qty \(item.quantity)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.90))
                        Spacer()
                        Text("$\(String(format: "%.2f", item.totalAmount))")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.90))
                    }
                }
                .padding(10)

                if item.isRefunded {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

// =====================================================
// MARK: - Upcoming Horizontal Card
// =====================================================
fileprivate struct PassportUpcomingCard: View {
    let item: PassportTicketItem
    let onTap: () -> Void

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                PassportStorageImageView(imagePath: item.eventImagePath)
                    .frame(width: 160, height: 120)
                    .clipped()

                LinearGradient(colors: [Color.clear, Color.black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 56)
                    .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    if item.isRefunded {
                        Text("REFUNDED")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.25))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }

                    Text(item.eventTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    if let d = item.eventDate {
                        Text(Self.df.string(from: d))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
                .padding(8)

                if item.isRefunded {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// =====================================================
// MARK: - Ticket Detail (Proof + Hide/Delete)
// =====================================================
fileprivate struct PassportTicketDetailView: View {
    let item: PassportTicketItem
    let onHide: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static let shortDF: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    ZStack(alignment: .topTrailing) {
                        PassportStorageImageView(imagePath: item.eventImagePath)
                            .frame(height: 360)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                .padding(12)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(item.eventTitle)
                                .font(.title3.weight(.bold))
                                .foregroundColor(.white)
                            Spacer()
                            if item.isRefunded {
                                Text("REFUNDED")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.25), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                            }
                        }

                        if let d = item.eventDate {
                            Text(Self.df.string(from: d))
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.82))
                        }

                        HStack(spacing: 10) {
                            badge("Type", item.type.uppercased())
                            badge("Qty", "\(item.quantity)")
                            badge("Total", "$\(String(format: "%.2f", item.totalAmount))")
                        }

                        // Refund UI prepared (only shows if status becomes refunded later)
                        if item.isRefunded {
                            VStack(alignment: .leading, spacing: 6) {
                                if item.refundedAtUnix > 0 {
                                    Text("Refunded: \(Self.shortDF.string(from: Date(timeIntervalSince1970: item.refundedAtUnix)))")
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.80))
                                }
                                if item.refundAmount > 0 {
                                    Text("Refund Amount: $\(String(format: "%.2f", item.refundAmount))")
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.80))
                                }
                                Text("This ticket is no longer valid.")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.red.opacity(0.92))
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.red.opacity(0.25), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 2)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Proof of Purchase")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Ticket ID: \(item.id)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.80))
                            .textSelection(.enabled)

                        if !item.eventId.isEmpty {
                            Text("Event ID: \(item.eventId)")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.70))
                                .textSelection(.enabled)
                        }

                        Text("Status: \(item.status)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.70))
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(spacing: 10) {
                        Button {
                            onHide()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "eye.slash")
                                Text("Hide from Passport")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onDelete()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Permanently")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.red.opacity(0.30), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
        }
    }

    private func badge(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// =====================================================
// MARK: - Firebase Storage image loader (path-based)
// =====================================================
fileprivate struct PassportStorageImageView: View {
    let imagePath: String

    @State private var url: URL?
    @State private var failed: Bool = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.04)

            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.white)
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else if failed || imagePath.isEmpty {
                fallback
            } else {
                ProgressView().tint(.white)
                    .onAppear { resolve() }
            }
        }
    }

    private var fallback: some View {
        ZStack {
            Color.white.opacity(0.05)
            Image(systemName: "photo")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.65))
        }
    }

    private func resolve() {
        guard !imagePath.isEmpty else { failed = true; return }
        let ref = Storage.storage().reference(withPath: imagePath)
        ref.downloadURL { u, _ in
            DispatchQueue.main.async {
                if let u = u {
                    self.url = u
                } else {
                    self.failed = true
                }
            }
        }
    }
}

// =====================================================
// MARK: - UIKit share sheet wrapper
// =====================================================
fileprivate struct PassportActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
