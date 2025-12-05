import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase
import FeedKit
import WebKit
import UIKit

// MARK: - EventModel

struct EventModel: Identifiable {
    var id: String
    var title: String
    var description: String
    var imagePath: String
    var date: Date
    var payoutMethod: String
    var payoutDetails: String
    var ticketPrice: Double
    var ticketQuantity: Int
    var tablePrice: Double
    var tableQuantity: Int
    var userId: String
    var location: String
    var ticketsSold: Int
    var tablesSold: Int
    var isFree: Bool

    static func from(snapshot: DataSnapshot) -> EventModel? {
        guard let value = snapshot.value as? [String: Any],
              let title = value["title"] as? String,
              let description = value["description"] as? String,
              let imagePath = value["imagePath"] as? String,
              let timestamp = value["date"] as? TimeInterval,
              let userId = value["userId"] as? String else {
            return nil
        }

        func toDouble(_ val: Any?) -> Double {
            if let d = val as? Double { return d }
            if let i = val as? Int { return Double(i) }
            if let s = val as? String, let d = Double(s) { return d }
            return 0.0
        }

        func toInt(_ val: Any?) -> Int {
            if let i = val as? Int { return i }
            if let s = val as? String, let i = Int(s) { return i }
            if let d = val as? Double { return Int(d) }
            return 0
        }

        return EventModel(
            id: snapshot.key,
            title: title,
            description: description,
            imagePath: imagePath,
            date: Date(timeIntervalSince1970: timestamp),
            payoutMethod: value["payoutMethod"] as? String ?? "",
            payoutDetails: value["payoutDetails"] as? String ?? "",
            ticketPrice: toDouble(value["ticketPrice"]),
            ticketQuantity: toInt(value["ticketQuantity"]),
            tablePrice: toDouble(value["tablePrice"]),
            tableQuantity: toInt(value["tableQuantity"]),
            userId: userId,
            location: value["location"] as? String ?? "",
            ticketsSold: toInt(value["ticketsSold"]),
            tablesSold: toInt(value["tablesSold"]),
            isFree: value["isFree"] as? Bool ?? false
        )
    }
}

// MARK: - EventTabView (compact chrome + toolbar icons + FAB)
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase

struct EventTabView: View {
    @State private var selectedTab = 0
    @State private var showCreate = false

    // Hints: preference vs. visibility
    @AppStorage("toolbarHintsEnabled") private var toolbarHintsEnabled = true
    @State private var showToolbarHints = false
    @State private var hintHideWorkItem: DispatchWorkItem?
    private let hintDuration: TimeInterval = 10 // ~4× longer

    // Promoter Dashboard state
    @State private var isPromoterUser = false
    @State private var showPromoterSheet = false

    // Nightlife entry state
    @State private var showNightlife = false

    // Use a FAB to keep the toolbar clean
    private let useFAB = true

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 8) {
                    Picker("View", selection: $selectedTab) {
                        Text("All Events").tag(0)
                        Text("My Events").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Group {
                        if selectedTab == 0 {
                            EventFeedView()
                        } else {
                            MyEventsView()
                        }
                    }
                    .padding(.top, 4)
                }
                .overlay(
                    VStack {
                        HStack {
                            Spacer()
                            if showToolbarHints {
                                VStack(alignment: .trailing, spacing: 6) {
                                    if isPromoterUser {
                                        hintBubble(icon: "star.fill",
                                                   text: "Promoter Dashboard — manage events, sales & stats")
                                    }
                                    hintBubble(icon: "sparkles",
                                               text: "Nightlife — browse venues, guestlists & reservations")
                                }
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .padding(.trailing, 8)
                                .padding(.top, 4)
                            }
                        }
                        Spacer()
                    }
                )

                if useFAB {
                    VStack {
                        Spacer()
                        HStack {
                            Button(action: { showCreate = true }) {
                                Image(systemName: "plus")
                                    .font(.title2)
                                    .padding()
                                    .background(Circle().fill(Color.blue))
                                    .foregroundColor(.white)
                                    .shadow(radius: 6)
                            }
                            .padding(.leading, 16) // left
                            Spacer()
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .navigationBarTitle("Events", displayMode: .inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showNightlife = true }) {
                        Image(systemName: "sparkles")
                    }
                    .onLongPressGesture { triggerToolbarHints(duration: hintDuration) }

                    if isPromoterUser {
                        Button(action: { showPromoterSheet = true }) {
                            Image(systemName: "star.fill")
                        }
                        .onLongPressGesture { triggerToolbarHints(duration: hintDuration) }
                    }

                    if !useFAB {
                        Button(action: { showCreate = true }) {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreate) { CreateEventView() }
            .sheet(isPresented: $showPromoterSheet) { PromoterDashboardView() }
            .sheet(isPresented: $showNightlife) { NightlifeHomeView() }
        }
        .onAppear {
            refreshPromoterFlag()
            triggerToolbarHints(duration: hintDuration)
        }
    }

    // MARK: - Hint UI
    private func hintBubble(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Button("Never show again") {
                disableHints()
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.65))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 2)
    }

    private func triggerToolbarHints(duration: TimeInterval) {
        guard toolbarHintsEnabled else { return }
        hintHideWorkItem?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { showToolbarHints = true }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.35)) { showToolbarHints = false }
        }
        hintHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func disableHints() {
        hintHideWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { showToolbarHints = false }
        toolbarHintsEnabled = false
    }

    // MARK: - Promoter check
    private func refreshPromoterFlag() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isPromoterUser = false
            return
        }
        let ref = Database.database().reference().child("promoters").child(uid)
        ref.observeSingleEvent(of: .value) { snap in
            self.isPromoterUser = snap.exists()
        }
    }
}

// Reusable, subtle hint chip
private struct HintChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6).opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}


import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import CoreImage.CIFilterBuiltins

