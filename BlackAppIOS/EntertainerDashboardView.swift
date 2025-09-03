import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions
import UIKit

// MARK: - Model (renamed to avoid collisions elsewhere)
struct EntertainerProfileModel: Identifiable, Codable {
    var id: String
    var stageName: String
    var approved: Bool
    var bio: String?
    var instagram: String?
    var tiktok: String?
    var website: String?
    var rate: Double?
    var payoutMethod: String?      // forced to "PayPal" on save
    var payoutDetails: String?     // PayPal email
}

// Optional gig model for the list
struct EntertainerGig: Identifiable {
    let id: String
    let nightId: String
    let venueName: String
    let date: Date
    let status: String
    let role: String?
    let compensation: Double?
}

struct EntertainerDashboardScreen: View {

    // MARK: - State
    @State private var profile: EntertainerProfileModel?
    @State private var upcomingGigs: [EntertainerGig] = []
    @State private var monthEarnings: Double = 0
    @State private var totalGigsThisMonth: Int = 0
    @State private var avgRate: Double = 0
    @State private var followers: Int = 0 // placeholder—wire to your social/metrics source
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showManageSheet = false

    // UI
    @State private var searchText: String = ""
    @State private var selectedTab: Int = 0

    // Actions wiring
    @State private var showOfferSheet = false
    @State private var showPayoutSheet = false
    @State private var showCalendarSheet = false
    @State private var bannerMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                actionTiles
                analyticsSection
                gigsSection
                profileSection
                toolsSection
            }
            .padding()
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color(red: 0.11, green: 0.05, blue: 0.18)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .preferredColorScheme(ColorScheme.dark)
        .onAppear { bootstrap() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showManageSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        // Settings
        .sheet(isPresented: $showManageSheet) {
            NavigationView {
                Form {
                    Section(header: Text("Dashboard Settings")) {
                        Picker("Quick Actions Layout", selection: $selectedTab) {
                            Text("Default").tag(0)
                            Text("Compact").tag(1)
                        }
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showManageSheet = false }
                    }
                }
            }
            .preferredColorScheme(ColorScheme.dark)
        }
        // Create Offer → now posts to Gossip (first) using the manager
        .sheet(isPresented: $showOfferSheet) {
            OfferComposerSheet(profile: profile) { textToShare in
                // Gossip-first share of the generated offer text
                if let presenter = UIApplication.shared.keyWindowTopMostController {
                    GossipShareManager.shared.presentShare(
                        from: presenter,
                        payload: .text(textToShare)
                    )
                }
            } onLogged: { ok in
                if ok { banner("Offer logged") }
            }
            .preferredColorScheme(.dark)
        }
        // Request Payout (PayPal only)
        .sheet(isPresented: $showPayoutSheet) {
            PayoutRequestSheet(profile: profile) { ok, msg in
                if ok { banner("Payout request submitted") }
                else if let msg { banner(msg) }
            }
            .preferredColorScheme(.dark)
        }
        // Calendar
        .sheet(isPresented: $showCalendarSheet) {
            CalendarListSheet(gigs: upcomingGigs)
                .preferredColorScheme(.dark)
        }
        // Banner (simple alert)
        .alert(bannerMessage ?? "", isPresented: Binding(get: { bannerMessage != nil },
                                                         set: { _ in bannerMessage = nil })) {
            Button("OK", role: .cancel) { }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.25))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .stroke(LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        )
                    Image(systemName: "music.mic")
                        .font(.system(size: 24, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile?.stageName.isEmpty == false ? profile?.stageName ?? "" : "Entertainer")
                        .font(.title2).bold()
                    HStack(spacing: 8) {
                        statusPill(text: profile?.approved == true ? "approved" : "pending")
                        if let rate = profile?.rate {
                            Text("$\(Int(rate))/hr")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
                Spacer()
                Button {
                    saveProfile()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().scaleEffect(0.8) }
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
    }

    // MARK: - Quick Actions (Gossip-first wiring)
    private var actionTiles: some View {
        GlassGrid {
            ActionTile(title: "Create Offer", systemImage: "sparkles") {
                showOfferSheet = true
            }
            ActionTile(title: "Request Payout", systemImage: "banknote") {
                showPayoutSheet = true
            }
            ActionTile(title: "Share Booking Link", systemImage: "link") {
                if let url = URL(string: buildBookingLink()) {
                    if let presenter = UIApplication.shared.keyWindowTopMostController {
                        GossipShareManager.shared.presentShare(
                            from: presenter,
                            payload: .link(url: url, text: "Book \(profile?.stageName ?? "me")")
                        )
                    }
                } else {
                    banner("Couldn’t build your booking link")
                }
            }
            ActionTile(title: "Open Calendar", systemImage: "calendar") {
                showCalendarSheet = true
            }
        }
    }

    // MARK: - Analytics
    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analytics")
                .font(.title3).bold()
                .padding(.horizontal, 4)

            GlassGrid {
                MetricTile(title: "Gigs (Mo.)", value: "\(totalGigsThisMonth)")
                MetricTile(title: "Earnings (Mo.)", value: "$\(Int(monthEarnings))")
                MetricTile(title: "Avg Rate", value: "$\(Int(avgRate))/hr")
                MetricTile(title: "Followers", value: "\(followers)")
            }
        }
    }

    // MARK: - Gigs (adds share-to-Gossip on each row)
    private var gigsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming Gigs")
                .font(.title3).bold()
                .padding(.horizontal, 4)

            if upcomingGigs.isEmpty {
                GlassCard {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                        Text("No upcoming gigs yet.")
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                    }
                }
            } else {
                ForEach(upcomingGigs) { gig in
                    GlassCard {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(gig.venueName).bold()
                                Text(dateFormatter.string(from: gig.date))
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                                HStack(spacing: 8) {
                                    statusPill(text: gig.status)
                                    if let role = gig.role, !role.isEmpty {
                                        Text(role.capitalized)
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                    }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                if let comp = gig.compensation {
                                    Text("$\(Int(comp))")
                                        .font(.headline)
                                }
                                // Gossip-first share for this specific gig
                                Button {
                                    if let presenter = UIApplication.shared.keyWindowTopMostController,
                                       let url = URL(string: buildNightDeepLink(nightId: gig.nightId)) {
                                        let caption = makeGigShareCaption(gig: gig)
                                        GossipShareManager.shared.presentShare(
                                            from: presenter,
                                            payload: .link(url: url, text: caption)
                                        )
                                    }
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Profile Editor (PayPal-only UI)
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile")
                .font(.title3).bold()
                .padding(.horizontal, 4)

            GlassCard {
                VStack(spacing: 12) {
                    HStack {
                        Text("Stage Name").font(.subheadline)
                        Spacer()
                    }
                    TextField("e.g. DJ Nova", text: Binding(
                        get: { profile?.stageName ?? "" },
                        set: { setProfile(\.stageName, $0) }
                    ))
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("Bio").font(.subheadline)
                        Spacer()
                    }
                    TextEditor(text: Binding(
                        get: { profile?.bio ?? "" },
                        set: { setProfile(\.bio, $0) }
                    ))
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))

                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("Instagram").font(.subheadline)
                            TextField("@handle", text: Binding(
                                get: { profile?.instagram ?? "" },
                                set: { setProfile(\.instagram, $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading) {
                            Text("TikTok").font(.subheadline)
                            TextField("@handle", text: Binding(
                                get: { profile?.tiktok ?? "" },
                                set: { setProfile(\.tiktok, $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Website").font(.subheadline)
                        TextField("https://", text: Binding(
                            get: { profile?.website ?? "" },
                            set: { setProfile(\.website, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("Default Rate ($/hr)").font(.subheadline)
                            TextField("0", text: Binding(
                                get: { String(Int(profile?.rate ?? 0)) },
                                set: { setProfile(\.rate, Double($0) ?? 0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                        }
                    }

                    // PAYPAL ONLY
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "p.circle.fill").foregroundColor(.blue)
                            Text("PayPal (required)").font(.subheadline).bold()
                        }
                        TextField("PayPal email", text: Binding(
                            get: { profile?.payoutDetails ?? "" },
                            set: { setProfile(\.payoutDetails, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    }

                    HStack {
                        if let err = saveError {
                            Text(err).foregroundColor(.red)
                        }
                        Spacer()
                        Button {
                            saveProfile()
                        } label: {
                            HStack(spacing: 6) {
                                if isSaving { ProgressView().scaleEffect(0.8) }
                                Image(systemName: "square.and.arrow.down")
                                Text("Save Profile")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                    }
                }
            }
        }
    }

    // MARK: - Tools
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.title3).bold()
                .padding(.horizontal, 4)

            GlassGrid {
                ActionTile(title: "My Contracts", systemImage: "doc.text") {
                    // Log an intent & show banner (placeholder)
                    logActivity(type: "contracts_opened", payload: [:])
                    banner("Contracts coming soon")
                }
                ActionTile(title: "Templates", systemImage: "square.grid.2x2") {
                    logActivity(type: "templates_opened", payload: [:])
                    banner("Templates coming soon")
                }
                ActionTile(title: "Promo Assets", systemImage: "photo.on.rectangle") {
                    logActivity(type: "promo_assets_opened", payload: [:])
                    banner("Promo assets coming soon")
                }
                ActionTile(title: "Help & Support", systemImage: "questionmark.circle") {
                    // Opens supportMessages with a stub so admins can follow up
                    submitSupportMessage("Entertainer needs help with dashboard")
                    banner("Support pinged")
                }
            }
        }
    }

    // MARK: - Data Bootstrap
    private func bootstrap() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Database.database().reference()

        // Profile
        db.child("entertainers").child(uid).observeSingleEvent(of: .value) { snap in
            if let dict = snap.value as? [String: Any] {
                let p = EntertainerProfileModel(
                    id: uid,
                    stageName: dict["stageName"] as? String ?? "",
                    approved: dict["approved"] as? Bool ?? false,
                    bio: dict["bio"] as? String,
                    instagram: dict["instagram"] as? String,
                    tiktok: dict["tiktok"] as? String,
                    website: dict["website"] as? String,
                    rate: (dict["rate"] as? NSNumber)?.doubleValue ?? dict["rate"] as? Double,
                    payoutMethod: "PayPal",
                    payoutDetails: dict["payoutDetails"] as? String
                )
                self.profile = p
                self.avgRate = p.rate ?? 0
            } else {
                self.profile = EntertainerProfileModel(id: uid, stageName: "", approved: false)
            }
        }

        // Gigs for this entertainer (lineupsByEntertainer/<uid> => { nightId: "slotId" })
        db.child("lineupsByEntertainer").child(uid).observeSingleEvent(of: .value) { snap in
            var gigs: [EntertainerGig] = []

            let group = DispatchGroup()
            for case let child as DataSnapshot in snap.children {
                let nightId = child.key
                group.enter()
                // load the night + venue to display
                db.child("nights").child(nightId).observeSingleEvent(of: .value) { nightSnap in
                    defer { group.leave() }
                    guard let nightDict = nightSnap.value as? [String: Any] else { return }
                    let ts = (nightDict["date"] as? TimeInterval)
                              ?? (nightDict["startAt"] as? TimeInterval)
                              ?? 0
                    let venueId = nightDict["venueId"] as? String ?? ""
                    let date = Date(timeIntervalSince1970: ts)

                    // fetch venue name (optional)
                    var venueName = "Venue"
                    if !venueId.isEmpty {
                        db.child("venues").child(venueId).observeSingleEvent(of: .value) { vSnap in
                            if let vDict = vSnap.value as? [String: Any],
                               let name = vDict["name"] as? String {
                                venueName = name
                            }
                        }
                    }

                    // lineup slot details (status/role/comp) if available
                    var status = "pending"
                    var role: String? = nil
                    var comp: Double? = nil
                    if let slotId = child.value as? String {
                        db.child("lineups").child(nightId).child(slotId).observeSingleEvent(of: .value) { sSnap in
                            if let s = sSnap.value as? [String: Any] {
                                status = s["status"] as? String ?? status
                                role = s["role"] as? String
                                comp = (s["compensation"] as? NSNumber)?.doubleValue ?? s["compensation"] as? Double
                            }
                        }
                    }

                    gigs.append(
                        EntertainerGig(
                            id: nightId,
                            nightId: nightId,
                            venueName: venueName,
                            date: ts > 0 ? date : Date(),
                            status: status,
                            role: role,
                            compensation: comp
                        )
                    )
                }
            }
            group.notify(queue: .main) {
                // future gigs
                let future = gigs.filter { $0.date >= Date().addingTimeInterval(-86400) }
                self.upcomingGigs = future.sorted(by: { $0.date < $1.date })

                // quick stats
                let cal = Calendar.current
                let month = cal.component(.month, from: Date())
                let thisMonth = future.filter { cal.component(.month, from: $0.date) == month }
                self.totalGigsThisMonth = thisMonth.count
                self.monthEarnings = thisMonth.compactMap { $0.compensation }.reduce(0, +)
            }
        }

        // followers (placeholder—replace with real source)
        followers = Int.random(in: 400...1200)
    }

    // MARK: - Save
    private func saveProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard let p = profile else { return }
        isSaving = true
        saveError = nil

        // Enforce PayPal-only
        let paypalEmail = (p.payoutDetails ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if paypalEmail.isEmpty || !paypalEmail.contains("@") {
            isSaving = false
            saveError = "Please add a valid PayPal email."
            banner("Add a valid PayPal email")
            return
        }

        var payload: [String: Any] = [
            "stageName": p.stageName,
            "approved": p.approved,
            "payoutMethod": "PayPal",
            "payoutDetails": paypalEmail
        ]
        if let bio = p.bio { payload["bio"] = bio }
        if let ig = p.instagram { payload["instagram"] = ig }
        if let tt = p.tiktok { payload["tiktok"] = tt }
        if let web = p.website { payload["website"] = web }
        if let rate = p.rate { payload["rate"] = rate }

        let ref = Database.database().reference().child("entertainers").child(uid)
        ref.updateChildValues(payload) { err, _ in
            self.isSaving = false
            if let err = err {
                self.saveError = err.localizedDescription
            } else {
                banner("Profile saved")
            }
        }
    }

    // MARK: - Helpers
    private func buildBookingLink() -> String {
        guard let uid = Auth.auth().currentUser?.uid else { return "https://blackapp.app/" }
        // Simple deep link for now. Replace with your real hosted route if needed.
        return "https://blackapp.app/entertainer/\(uid)"
    }

    private func buildNightDeepLink(nightId: String) -> String {
        // A simple, stable deep link that the web/app can resolve.
        return "https://blackapp.app/night/\(nightId)"
    }

    private func makeGigShareCaption(gig: EntertainerGig) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let when = fmt.string(from: gig.date)
        let who = profile?.stageName ?? "I"
        if let role = gig.role, !role.isEmpty {
            return "\(who) (\(role)) — \(gig.venueName) • \(when)"
        } else {
            return "\(who) — \(gig.venueName) • \(when)"
        }
    }

    private func logActivity(type: String, payload: [String: Any]) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("activityLogs").childByAutoId()
        var base: [String: Any] = [
            "type": type,
            "userId": uid,
            "createdAt": ServerValue.timestamp()
        ]
        payload.forEach { base[$0.key] = $0.value }
        ref.setValue(base)
    }

    private func submitSupportMessage(_ text: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("supportMessages").childByAutoId()
        let payload: [String: Any] = [
            "userId": uid,
            "message": text,
            "timestamp": Date().timeIntervalSince1970,
            "status": "unread",
            "name": profile?.stageName ?? "",
            "email": profile?.payoutDetails ?? "" // best-known contact
        ]
        ref.setValue(payload)
    }

    private func banner(_ text: String) {
        bannerMessage = text
    }

    // MARK: - Small setters
    private func setProfile<T>(_ keyPath: WritableKeyPath<EntertainerProfileModel, T?>, _ value: T?) {
        if profile == nil, let uid = Auth.auth().currentUser?.uid {
            profile = EntertainerProfileModel(id: uid, stageName: "", approved: false)
        }
        profile?[keyPath: keyPath] = value
    }
    private func setProfile(_ keyPath: WritableKeyPath<EntertainerProfileModel, String>, _ value: String) {
        if profile == nil, let uid = Auth.auth().currentUser?.uid {
            profile = EntertainerProfileModel(id: uid, stageName: "", approved: false)
        }
        profile?[keyPath: keyPath] = value
    }
    private func setProfile(_ keyPath: WritableKeyPath<EntertainerProfileModel, Double?>, _ value: Double?) {
        if profile == nil, let uid = Auth.auth().currentUser?.uid {
            profile = EntertainerProfileModel(id: uid, stageName: "", approved: false)
        }
        profile?[keyPath: keyPath] = value
    }

    // MARK: - UI bits
    private func statusPill(text: String) -> some View {
        let color: Color = {
            switch text.lowercased() {
            case "approved": return .green
            case "pending":  return .orange
            case "rejected": return .red
            default:         return .gray
            }
        }()

        return Text(text.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }
}

// MARK: - Reusable “glass” UI components
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 8)
            )
    }
}

private struct GlassGrid<Content: View>: View {
    @ViewBuilder var content: Content
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            content
        }
    }
}

private struct ActionTile: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.purple.opacity(0.35), .blue.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                }
                Text(title).bold()
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.title3).bold()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}

// MARK: - Offer Composer Sheet

private struct OfferComposerSheet: View {
    var profile: EntertainerProfileModel?
    var onShare: (String) -> Void
    var onLogged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var eventName: String = ""
    @State private var date: Date = Date()
    @State private var location: String = ""
    @State private var rateText: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event")) {
                    TextField("Event name", text: $eventName)
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Location / Venue", text: $location)
                }
                Section(header: Text("Offer")) {
                    TextField("Rate (USD)", text: $rateText).keyboardType(.numberPad)
                    TextEditor(text: $notes).frame(minHeight: 100)
                }
                Section {
                    Button("Create & Share") { share() }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Create Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func share() {
        let rate = Double(rateText) ?? 0
        let name = profile?.stageName ?? "Entertainer"
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short
        var lines: [String] = []
        lines.append("\(name) – Offer")
        if !eventName.isEmpty { lines.append("Event: \(eventName)") }
        lines.append("Date: \(fmt.string(from: date))")
        if !location.isEmpty { lines.append("Location: \(location)") }
        if rate > 0 { lines.append(String(format: "Rate: $%.0f", rate)) }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(""); lines.append(notes)
        }
        let text = lines.joined(separator: "\n")

        // Log to activityLogs
        if let uid = Auth.auth().currentUser?.uid {
            let ref = Database.database().reference().child("activityLogs").childByAutoId()
            let payload: [String: Any] = [
                "type": "entertainer_offer_created",
                "userId": uid,
                "createdAt": ServerValue.timestamp(),
                "eventName": eventName,
                "date": date.timeIntervalSince1970,
                "location": location,
                "rate": rate
            ]
            ref.setValue(payload) { err, _ in
                onLogged(err == nil)
            }
        }

        onShare(text)
        dismiss()
    }
}

// MARK: - Payout Request Sheet (PayPal only)

private struct PayoutRequestSheet: View {
    var profile: EntertainerProfileModel?
    var onDone: (Bool, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String = ""
    @State private var paypalEmail: String = ""
    @State private var submitting = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("PayPal")) {
                    TextField("PayPal email", text: $paypalEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Payout")) {
                    TextField("Amount (USD)", text: $amountText)
                        .keyboardType(.decimalPad)
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        if submitting { ProgressView() } else { Text("Submit Payout Request") }
                    }
                    .disabled(!isValid || submitting)
                }
            }
            .navigationTitle("Request Payout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                paypalEmail = profile?.payoutDetails ?? ""
            }
        }
    }

    private var isValid: Bool {
        let amt = Double(amountText) ?? 0
        return amt > 0 && paypalEmail.contains("@")
    }

    private func submit() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let amount = Double(amountText) ?? 0
        submitting = true

        // Write under paymentLogs (allowed to write by your rules)
        let ref = Database.database().reference().child("paymentLogs").child("payoutRequests").childByAutoId()
        let payload: [String: Any] = [
            "userId": uid,
            "amount": amount,
            "method": "PayPal",
            "paypalEmail": paypalEmail,
            "status": "submitted",
            "createdAt": ServerValue.timestamp()
        ]
        ref.setValue(payload) { err, _ in
            submitting = false
            if let err = err {
                onDone(false, err.localizedDescription)
            } else {
                onDone(true, nil)
                dismiss()
            }
        }
    }
}

// MARK: - Calendar List Sheet

private struct CalendarListSheet: View {
    let gigs: [EntertainerGig]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(gigs) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.venueName).bold()
                        Text(g.date, style: .date) + Text(" • ") + Text(g.date, style: .time)
                        Text(g.status.capitalized).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("My Calendar")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Share Sheet

private struct BAActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