// MARK: - Unified ticket model for wallet
struct UnifiedPurchase: Identifiable, Equatable {
    let id: String                      // purchase/order id
    let userId: String
    let eventId: String
    var eventTitle: String
    var eventImagePath: String          // for platform; for EB we store external image URL here
    var quantity: Int
    var type: String                    // "ticket" | "table" | etc.
    var totalAmount: Double
    var timestamp: TimeInterval         // purchase time or event time fallback

    // Enrichment / external
    var source: String?                 // "eventbrite" for EB; nil or "platform" otherwise
    var orderId: String?                // EB order id
    var externalURL: String?            // EB event URL
    var barcode: String?                // EB attendee/order barcode (if present)
    var barcodeStatus: String?          // EB barcode status (optional)
    var eventISODate: String?           // EB imported event ISO date (if available)

    // Convenience
    var isEventbrite: Bool { (source ?? "").lowercased() == "eventbrite" }
}





/// Simple representation of an unclaimed EB order (from /api/eb/list-unclaimed)
fileprivate struct UnclaimedItem: Identifiable, Hashable, Decodable {
    var id: String { orderId }
    let orderId: String
    let eventId: String
    let email: String?
    let placedAt: String?
    let quantity: Int
    let totalAmount: Double
    let currency: String
    let status: String?
    let eventTitle: String?
    let eventImagePath: String?
}


// MARK: - MyEventsView (NO inner NavigationView; tighter spacing)

struct MyEventsView: View {
    @State private var myCreatedEvents: [EventModel] = []
    @State private var myPurchased: [UnifiedPurchase] = []

    // Unclaimed EB
    @State private var unclaimed: [UnclaimedItem] = []
    @State private var isClaimWorking = false
    @State private var claimError: String? = nil

    // Sheets / selections
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
    @State private var selectedEventToEdit: EventModel? = nil
    @State private var selectedEventForStats: EventModel? = nil

    // Platform ticket proof
    @State private var selectedPlatformPurchase: PurchaseModel? = nil
    // Eventbrite ticket proof
    @State private var selectedEBProof: UnifiedPurchase? = nil

    // 🔍 Debug banner
    @State private var debugWalletLoadedCount: Int = -1
    @State private var debugLastFetchNote: String = "–"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ===== Debug banner =====
                VStack(spacing: 6) {
                    Text("Wallet v2025-11-12").font(.caption2).foregroundColor(.gray)
                    Text("Loaded: \(debugWalletLoadedCount >= 0 ? String(debugWalletLoadedCount) : "…") • \(debugLastFetchNote)")
                        .font(.caption2).foregroundColor(.gray)
                }
                .padding(.top, 8)

                // ===== Unclaimed banner (if any) =====
                if !unclaimed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Eventbrite tickets found")
                            .font(.headline)
                        Text("We found \(unclaimed.count) Eventbrite order\(unclaimed.count == 1 ? "" : "s") for your email. Claim them to add to your wallet.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        HStack(spacing: 8) {
                            Button {
                                claimAllUnclaimed()
                            } label: {
                                Label(isClaimWorking ? "Claiming…" : "Claim all", systemImage: "arrow.down.doc")
                                    .font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.blue.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .disabled(isClaimWorking)

                            Menu {
                                ForEach(unclaimed) { item in
                                    Button("Claim \(item.orderId)") {
                                        claim(orderId: item.orderId)
                                    }
                                }
                            } label: {
                                Label("Claim individually", systemImage: "list.bullet")
                                    .font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.2))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                        if let err = claimError {
                            Text(err).font(.footnote).foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding([.leading, .trailing]) // avoid rare .horizontal inference error
                }

                // ===== Created by me =====
                Text("Events I’ve Created")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(myCreatedEvents) { event in
                    VStack(alignment: .leading, spacing: 10) {
                        EventCardView(event: event)

                        // compact action row
                        HStack(spacing: 8) {
                            Button(action: { selectedEventToEdit = event }) {
                                Label("Edit", systemImage: "pencil")
                                    .font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }

                            Button(action: { deleteEvent(event) }) {
                                Label("Delete", systemImage: "trash")
                                    .font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.red.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }

                            Button(action: { selectedEventForStats = event }) {
                                Label("Stats", systemImage: "chart.bar.fill")
                                    .font(.footnote)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }
                }

                Divider().padding(.vertical, 6)

                // ===== Purchased by me (platform + EB) =====
                Text("My Tickets & Purchases")
                    .font(.headline)
                    .padding(.horizontal)

                ForEach(myPurchased) { p in
                    WalletPurchaseCard(p: p,
                                       openPlatform: { platformPurchase in
                        selectedPlatformPurchase = platformPurchase
                    }, openEventbrite: { ebPurchase in
                        selectedEBProof = ebPurchase
                    })
                    .padding(.horizontal)
                }

                // Raw fallback renderer so you SEE rows even if a card view silently fails
                if debugWalletLoadedCount == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Raw Wallet (fallback)").font(.subheadline).foregroundColor(.gray)
                        ForEach(myPurchased) { p in
                            Text("• \(p.orderId ?? p.id) • \(p.eventTitle.isEmpty ? "(no title)" : p.eventTitle)")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 4)
        }
        .onAppear {
            fetchMyEvents()
            fetchMyPurchasedEventsUnified()
            fetchUnclaimedForUser()
        }
        // Sheets
        .sheet(item: $selectedEventToEdit) { event in
            EditEventView(event: event)
        }
        .sheet(item: $selectedEventForStats) { event in
            EventStatsView(event: event)
        }
        .sheet(item: $selectedPlatformPurchase) { purchase in
            ShowTicketView(purchase: purchase)
        }
        .sheet(item: $selectedEBProof) { (eb: UnifiedPurchase) in
            EBTicketProofView(purchase: eb)
        }
        .sheet(isPresented: $showWebView) {
            if let url = selectedURL {
                WebView(url: url).edgesIgnoringSafeArea(.all)
            }
        }
    }

    // MARK: Fetch Created
    private func fetchMyEvents() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("events")

        ref.observeSingleEvent(of: .value) { snapshot in
            var createdEvents: [EventModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let event = EventModel.from(snapshot: child),
                   event.userId == userId {
                    createdEvents.append(event)
                }
            }
            self.myCreatedEvents = createdEvents.sorted { $0.date > $1.date }
        }
    }

    // MARK: Fetch Purchases (unified)
    private func fetchMyPurchasedEventsUnified() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        print("👜 [Wallet] fetching for uid:", userId)

        let ref = Database.database().reference().child("purchases").child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            print("👜 [Wallet] snapshot.exists =", snapshot.exists(), "children =", snapshot.childrenCount)
            self.debugLastFetchNote = "exists=\(snapshot.exists()) children=\(snapshot.childrenCount)"

            var unified: [UnifiedPurchase] = []
            var enrichRequests: [(index: Int, eventId: String)] = []

            var idx = 0
            for case let child as DataSnapshot in snapshot.children {
                guard let value = child.value as? [String: Any] else { continue }

                let orderId = child.key
                let eventId = (value["eventId"] as? String) ?? ""
                let source  = (value["source"] as? String) ?? (value["provider"] as? String)
                let qty     = (value["quantity"] as? Int) ?? (value["qty"] as? Int) ?? 0

                // timestamp preference: explicit → ISO placedAt → now
                let ts: TimeInterval = {
                    if let t = value["timestamp"] as? TimeInterval { return t }
                    if let iso = value["placedAt"] as? String,
                       let d = ISO8601DateFormatter().date(from: iso) {
                        return d.timeIntervalSince1970
                    }
                    return Date().timeIntervalSince1970
                }()

                let eventISO = (value["eventISODate"] as? String)
                    ?? (value["start"] as? String)
                    ?? (value["starts_at"] as? String)

                var up = UnifiedPurchase(
                    id: orderId,
                    userId: userId,
                    eventId: eventId,
                    eventTitle: (value["eventTitle"] as? String) ?? (value["title"] as? String) ?? "",
                    eventImagePath: (value["eventImagePath"] as? String) ?? (value["imageURL"] as? String) ?? "",
                    quantity: qty,
                    type: (value["type"] as? String) ?? "ticket",
                    totalAmount: (value["totalAmount"] as? Double) ?? (value["total"] as? Double) ?? 0.0,
                    timestamp: ts,
                    source: source,
                    orderId: (value["orderId"] as? String) ?? orderId,
                    externalURL: value["externalURL"] as? String,
                    barcode: value["barcode"] as? String,
                    barcodeStatus: value["barcodeStatus"] as? String,
                    eventISODate: eventISO
                )
                unified.append(up)

                // Enrich EB items missing title/image/date
                if (up.source == "eventbrite" || up.isEventbrite),
                   (up.eventTitle.isEmpty || up.eventImagePath.isEmpty || up.eventISODate == nil),
                   !eventId.isEmpty {
                    enrichRequests.append((index: idx, eventId: eventId))
                }
                idx += 1
            }

            guard !enrichRequests.isEmpty else {
                let final = unified.sorted { $0.timestamp > $1.timestamp }
                self.myPurchased = final
                self.debugWalletLoadedCount = final.count
                print("👜 [Wallet] myPurchased count =", final.count)
                return
            }

            let db = Database.database().reference()
            let group = DispatchGroup()
            var enriched = unified

            for req in enrichRequests {
                group.enter()
                db.child("externalEvents").child("eventbrite").child(req.eventId)
                    .observeSingleEvent(of: .value) { snap in
                        defer { group.leave() }
                        guard let m = snap.value as? [String: Any] else { return }
                        if req.index < enriched.count {
                            var u = enriched[req.index]
                            if u.eventTitle.isEmpty, let t = m["title"] as? String { u.eventTitle = t }
                            if u.eventImagePath.isEmpty {
                                let img = (m["imageURL"] as? String) ?? (m["heroImage"] as? String) ?? ""
                                if !img.isEmpty { u.eventImagePath = img }
                            }
                            if u.eventISODate == nil, let d = m["date"] as? String { u.eventISODate = d }
                            enriched[req.index] = u
                        }
                    }
            }

            group.notify(queue: .main) {
                let final = enriched.sorted { $0.timestamp > $1.timestamp }
                self.myPurchased = final
                self.debugWalletLoadedCount = final.count
                print("👜 [Wallet] myPurchased count =", final.count)
            }
        }
    }

    // MARK: Unclaimed: list and claim

    private func fetchUnclaimedForUser() {
        guard let user = Auth.auth().currentUser else { return }
        user.getIDToken { token, err in
            guard let token = token else {
                print("❌ Unable to get ID token:", err?.localizedDescription ?? "")
                return
            }
            var req = URLRequest(url: URL(string: "https://blackappios.web.app/api/eb/list-unclaimed")!)
            req.httpMethod = "GET"
            req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, resp, error in
                guard let data = data, error == nil else { return }
                struct Resp: Decodable { let ok: Bool; let items: [UnclaimedItem]? }
                if let r = try? JSONDecoder().decode(Resp.self, from: data), r.ok {
                    DispatchQueue.main.async { self.unclaimed = r.items ?? [] }
                }
            }.resume()
        }
    }

    private func claimAllUnclaimed() {
        guard !unclaimed.isEmpty else { return }
        isClaimWorking = true
        claimError = nil

        let group = DispatchGroup()
        var failures: [String] = []
        for item in unclaimed {
            group.enter()
            claim(orderId: item.orderId) { ok in
                if !ok { failures.append(item.orderId) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.isClaimWorking = false
            if failures.isEmpty {
                self.fetchMyPurchasedEventsUnified()
                self.unclaimed.removeAll()
            } else {
                self.claimError = "Some orders failed to claim: \(failures.joined(separator: ", "))"
            }
        }
    }

    private func claim(orderId: String, completion: ((Bool) -> Void)? = nil) {
        Auth.auth().currentUser?.getIDToken(completion: { token, err in
            guard let token = token else {
                DispatchQueue.main.async {
                    self.claimError = "Auth error getting ID token."
                    completion?(false)
                }
                return
            }
            var req = URLRequest(url: URL(string: "https://blackappios.web.app/api/eb/claim")!)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let body = ["orderId": orderId]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            URLSession.shared.dataTask(with: req) { data, resp, error in
                let ok = (error == nil)
                DispatchQueue.main.async {
                    if !ok { self.claimError = "Failed to claim \(orderId)" }
                    self.fetchMyPurchasedEventsUnified()
                    self.fetchUnclaimedForUser()
                    completion?(ok)
                }
            }.resume()
        })
    }

    // MARK: Delete (platform)
    private func deleteEvent(_ event: EventModel) {
        let ref = Database.database().reference().child("events").child(event.id)
        ref.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to delete event: \(error.localizedDescription)")
            } else {
                self.myCreatedEvents.removeAll { $0.id == event.id }
            }
        }
    }
}

// MARK: - Wallet card for any purchase (platform or EB)

fileprivate struct WalletPurchaseCard: View {
    let p: UnifiedPurchase
    let openPlatform: (PurchaseModel) -> Void
    let openEventbrite: (UnifiedPurchase) -> Void

    private func formattedDate(_ p: UnifiedPurchase) -> String {
        if let iso = p.eventISODate, let d = ISO8601DateFormatter().date(from: iso) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: d)
        } else {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: Date(timeIntervalSince1970: p.timestamp))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Image (EB URL → AsyncImage; platform path → EventImageView; else gray)
            if p.isEventbrite, !p.eventImagePath.isEmpty, let url = URL(string: p.eventImagePath) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ZStack { Color.gray.opacity(0.2); ProgressView() }
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(height: 180)
                .clipped()
                .cornerRadius(10)
            } else if !p.isEventbrite, !p.eventImagePath.isEmpty {
                EventImageView(imagePath: p.eventImagePath)
                    .frame(height: 180)
                    .cornerRadius(10)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .frame(height: 180)
                    .cornerRadius(10)
            }

            Text(p.eventTitle.isEmpty ? "Event" : p.eventTitle)
                .font(.headline)

            HStack {
                Text("Date: \(formattedDate(p))")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                Spacer()
                Text("\(p.quantity)x")
                    .font(.subheadline)
                Text(String(format: "$%.2f", p.totalAmount))
                    .font(.subheadline)
            }

            HStack(spacing: 8) {
                if p.isEventbrite {
                    Button {
                        openEventbrite(p)
                    } label: {
                        Label("View Ticket", systemImage: "qrcode")
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.blue.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }

                    if let s = p.externalURL, let url = URL(string: s) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label("Open in Eventbrite", systemImage: "arrow.up.right.square")
                                .font(.footnote)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.orange.opacity(0.9))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                } else {
                    Button {
                        let model = PurchaseModel(
                            id: p.id,
                            userId: p.userId,
                            eventId: p.eventId,
                            eventTitle: p.eventTitle,
                            eventImagePath: p.eventImagePath,
                            quantity: p.quantity,
                            type: p.type,
                            totalAmount: p.totalAmount,
                            timestamp: p.timestamp
                        )
                        openPlatform(model)
                    } label: {
                        Label("View Ticket", systemImage: "ticket")
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.blue.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Eventbrite proof (QR/barcode + order info)

fileprivate struct EBTicketProofView: View {
    let purchase: UnifiedPurchase
    @Environment(\.dismiss) private var dismiss
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    private func qrImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        if let cgimg = context.createCGImage(output, from: output.extent) {
            return UIImage(cgImage: cgimg)
        }
        return nil
    }

    private var dateText: String {
        if let iso = purchase.eventISODate, let d = ISO8601DateFormatter().date(from: iso) {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: d)
        } else {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: Date(timeIntervalSince1970: purchase.timestamp))
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(purchase.eventTitle.isEmpty ? "Event" : purchase.eventTitle)
                    .font(.title3).multilineTextAlignment(.center)

                if purchase.isEventbrite,
                   let url = URL(string: purchase.eventImagePath), !purchase.eventImagePath.isEmpty {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ZStack { Color.gray.opacity(0.2); ProgressView() }
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.gray.opacity(0.2)
                        }
                    }
                    .frame(height: 160)
                    .clipped()
                    .cornerRadius(12)
                }

                VStack(spacing: 6) {
                    Text(dateText).font(.subheadline).foregroundColor(.gray)
                    if let oid = purchase.orderId { Text("Order: \(oid)").font(.footnote).foregroundColor(.gray) }
                }

                if let code = purchase.barcode, let img = qrImage(from: code) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .padding(.top, 8)

                    Text(code)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("No barcode available yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let s = purchase.externalURL, let url = URL(string: s) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text("Open in Eventbrite")
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.orange)
                            .cornerRadius(10)
                    }
                }
            }
            .padding()
            .navigationTitle("Ticket")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - EventImageView (unchanged logic; logs retained)

struct EventImageView: View {
    let imagePath: String
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var fetchAttempted = false

    var body: some View {
        ZStack {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if isLoading {
                ProgressView("Loading...")
            } else {
                Rectangle()
                    .foregroundColor(.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.white)
                            .font(.title)
                    )
            }
        }
        .frame(height: 200)
        .clipped()
        .cornerRadius(10)
        .onAppear {
            if !fetchAttempted {
                fetchAttempted = true
                fetchImage()
            }
        }
    }

    private func fetchImage() {
        guard !imagePath.isEmpty else { isLoading = false; return }
        print("🔍 Fetching image URL for path: \(imagePath)")
        let storageRef = Storage.storage().reference(withPath: imagePath)
        storageRef.downloadURL { url, error in
            if let url = url {
                print("✅ Download URL obtained: \(url.absoluteString)")
                loadImageData(from: url)
            } else {
                print("❌ Failed to fetch image URL: \(error?.localizedDescription ?? "Unknown error")")
                isLoading = false
            }
        }
    }

    private func loadImageData(from url: URL, retries: Int = 3) {
        print("📥 Attempting to load image from: \(url.absoluteString), retries left: \(retries)")
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data, error == nil {
                DispatchQueue.main.async {
                    print("✅ Retried image data loaded successfully")
                    imageData = data
                    isLoading = false
                }
            } else if retries > 0 {
                print("🔁 Retrying image download (\(retries - 1) left)...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadImageData(from: url, retries: retries - 1)
                }
            } else {
                print("❌ Final image fetch failed after retries: \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async {
                    isLoading = false
                }
            }
        }.resume()
    }
}



// MARK: - CreateEventView (friendly validation + alerts + disabled overlay)

struct CreateEventView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var title = ""
    @State private var description = ""
    @State private var selectedDate = Date()
    @State private var payoutMethod = "PayPal"   // fixed
    @State private var payoutDetails = ""        // PayPal email only
    @State private var ticketPrice: Double = 0.0
    @State private var ticketQuantity: Int = 0
    @State private var tablePrice: Double = 0.0
    @State private var tableQuantity: Int = 0
    @State private var selectedImage: UIImage?
    @State private var isUploading = false
    @State private var showImagePicker = false
    @State private var location = ""

    // NEW: errors
    @State private var formErrors: [String] = []
    @State private var showErrorAlert = false

    var body: some View {
        NavigationView {
            Form {
                // 🔴 Inline error banner
                if !formErrors.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Please fix the following:")
                                .font(.subheadline).bold()
                            ForEach(formErrors, id: \.self) { msg in
                                Text("• \(msg)").font(.footnote)
                            }
                        }
                        .foregroundColor(.red)
                    }
                }

                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Location", text: $location)
                    TextField("Event Description", text: $description)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }

                Section(header: Text("Event Image")) {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                    }
                    Button("Select Event Image") {
                        showImagePicker = true
                    }
                }

                Section(header: Text("Payout Information")) {
                    HStack {
                        Text("Payout Method")
                        Spacer()
                        Text("PayPal").foregroundColor(.secondary)
                    }
                    TextField("Enter PayPal email", text: $payoutDetails)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section(header: Text("Ticket Sales")) {
                    Text("Ticket Price (USD)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)

                    Text("Number of Tickets")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    Text("Table Price (USD)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)

                    Text("Number of Tables")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                if isUploading {
                    ProgressView("Uploading...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button("Create Event") {
                        createEvent()
                    }
                }
            }
            .navigationTitle("Create New Event")
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedImage)
            }
            .disabled(isUploading)
            .overlay {
                if isUploading {
                    ZStack {
                        Color.black.opacity(0.05).ignoresSafeArea()
                        ProgressView("Uploading…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
            }
            .alert("Can’t Create Event", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(formErrors.map { "• \($0)" }.joined(separator: "\n"))
            }
        }
    }

    private func validateForm() -> [String] {
        var errs: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please enter an event title.")
        }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please enter a location.")
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please add a short description.")
        }
        if selectedImage == nil {
            errs.append("Please select a cover image for the event.")
        }

        // PayPal email (lightweight but solid)
        let email = payoutDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try! NSRegularExpression(
            pattern: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
            options: [.caseInsensitive]
        )
        if regex.firstMatch(in: email, range: NSRange(location: 0, length: email.utf16.count)) == nil {
            errs.append("Enter a valid PayPal email.")
        }

        if ticketPrice < 0 || tablePrice < 0 { errs.append("Prices can’t be negative.") }
        if ticketQuantity < 0 || tableQuantity < 0 { errs.append("Quantities can’t be negative.") }
        if ticketPrice > 0 && ticketQuantity == 0 { errs.append("Set ticket quantity for paid tickets.") }
        if tablePrice > 0 && tableQuantity == 0 { errs.append("Set table quantity for paid tables.") }

        return errs
    }

    private func createEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let errs = validateForm()
        guard errs.isEmpty else {
            formErrors = errs
            showErrorAlert = true
            return
        }

        isUploading = true
        guard let image = selectedImage else { return }

        uploadEventImage(image) { imagePath in
            guard let imagePath = imagePath else {
                self.isUploading = false
                self.formErrors = ["We couldn’t upload your image. Check your connection and try again."]
                self.showErrorAlert = true
                return
            }
            saveEventData(imagePath: imagePath, userId: userId)
        }
    }

    private func uploadEventImage(_ image: UIImage, completion: @escaping (String?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            formErrors = ["We couldn’t read the selected image. Try another image."]
            showErrorAlert = true
            completion(nil)
            return
        }

        let imageID = UUID().uuidString
        let storageRef = Storage.storage().reference().child("eventImages/\(imageID).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        storageRef.putData(imageData, metadata: metadata) { _, error in
            if let error = error {
                self.formErrors = ["Image upload failed. (\(error.localizedDescription))"]
                self.showErrorAlert = true
                completion(nil)
            } else {
                completion("eventImages/\(imageID).jpg")
            }
        }
    }

    private func saveEventData(imagePath: String, userId: String) {
        let ref = Database.database().reference().child("events").childByAutoId()
        let eventId = ref.key ?? UUID().uuidString
        let data: [String: Any] = [
            "id": eventId,
            "title": title,
            "description": description,
            "date": selectedDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,
            "payoutMethod": payoutMethod,
            "payoutDetails": payoutDetails,
            "location": location,
            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,
            "imagePath": imagePath,
            "userId": userId,
            "isFree": (ticketPrice <= 0 && tablePrice <= 0)
        ]

        ref.setValue(data) { error, _ in
            isUploading = false
            if let error = error {
                self.formErrors = ["We couldn’t save your event. (\(error.localizedDescription))"]
                self.showErrorAlert = true
            } else {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }
}

// MARK: - EditEventView (same friendly validation pattern)

struct EditEventView: View {
    @Environment(\.presentationMode) var presentationMode
    let event: EventModel

    @State private var title: String
    @State private var description: String
    @State private var selectedDate: Date
    @State private var payoutMethod: String
    @State private var payoutDetails: String
    @State private var ticketPrice: Double
    @State private var ticketQuantity: Int
    @State private var tablePrice: Double
    @State private var tableQuantity: Int
    @State private var location: String
    @State private var selectedImage: UIImage?
    @State private var showImagePicker = false
    @State private var isUploading = false

    @State private var formErrors: [String] = []
    @State private var showErrorAlert = false

    init(event: EventModel) {
        self.event = event
        let normalizedMethod = "PayPal"
        let normalizedDetails = (event.payoutMethod == "PayPal") ? event.payoutDetails : ""

        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description)
        _location = State(initialValue: event.location)
        _selectedDate = State(initialValue: event.date)
        _payoutMethod = State(initialValue: normalizedMethod)
        _payoutDetails = State(initialValue: normalizedDetails)
        _ticketPrice = State(initialValue: event.ticketPrice)
        _ticketQuantity = State(initialValue: event.ticketQuantity)
        _tablePrice = State(initialValue: event.tablePrice)
        _tableQuantity = State(initialValue: event.tableQuantity)
    }

    var body: some View {
        NavigationView {
            Form {
                if !formErrors.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Please fix the following:")
                                .font(.subheadline).bold()
                            ForEach(formErrors, id: \.self) { msg in
                                Text("• \(msg)").font(.footnote)
                            }
                        }
                        .foregroundColor(.red)
                    }
                }

                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Description", text: $description)
                    TextField("Event Location", text: $location)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }

                Section(header: Text("Update Image")) {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                    }
                    Button("Select New Image") {
                        showImagePicker = true
                    }
                }

                Section(header: Text("Payout Information")) {
                    HStack {
                        Text("Payout Method")
                        Spacer()
                        Text("PayPal")
                            .foregroundColor(.secondary)
                    }

                    TextField("Enter PayPal Email", text: $payoutDetails)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }

                Section(header: Text("Ticket Sales")) {
                    TextField("Ticket Price (USD)", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Number of Tickets", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    TextField("Table Price (USD)", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Number of Tables", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                if isUploading {
                    ProgressView("Updating...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button("Save Changes") {
                        updateEvent()
                    }
                }
            }
            .navigationTitle("Edit Event")
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedImage)
            }
            .disabled(isUploading)
            .overlay {
                if isUploading {
                    ZStack {
                        Color.black.opacity(0.05).ignoresSafeArea()
                        ProgressView("Updating…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
            }
            .alert("Can’t Save Changes", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(formErrors.map { "• \($0)" }.joined(separator: "\n"))
            }
        }
    }

    private func validateEditForm() -> [String] {
        var errs: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please enter an event title.")
        }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please enter a location.")
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append("Please add a short description.")
        }
        let email = payoutDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try! NSRegularExpression(
            pattern: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
            options: [.caseInsensitive]
        )
        if regex.firstMatch(in: email, range: NSRange(location: 0, length: email.utf16.count)) == nil {
            errs.append("Enter a valid PayPal email.")
        }
        if ticketPrice < 0 || tablePrice < 0 { errs.append("Prices can’t be negative.") }
        if ticketQuantity < 0 || tableQuantity < 0 { errs.append("Quantities can’t be negative.") }
        if ticketPrice > 0 && ticketQuantity == 0 { errs.append("Set ticket quantity for paid tickets.") }
        if tablePrice > 0 && tableQuantity == 0 { errs.append("Set table quantity for paid tables.") }
        return errs
    }

    private func updateEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let errs = validateEditForm()
        guard errs.isEmpty else {
            formErrors = errs
            showErrorAlert = true
            return
        }

        isUploading = true
        if let newImage = selectedImage {
            uploadNewImage(newImage) { imagePath in
                guard let path = imagePath else {
                    isUploading = false
                    formErrors = ["We couldn’t upload your image. Check your connection and try again."]
                    showErrorAlert = true
                    return
                }
                saveChanges(imagePath: path, userId: userId)
            }
        } else {
            saveChanges(imagePath: event.imagePath, userId: userId)
        }
    }

    private func uploadNewImage(_ image: UIImage, completion: @escaping (String?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            formErrors = ["We couldn’t read the selected image. Try another image."]
            showErrorAlert = true
            completion(nil)
            return
        }

        let imageID = UUID().uuidString
        let storageRef = Storage.storage().reference().child("eventImages/\(imageID).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        storageRef.putData(imageData, metadata: metadata) { _, error in
            if let error = error {
                print("❌ Image upload error: \(error.localizedDescription)")
                formErrors = ["Image upload failed. (\(error.localizedDescription))"]
                showErrorAlert = true
                completion(nil)
            } else {
                completion("eventImages/\(imageID).jpg")
            }
        }
    }

    private func saveChanges(imagePath: String, userId: String) {
        let ref = Database.database().reference().child("events/\(event.id)")
        let data: [String: Any] = [
            "title": title,
            "description": description,
            "location": location,
            "date": selectedDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,
            "payoutMethod": payoutMethod,
            "payoutDetails": payoutDetails,
            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,
            "imagePath": imagePath,
            "userId": userId,
            "isFree": (ticketPrice <= 0 && tablePrice <= 0)
        ]

        ref.updateChildValues(data) { error, _ in
            isUploading = false
            if let error = error {
                formErrors = ["We couldn’t save your changes. (\(error.localizedDescription))"]
                showErrorAlert = true
            } else {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }
}

// MARK: - ShowTicketView (unchanged)

struct ShowTicketView: View {
    let purchase: PurchaseModel
    @Environment(\.presentationMode) var presentationMode
    @State private var isCheckedIn = false
    @State private var checkInSuccess = false

    var body: some View {
        VStack(spacing: 20) {
            Text("🎟️ Your Ticket")
                .font(.title)
                .bold()

            Text(purchase.eventTitle)
                .font(.headline)

            Text("Type: \(purchase.type.capitalized)")
            Text("Quantity: \(purchase.quantity)")
            Text("Amount Paid: $\(String(format: "%.2f", purchase.totalAmount))")

            Text("Purchase ID")
                .font(.caption)
                .foregroundColor(.gray)

            Text(purchase.id)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.blue)

            if checkInSuccess {
                Label("✅ Checked In", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.headline)
            } else {
                Button(action: handleCheckIn) {
                    Text("Check In")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(isCheckedIn)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            loadCheckInStatus()
        }
    }

    private func loadCheckInStatus() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(userId).child(purchase.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            if let data = snapshot.value as? [String: Any],
               let checked = data["checkedIn"] as? Bool {
                self.isCheckedIn = checked
                self.checkInSuccess = checked
            }
        }
    }

    private func handleCheckIn() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(userId).child(purchase.id)

        ref.updateChildValues(["checkedIn": true]) { error, _ in
            if error == nil {
                self.checkInSuccess = true
                self.isCheckedIn = true
            }
        }
    }
}

// MARK: - EventStatsView (unchanged)

struct EventStatsView: View {
    let event: EventModel
    @State private var checkIns: [PurchaseModel] = []
    @State private var totalTickets = 0
    @State private var totalTables = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Event Stats")
                    .font(.largeTitle)
                    .bold()

                Text("Title: \(event.title)")
                    .font(.headline)

                Text("Total Tickets Sold: \(totalTickets)")
                Text("Total Tables Booked: \(totalTables)")
                Text("Checked-In Attendees: \(checkIns.count)")

                Divider()

                Text("Checked-In Users")
                    .font(.title3)
                    .bold()

                if checkIns.isEmpty {
                    Text("No one has checked in yet.")
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                } else {
                    ForEach(checkIns) { purchase in
                        HStack(alignment: .top, spacing: 12) {
                            UserAvatarView(userId: purchase.userId)

                            VStack(alignment: .leading, spacing: 2) {
                                UserNameView(userId: purchase.userId)

                                Text("Type: \(purchase.type.capitalized) | Qty: \(purchase.quantity)")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding()
            .onAppear {
                loadStats()
            }
        }
    }

    private func loadStats() {
        let ref = Database.database().reference().child("purchases")

        ref.observeSingleEvent(of: .value) { snapshot in
            var checked: [PurchaseModel] = []
            var ticketTotal = 0
            var tableTotal = 0

            for case let userSnapshot as DataSnapshot in snapshot.children {
                for case let purchaseSnapshot as DataSnapshot in userSnapshot.children {
                    guard let value = purchaseSnapshot.value as? [String: Any],
                          value["eventId"] as? String == event.id else { continue }

                    let type = value["type"] as? String ?? "ticket"
                    let quantity = value["quantity"] as? Int ?? 0

                    if type == "ticket" {
                        ticketTotal += quantity
                    } else if type == "table" {
                        tableTotal += quantity
                    }

                    if value["checkedIn"] as? Bool == true {
                        let model = PurchaseModel(
                            id: purchaseSnapshot.key,
                            userId: value["userId"] as? String ?? "",
                            eventId: event.id,
                            eventTitle: value["eventTitle"] as? String ?? "",
                            eventImagePath: value["eventImagePath"] as? String ?? "",
                            quantity: quantity,
                            type: type,
                            totalAmount: value["totalAmount"] as? Double ?? 0.0,
                            timestamp: value["timestamp"] as? TimeInterval ?? 0.0
                        )
                        checked.append(model)
                    }
                }
            }

            self.totalTickets = ticketTotal
            self.totalTables = tableTotal
            self.checkIns = checked
        }
    }
}

// MARK: - UserNameView (unchanged)

struct UserNameView: View {
    let userId: String
    @State private var name: String = ""

    var body: some View {
        Text(name.isEmpty ? "User: \(userId.prefix(8))..." : "User: \(name)")
            .font(.subheadline)
            .foregroundColor(.primary)
            .onAppear { fetchName() }
    }

    private func fetchName() {
        let ref = Database.database().reference().child("users").child(userId).child("name")
        ref.observeSingleEvent(of: .value) { snapshot in
            if let value = snapshot.value as? String {
                self.name = value
            }
        }
    }
}

// MARK: - UserAvatarView (unchanged)

struct UserAvatarView: View {
    let userId: String
    @State private var imageURL: String? = nil
    @State private var initials: String = "?"

    var body: some View {
        Group {
            if let url = imageURL, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    if let img = phase.image {
                        img.resizable()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .onAppear {
            loadProfileImage()
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Text(initials)
                    .foregroundColor(.black)
                    .font(.caption)
            )
    }

    private func loadProfileImage() {
        let ref = Database.database().reference().child("users").child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            if let dict = snapshot.value as? [String: Any] {
                self.imageURL = dict["profileImageURL"] as? String
                if let name = dict["name"] as? String {
                    self.initials = name.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined().uppercased()
                }
            }
        }
    }
}

// MARK: - RSSCardView (unchanged)

struct RSSCardView: View {
    let article: RSSArticle
    @Binding var selectedURL: URL?
    @Binding var showWebView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: article.imageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)

                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(12)

                case .failure:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 200)

                @unknown default:
                    EmptyView()
                }
            }

            Text(article.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(article.description)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(2)

            Button(action: {
                if let url = URL(string: article.link) {
                    selectedURL = url
                    showWebView = true
                }
            }) {
                Text("Read More")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(16)
        .shadow(radius: 3)
    }
}

// MARK: - EventDetailView (unchanged core; includes share + checkout)

struct EventDetailView: View {
    let event: EventModel

    @State private var showWebViewModal = false
    @State private var selectedURL: URL?
    @State private var showCheckoutConfirmation = false
    @State private var isSaved = false

    @State private var showShareOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    EventImageView(imagePath: event.imagePath)
                        .frame(height: 250)
                        .cornerRadius(12)

                    Text(formattedDate(event.date))
                        .font(.caption)
                        .bold()
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                        .padding()
                }

                Text(event.title)
                    .font(.title)
                    .bold()
                    .padding(.top)

                Text(event.description)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)

                if event.ticketPrice > 0 || event.tablePrice > 0 {
                    Button(action: {
                        showCheckoutConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "cart.fill")
                            Text("Buy Tickets / Tables")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                HStack {
                    Button(action: { showShareOptions = true }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }

                    .confirmationDialog("Share Event", isPresented: $showShareOptions, titleVisibility: .visible) {
                        Button("Share to Gossip (recommended)") {
                            shareToGossip()
                        }
                        Button("Share via…") {
                            shareToSystem()
                        }
                        Button("Cancel", role: .cancel) {}
                    }

                    Button(action: toggleSaveEvent) {
                        Label(isSaved ? "Saved" : "Remind Me", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .preferredColorScheme(.dark)
        .onAppear {
            checkIfSaved()
        }
        .sheet(isPresented: $showWebViewModal) {
            if let url = selectedURL {
                NavigationView {
                    WebView(url: url)
                        .navigationBarTitle("Secure Checkout", displayMode: .inline)
                        .navigationBarItems(trailing: Button("Close") {
                            showWebViewModal = false
                        })
                }
            }
        }
        .sheet(isPresented: $showCheckoutConfirmation) {
            CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                let baseTotal = Double(ticketQty) * event.ticketPrice + Double(tableQty) * event.tablePrice
                let totalWithFee = baseTotal * 1.02

                let urlString = """
                https://blackappios.web.app/index.html?\
                eventId=\(event.id)&\
                eventName=\(event.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&\
                eventTime=\(Int(event.date.timeIntervalSince1970))&\
                userId=\(Auth.auth().currentUser?.uid ?? "anonymous")&\
                ticketQty=\(ticketQty)&\
                ticketPrice=\(event.ticketPrice)&\
                tableQty=\(tableQty)&\
                tablePrice=\(event.tablePrice)&\
                baseTotal=\(String(format: "%.2f", baseTotal))&\
                totalWithFee=\(String(format: "%.2f", totalWithFee))&\
                payoutMethod=\(event.payoutMethod)&\
                payoutDetails=\(event.payoutDetails.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&\
                eventImagePath=\(event.imagePath)
                """

                if let url = URL(string: urlString) {
                    selectedURL = url
                    showWebViewModal = true
                } else {
                    print("❌ Failed to create checkout URL")
                }
            }
        }
    }

    private func toggleSaveEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)

        if isSaved {
            ref.removeValue()
            isSaved = false
        } else {
            let values: [String: Any] = [
                "eventId": event.id,
                "title": event.title,
                "timestamp": Date().timeIntervalSince1970
            ]
            ref.setValue(values)
            isSaved = true
        }
    }

    private func checkIfSaved() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }

    private func shareToGossip() {
        guard let url = buildEventDeepLink() else {
            shareToSystem()
            return
        }
        let caption = makeEventCaption()
        if let top = topMostController() {
            GossipShareManager.shared.presentShare(from: top, payload: .link(url: url, text: caption))
        } else {
            shareToSystem()
        }
    }

    private func shareToSystem() {
        guard let url = buildEventDeepLink() else { return }
        presentSystemShare([makeEventCaption(), url])
    }

    private func buildEventDeepLink() -> URL? {
        URL(string: "https://blackappios.web.app/event.html?eventId=\(event.id)")
    }

    private func makeEventCaption() -> String {
        let dateText = formattedDate(event.date)
        var parts: [String] = []
        parts.append(event.title)
        if !event.location.isEmpty { parts.append(event.location) }
        parts.append(dateText)
        if event.ticketPrice > 0 { parts.append(String(format: "Tickets $%.0f", event.ticketPrice)) }
        if event.tablePrice > 0 { parts.append(String(format: "Tables $%.0f", event.tablePrice)) }
        return parts.joined(separator: " • ")
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Generic share presenters (unchanged)

private func presentSystemShare(_ items: [Any]) {
    DispatchQueue.main.async {
        guard let top = topMostController() else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }
}

private func topMostController(base: UIViewController? = {
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .sorted { ($0.activationState == .foregroundActive) && ($1.activationState != .foregroundActive) }
    let keyWin = scenes.first?.windows.first(where: { $0.isKeyWindow })
    return keyWin?.rootViewController
}()) -> UIViewController? {
    if let nav = base as? UINavigationController { return topMostController(base: nav.visibleViewController) }
    if let tab = base as? UITabBarController { return topMostController(base: tab.selectedViewController) }
    if let presented = base?.presentedViewController { return topMostController(base: presented) }
    return base
}

// MARK: - ShareModalView / ShareIconButton (unchanged)

struct ShareModalView: View {
    let eventId: String
    let eventTitle: String
    @Binding var showCopiedAlert: Bool

    var hostedURL: String {
        return "https://blackappios.web.app/event.html?eventId=\(eventId)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Share this Event")
                .font(.headline)
                .padding(.top)

            HStack(spacing: 20) {
                ShareIconButton(systemImage: "f.square") {
                    shareTo(url: "https://www.facebook.com/sharer/sharer.php?u=\(hostedURL)")
                }
                ShareIconButton(systemImage: "camera") {
                    shareTo(url: "https://www.instagram.com/?url=\(hostedURL)")
                }
                ShareIconButton(systemImage: "message.fill") {
                    shareTo(url: "https://api.whatsapp.com/send?text=\(eventTitle) \(hostedURL)")
                }
                ShareIconButton(systemImage: "bird") {
                    shareTo(url: "https://twitter.com/intent/tweet?text=\(eventTitle)&url=\(hostedURL)")
                }
            }

            Button(action: {
                UIPasteboard.general.string = hostedURL
                showCopiedAlert = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showCopiedAlert = false
                }
            }) {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Link")
                }
                .foregroundColor(.blue)
                .padding()
                .background(Color.white)
                .cornerRadius(10)
            }

            Spacer()
        }
        .padding()
        .background(Color.black)
        .presentationDetents([.medium])
    }

    private func shareTo(url: String) {
        if let shareURL = URL(string: url) {
            UIApplication.shared.open(shareURL)
        }
    }
}

struct ShareIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .padding(10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
