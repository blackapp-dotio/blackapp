import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseFunctions
import CoreImage.CIFilterBuiltins
import SafariServices

// MARK: - Small value types (Hashable) to avoid tuple Hashable issues
struct Geo: Hashable, Codable { let lat: Double; let lng: Double }
struct XY: Hashable, Codable { let x: Double; let y: Double }

// MARK: - Models

struct VenueModel: Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    var geo: Geo?
    var photos: [String]
    var genres: [String]
    var dressCode: String?
    var hours: [String: [String: String]]? // e.g. ["fri":["open":"22:00","close":"04:00"]]

    static func from(_ snap: DataSnapshot) -> VenueModel? {
        guard let v = snap.value as? [String: Any],
              let name = v["name"] as? String else { return nil }
        let address = v["address"] as? String ?? ""
        let photos = v["photos"] as? [String] ?? []
        let genres = v["genres"] as? [String] ?? []
        let dress = v["dressCode"] as? String
        let hours = v["hours"] as? [String: [String: String]]

        var geoValue: Geo? = nil
        if let g = v["geo"] as? [String: Any],
           let lat = g["lat"] as? Double,
           let lng = g["lng"] as? Double {
            geoValue = Geo(lat: lat, lng: lng)
        }

        return VenueModel(id: snap.key,
                          name: name,
                          address: address,
                          geo: geoValue,
                          photos: photos,
                          genres: genres,
                          dressCode: dress,
                          hours: hours)
    }
}

struct NightModel: Identifiable, Hashable {
    var id: String
    var venueId: String
    var date: Date
    var title: String
    var description: String
    var imagePath: String?
    var promoterIds: [String: Bool]
    var status: String

    static func from(_ snap: DataSnapshot) -> NightModel? {
        guard let v = snap.value as? [String: Any],
              let venueId = v["venueId"] as? String,
              let dateTs = v["date"] as? TimeInterval,
              let title = v["title"] as? String else { return nil }
        let description = v["description"] as? String ?? ""
        let imagePath = v["imagePath"] as? String
        let promoterIds = v["promoterIds"] as? [String: Bool] ?? [:]
        let status = v["status"] as? String ?? "published"
        return NightModel(id: snap.key,
                          venueId: venueId,
                          date: Date(timeIntervalSince1970: dateTs),
                          title: title,
                          description: description,
                          imagePath: imagePath,
                          promoterIds: promoterIds,
                          status: status)
    }
}

struct TableModel: Identifiable, Hashable {
    var id: String
    var venueId: String
    var label: String
    var section: String?
    var capacity: Int
    var position: XY?
    var active: Bool

    static func from(_ snap: DataSnapshot) -> TableModel? {
        guard let v = snap.value as? [String: Any],
              let venueId = v["venueId"] as? String,
              let label = v["label"] as? String else { return nil }
        let section = v["section"] as? String
        let capacity = v["capacity"] as? Int ?? 0

        var posValue: XY? = nil
        if let pos = v["position"] as? [String: Any],
           let x = pos["x"] as? Double,
           let y = pos["y"] as? Double {
            posValue = XY(x: x, y: y)
        }

        let active = v["active"] as? Bool ?? true

        return TableModel(id: snap.key,
                          venueId: venueId,
                          label: label,
                          section: section,
                          capacity: capacity,
                          position: posValue,
                          active: active)
    }
}

struct InventoryItem: Identifiable, Hashable {
    var id: String { tableId }
    var nightId: String
    var tableId: String
    var minSpend: Double
    var timeSlot: String?
    var depositPercent: Int?
    var status: String // available/held/paid/blocked

    static func from(nightId: String, tableId: String, snap: DataSnapshot) -> InventoryItem? {
        guard let v = snap.value as? [String: Any] else { return nil }
        let minSpend = v["minSpend"] as? Double ?? 0
        let timeSlot = v["timeSlot"] as? String
        let depositPercent = v["depositPercent"] as? Int
        let status = v["status"] as? String ?? "available"
        return InventoryItem(nightId: nightId,
                             tableId: tableId,
                             minSpend: minSpend,
                             timeSlot: timeSlot,
                             depositPercent: depositPercent,
                             status: status)
    }
}

struct ReservationModel: Identifiable, Hashable {
    var id: String
    var nightId: String
    var tableId: String
    var userId: String
    var status: String // held/pending/paid/cancelled/expired
    var minSpend: Double
    var depositPercent: Int
    var depositAmount: Double
    var amountPaid: Double
    var holdExpiresAt: TimeInterval?

    static func from(_ snap: DataSnapshot) -> ReservationModel? {
        guard let v = snap.value as? [String: Any],
              let nightId = v["nightId"] as? String,
              let tableId = v["tableId"] as? String,
              let userId = v["userId"] as? String,
              let status = v["status"] as? String,
              let minSpend = v["minSpend"] as? Double else { return nil }
        let depositPercent = v["depositPercent"] as? Int ?? 0
        let depositAmount = v["depositAmount"] as? Double ?? 0
        let amountPaid = v["amountPaid"] as? Double ?? 0
        let hold = v["holdExpiresAt"] as? TimeInterval
        return ReservationModel(id: snap.key,
                                nightId: nightId,
                                tableId: tableId,
                                userId: userId,
                                status: status,
                                minSpend: minSpend,
                                depositPercent: depositPercent,
                                depositAmount: depositAmount,
                                amountPaid: amountPaid,
                                holdExpiresAt: hold)
    }
}

// MARK: - Entertainer & Lineup Models

struct EntertainerProfile: Identifiable, Hashable {
    var id: String            // uid
    var stageName: String
    var bio: String?
    var genres: [String]
    var socials: [String: String] // instagram, tiktok, youtube, soundcloud, website
    var payoutMethod: String?     // e.g. "PayPal"
    var payoutDetails: String?    // e.g. paypal email

    static func from(_ snap: DataSnapshot) -> EntertainerProfile? {
        guard let v = snap.value as? [String: Any],
              let stageName = v["stageName"] as? String else { return nil }
        let bio = v["bio"] as? String
        let genres = v["genres"] as? [String] ?? []
        let socials = v["socials"] as? [String: String] ?? [:]
        let payoutMethod = v["payoutMethod"] as? String
        let payoutDetails = v["payoutDetails"] as? String
        return EntertainerProfile(
            id: snap.key,
            stageName: stageName,
            bio: bio,
            genres: genres,
            socials: socials,
            payoutMethod: payoutMethod,
            payoutDetails: payoutDetails
        )
    }
}

struct LineupSlot: Identifiable, Hashable {
    var id: String            // autoId under /lineups/{nightId}/{slotId}
    var nightId: String
    var entertainerId: String
    var role: String?         // "Headliner", "Host", "DJ", etc.
    var startAt: TimeInterval?
    var endAt: TimeInterval?
    var compensation: Double?
    var status: String        // "invited", "confirmed", "declined", "cancelled"

    static func from(nightId: String, snap: DataSnapshot) -> LineupSlot? {
        guard let v = snap.value as? [String: Any],
              let entertainerId = v["entertainerId"] as? String,
              let status = v["status"] as? String else { return nil }
        let role = v["role"] as? String
        let startAt = v["startAt"] as? TimeInterval
        let endAt = v["endAt"] as? TimeInterval
        let comp = v["compensation"] as? Double
        return LineupSlot(
            id: snap.key,
            nightId: nightId,
            entertainerId: entertainerId,
            role: role,
            startAt: startAt,
            endAt: endAt,
            compensation: comp,
            status: status
        )
    }
}

// MARK: - Service Layer

final class NightlifeService: ObservableObject {
    static let shared = NightlifeService()
    private init() {}

    var db: DatabaseReference { Database.database().reference() }

    // Venues
    func fetchVenues(completion: @escaping ([VenueModel]) -> Void) {
        db.child("venues").observeSingleEvent(of: .value) { snap in
            var out: [VenueModel] = []
            for case let child as DataSnapshot in snap.children {
                if let v = VenueModel.from(child) { out.append(v) }
            }
            completion(out)
        }
    }

    // Nights by venue
    func fetchNights(for venueId: String, completion: @escaping ([NightModel]) -> Void) {
        db.child("nights")
            .queryOrdered(byChild: "venueId")
            .queryEqual(toValue: venueId)
            .observeSingleEvent(of: .value) { snap in
                var out: [NightModel] = []
                for case let child as DataSnapshot in snap.children {
                    if let n = NightModel.from(child) { out.append(n) }
                }
                completion(out.sorted { $0.date < $1.date })
            }
    }

    // Inventory for night
    func fetchInventory(nightId: String, completion: @escaping ([InventoryItem]) -> Void) {
        db.child("inventory").child(nightId).observeSingleEvent(of: .value) { snap in
            var out: [InventoryItem] = []
            for case let child as DataSnapshot in snap.children {
                if let item = InventoryItem.from(nightId: nightId, tableId: child.key, snap: child) { out.append(item) }
            }
            completion(out)
        }
    }
}




// MARK: - Ticket SKU + Ticket Inventory API

struct TicketSKU: Identifiable, Hashable {
    var id: String             // e.g. "ga", "vip-early"
    var nightId: String
    var name: String           // "General Admission", "VIP", etc.
    var price: Double
    var qtyAvailable: Int?
    var externalURL: String?   // if present → open external site in SafariView
    var source: String?        // "ticketmaster", "seatgeek", "eventbrite", "manual"

    static func from(nightId: String, skuId: String, snap: DataSnapshot) -> TicketSKU? {
        guard let v = snap.value as? [String: Any],
              let name = v["name"] as? String,
              let price = v["price"] as? Double else { return nil }
        let qty = v["qtyAvailable"] as? Int
        let url = v["externalURL"] as? String
        let source = v["source"] as? String
        return TicketSKU(id: skuId, nightId: nightId, name: name, price: price, qtyAvailable: qty, externalURL: url, source: source)
    }
}

// Ticket inventory fetch
extension NightlifeService {
    func fetchTicketInventory(nightId: String, completion: @escaping ([TicketSKU]) -> Void) {
        db.child("ticketInventory").child(nightId).observeSingleEvent(of: .value) { snap in
            var out: [TicketSKU] = []
            for case let child as DataSnapshot in snap.children {
                if let sku = TicketSKU.from(nightId: nightId, skuId: child.key, snap: child) { out.append(sku) }
            }
            completion(out)
        }
    }
}

// MARK: - Helpers

func platformFee(_ amount: Double) -> Double { (amount * 0.02).rounded(toPlaces: 2) }

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Reusable controls/helpers (file scope)

fileprivate struct RangeSlider: View {
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    var body: some View {
        VStack {
            Slider(value: Binding(
                get: { range.lowerBound },
                set: { range = min($0, range.upperBound)...range.upperBound }
            ), in: bounds)
            Slider(value: Binding(
                get: { range.upperBound },
                set: { range = range.lowerBound...max($0, range.lowerBound) }
            ), in: bounds)
        }
    }
}

fileprivate extension ClosedRange where Bound == Double {
    func clamped(to other: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = min(max(lowerBound, other.lowerBound), other.upperBound)
        let upper = max(min(upperBound, other.upperBound), other.lowerBound)
        return lower...upper
    }
}

// MARK: - Safari wrapper with unique name (avoids conflicts)

struct NightlifeSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Small shared UI bits

struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        HStack { Text(title).font(.headline); Spacer() }
            .padding(.top, 8)
    }
}

// MARK: - Views (Venue detail + guestlist + QR + payment callback)

struct VenueDetailView: View {
    var venue: VenueModel
    @State private var nights: [NightModel] = []
    @State private var selectedNight: NightModel?
    @State private var inventory: [InventoryItem] = []
    @State private var tickets: [TicketSKU] = []

    @State private var isLoadingTables = false
    @State private var isLoadingTickets = false

    // Filters
    @State private var selectedDate = Date()
    @State private var minSpendBounds: ClosedRange<Double> = 0...5000
    @State private var minSpendActive: ClosedRange<Double> = 0...5000

    @State private var ticketPriceBounds: ClosedRange<Double> = 0...500
    @State private var ticketPriceActive: ClosedRange<Double> = 0...500

    // External sheet
    @State private var showSafari = false
    @State private var safariURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // MARK: Filters
                Group {
                    Divider()
                    Text("Filters").font(.headline)

                    // Date filter
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                        Spacer()
                        Button { resetFilters() } label: { Text("Reset").font(.footnote) }
                    }

                    // Tables Min Spend
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "dollarsign.circle")
                            Text("Table Min Spend")
                            Spacer()
                            Text("$\(Int(minSpendActive.lowerBound)) – $\(Int(minSpendActive.upperBound))")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        RangeSlider(range: $minSpendActive, bounds: minSpendBounds).frame(height: 24)
                    }

                    // Ticket price
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "ticket")
                            Text("Ticket Price")
                            Spacer()
                            Text("$\(Int(ticketPriceActive.lowerBound)) – $\(Int(ticketPriceActive.upperBound))")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        RangeSlider(range: $ticketPriceActive, bounds: ticketPriceBounds).frame(height: 24)
                    }
                }

                Divider()
                nightPicker
                Divider()
                tablesSection
                Divider()
                ticketsSection

                if let n = selectedNight {
                    Divider().padding(.vertical, 8)

                    // Manage lineup
                    NavigationLink {
                        LineupManagerView(nightId: n.id)
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                            Text("Manage Lineup for \(n.title)")
                            Spacer(); Image(systemName: "chevron.right")
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }

                    // Guest list
                    NavigationLink {
                        GuestListView(nightId: n.id)
                    } label: {
                        HStack {
                            Image(systemName: "person.3.fill")
                            Text("Join Guest List for \(n.title)")
                            Spacer(); Image(systemName: "chevron.right")
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }
                }
            }
            .padding()
        }
        .navigationTitle(venue.name)
        .onAppear { loadNights() }
        .onChange(of: selectedDate) { _ in filterNightsByDate() }
        .onChange(of: selectedNight) { _ in
            loadInventory()
            loadTickets()
        }
        .sheet(isPresented: $showSafari) {
            if let url = safariURL {
                NightlifeSafariView(url: url)
            }
        }
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = venue.photos.first {
                AsyncImage(url: URL(string: first)) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.2) }
                    .frame(height: 180).clipped().cornerRadius(12)
            }
            Text(venue.address).font(.subheadline).foregroundColor(.secondary)
            if !venue.genres.isEmpty {
                Text(venue.genres.joined(separator: " • ")).font(.footnote).foregroundColor(.secondary)
            }
            if let code = venue.dressCode {
                Text("Dress: \(code)").font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Night picker
    private var nightPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming Nights").font(.headline)
            if nights.isEmpty {
                Text("No nights scheduled").foregroundColor(.secondary).font(.subheadline)
            } else {
                Picker("Night", selection: $selectedNight) {
                    ForEach(nights, id: \.id) { n in
                        Text("\(DateFormatter.shortDate.string(from: n.date)) – \(n.title)")
                            .tag(Optional(n))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: Tables section
    private var tablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tables & Min Spend").font(.headline)

            if isLoadingTables { ProgressView().padding(.vertical) }

            ForEach(filteredTables, id: \.id) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Table \(item.tableId)").font(.subheadline).bold()
                        HStack(spacing: 12) {
                            Text("Min Spend: $\(Int(item.minSpend))")
                            if let slot = item.timeSlot { Text(slot) }
                        }
                        .font(.footnote).foregroundColor(.secondary)
                        Text("Status: \(item.status)")
                            .font(.caption)
                            .foregroundColor(item.status == "available" ? .green : .orange)
                    }
                    Spacer()
                    if item.status == "available" {
                        Button("Book") { book(item) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }

            if !isLoadingTables && filteredTables.isEmpty {
                Text("No tables match your price filter.").foregroundColor(.secondary).font(.footnote).padding(.top, 4)
            }
        }
    }

    private var filteredTables: [InventoryItem] {
        inventory.filter { minSpendActive.contains($0.minSpend) }
    }

    // MARK: Tickets section
    private var ticketsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tickets").font(.headline)

            if isLoadingTickets { ProgressView().padding(.vertical) }

            ForEach(filteredTickets, id: \.id) { sku in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sku.name).font(.subheadline).bold()
                        HStack(spacing: 12) {
                            Text(String(format: "$%.0f", sku.price))
                            if let qty = sku.qtyAvailable { Text("Qty: \(qty)") }
                            if let src = sku.source { Text(src.capitalized).foregroundColor(.secondary) }
                        }
                        .font(.footnote).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Buy") {
                        if let u = sku.externalURL, let url = URL(string: u) {
                            safariURL = url
                            showSafari = true
                        } else {
                            // internal ticket flow can go here later
                            print("No external URL; internal checkout TBD")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }

            if !isLoadingTickets && filteredTickets.isEmpty {
                Text("No tickets match your price filter.").foregroundColor(.secondary).font(.footnote).padding(.top, 4)
            }
        }
    }

    private var filteredTickets: [TicketSKU] {
        tickets.filter { ticketPriceActive.contains($0.price) }
    }

    // MARK: Data
    private func loadNights() {
        NightlifeService.shared.fetchNights(for: venue.id) { list in
            DispatchQueue.main.async {
                let base = list
                    .filter { $0.status == "published" && $0.date >= Date() }
                    .sorted { $0.date < $1.date }
                self.nights = base
                filterNightsByDate()
            }
        }
    }

    private func filterNightsByDate() {
        guard !nights.isEmpty else {
            selectedNight = nil
            inventory = []
            tickets = []
            return
        }
        let cal = Calendar.current
        if let match = nights.first(where: { cal.isDate($0.date, inSameDayAs: selectedDate) }) {
            selectedNight = match
        } else {
            selectedNight = nights.first(where: { $0.date >= cal.startOfDay(for: selectedDate) }) ?? nights.first
        }
        loadInventory()
        loadTickets()
    }

    private func loadInventory() {
        guard let night = selectedNight else { inventory = []; return }
        isLoadingTables = true
        NightlifeService.shared.fetchInventory(nightId: night.id) { list in
            DispatchQueue.main.async {
                self.inventory = list.sorted { $0.minSpend < $1.minSpend }
                self.isLoadingTables = false
                // Update slider bounds
                let values = self.inventory.map { $0.minSpend }
                let low = max(0, values.min() ?? 0)
                let high = max(low, values.max() ?? 0)
                self.minSpendBounds = low...high
                self.minSpendActive = self.minSpendActive.clamped(to: self.minSpendBounds)
            }
        }
    }

    private func loadTickets() {
        guard let night = selectedNight else { tickets = []; return }
        isLoadingTickets = true
        NightlifeService.shared.fetchTicketInventory(nightId: night.id) { list in
            DispatchQueue.main.async {
                self.tickets = list.sorted { $0.price < $1.price }
                self.isLoadingTickets = false
                // Update ticket price slider bounds
                let values = self.tickets.map { $0.price }
                let low = max(0, values.min() ?? 0)
                let high = max(low, values.max() ?? 0)
                self.ticketPriceBounds = low...high
                self.ticketPriceActive = self.ticketPriceActive.clamped(to: self.ticketPriceBounds)
            }
        }
    }

    // MARK: Actions
    private func resetFilters() {
        selectedDate = Date()
        minSpendActive = minSpendBounds
        ticketPriceActive = ticketPriceBounds
        filterNightsByDate()
    }

    private func book(_ item: InventoryItem) {
        guard let night = selectedNight else { return }
        let depositPercent = item.depositPercent ?? 0
        NightlifeService.shared.createReservationHold(
            nightId: night.id,
            tableId: item.tableId,
            minSpend: item.minSpend,
            depositPercent: depositPercent
        ) { result in
            switch result {
            case .failure(let err):
                print("❌ Hold failed:", err.localizedDescription)
            case .success(let payload):
                let isDeposit = depositPercent > 0
                let base = isDeposit ? payload.depositAmount : item.minSpend
                if let url = NightlifeService.shared.buildCheckoutURL(
                    nightId: night.id,
                    tableId: item.tableId,
                    reservationId: payload.reservationId,
                    isDeposit: isDeposit,
                    baseAmount: base
                ) { UIApplication.shared.open(url) }
            }
        }
    }
}

// MARK: - Guest List (MVP)

struct GuestListView: View {
    let nightId: String
    @State private var name: String = ""
    @State private var saving = false
    @State private var successId: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Join Guest List").font(.title3).bold()
            TextField("Your full name", text: $name)
                .textFieldStyle(.roundedBorder)
            Button {
                saving = true
                NightlifeService.shared.joinGuestlist(nightId: nightId, name: name) { result in
                    saving = false
                    switch result {
                    case .success(let id): successId = id
                    case .failure(let err): print("Guestlist error:", err.localizedDescription)
                    }
                }
            } label: {
                if saving { ProgressView() } else { Text("Join") }
            }
            .buttonStyle(.borderedProminent)
            if let sid = successId {
                Text("You're on the list ✅ (id: \(sid))").font(.footnote).foregroundColor(.green)
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - QR Code Utility

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = generateQR(from: text) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
        }
    }
    private func generateQR(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        if let output = filter.outputImage?.transformed(by: transform) {
            return UIImage(ciImage: output)
        }
        return nil
    }
}

// MARK: - Payment Callback Router

enum PaymentCallbackRouter {
    static func handle(url: URL) {
        guard url.absoluteString.contains("/pay/callback"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var reservationId: String?
        var amountPaid: Double?
        var promoterId: String?

        comps.queryItems?.forEach { item in
            switch item.name {
            case "reservationId": reservationId = item.value
            case "amountPaid": amountPaid = item.value.flatMap(Double.init)
            case "promoterId": promoterId = item.value
            default: break
            }
        }

        guard let rid = reservationId, let paid = amountPaid else { return }
        NightlifeService.shared.confirmReservation(reservationId: rid, amountPaid: paid, promoterId: promoterId) { result in
            switch result {
            case .success:
                print("✅ Reservation confirmed")
            case .failure(let err):
                print("❌ Confirm failed:", err.localizedDescription)
            }
        }
    }
}

// MARK: - Entertainer Dashboard & Editor

struct EntertainerDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EntertainerProfile?
    @State private var upcoming: [(slot: LineupSlot, night: NightModel)] = []
    @State private var past: [(slot: LineupSlot, night: NightModel)] = []
    @State private var isLoading = true
    @State private var showEditProfile = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    HStack {
                        Button { showEditProfile = true } label: {
                            Label("Edit Profile", systemImage: "pencil")
                        }.buttonStyle(.borderedProminent)
                        Spacer()
                    }

                    if isLoading {
                        ProgressView("Loading…").padding(.top, 24)
                    } else if upcoming.isEmpty, past.isEmpty {
                        Text("No gigs yet. Once venues/promoters add you to lineups, they’ll appear here.")
                            .foregroundColor(.secondary).padding(.top, 24)
                    } else {
                        SectionHeader("Upcoming Gigs")
                        ForEach(upcoming, id: \.slot.id) { pair in GigRow(pair: pair) }

                        SectionHeader("Past Gigs")
                        ForEach(past, id: \.slot.id) { pair in GigRow(pair: pair) }
                    }
                }
                .padding()
            }
            .navigationTitle("Entertainer")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showEditProfile) {
                EntertainerProfileEditor(existing: profile) { updated, err in
                    if let err = err { errorMessage = err.localizedDescription }
                    self.profile = updated ?? self.profile
                }
            }
            .onAppear(perform: load)
            .alert("Error", isPresented: Binding(get: { errorMessage != nil },
                                                 set: { _ in errorMessage = nil })) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile?.stageName ?? "Your Stage Name")
                .font(.title2).bold()
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio).foregroundColor(.secondary)
            } else {
                Text("Add a short bio so venues/promoters know your vibe.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func load() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true
        NightlifeService.shared.fetchEntertainerProfile(uid: uid) { prof in
            DispatchQueue.main.async { self.profile = prof }
        }
        NightlifeService.shared.fetchEntertainerGigs(uid: uid) { pairs in
            DispatchQueue.main.async {
                let now = Date()
                self.upcoming = pairs.filter { $0.night.date >= now && $0.slot.status != "cancelled" }
                self.past     = pairs.filter { $0.night.date <  now }
                self.isLoading = false
            }
        }
    }
}

private struct GigRow: View {
    let pair: (slot: LineupSlot, night: NightModel)
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pair.night.title).font(.headline)
            Text("\(DateFormatter.shortDate.string(from: pair.night.date)) • \(pair.slot.role ?? "Performer")")
                .font(.subheadline).foregroundColor(.secondary)
            HStack(spacing: 12) {
                if let comp = pair.slot.compensation { Text(String(format: "$%.0f", comp)) }
                Text(pair.slot.status.capitalized).foregroundColor(.secondary)
            }
            .font(.footnote)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

struct EntertainerProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    var existing: EntertainerProfile?
    var onDone: (EntertainerProfile?, Error?) -> Void

    @State private var stageName: String = ""
    @State private var bio: String = ""
    @State private var genresText: String = ""  // comma separated for MVP
    @State private var instagram: String = ""
    @State private var tiktok: String = ""
    @State private var website: String = ""
    @State private var payoutMethod: String = "PayPal"
    @State private var payoutDetails: String = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Artist")) {
                    TextField("Stage name", text: $stageName)
                    TextField("Genres (comma separated)", text: $genresText)
                    TextEditor(text: $bio).frame(minHeight: 100)
                }
                Section(header: Text("Socials")) {
                    TextField("Instagram", text: $instagram).autocapitalization(.none)
                    TextField("TikTok", text: $tiktok).autocapitalization(.none)
                    TextField("Website", text: $website).keyboardType(.URL).autocapitalization(.none)
                }
                Section(header: Text("Payout")) {
                    TextField("Method (e.g. PayPal)", text: $payoutMethod)
                    TextField("Details (e.g. paypal email)", text: $payoutDetails).autocapitalization(.none)
                }
                Section {
                    Button { save() } label: { if saving { ProgressView() } else { Text("Save") } }
                        .disabled(stageName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .navigationTitle("Entertainer Profile")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                if let e = existing {
                    stageName = e.stageName
                    bio = e.bio ?? ""
                    genresText = e.genres.joined(separator: ", ")
                    instagram = e.socials["instagram"] ?? ""
                    tiktok = e.socials["tiktok"] ?? ""
                    website = e.socials["website"] ?? ""
                    payoutMethod = e.payoutMethod ?? "PayPal"
                    payoutDetails = e.payoutDetails ?? ""
                }
            }
        }
    }

    private func save() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        saving = true
        let genres = genresText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let socials = [
            "instagram": instagram,
            "tiktok": tiktok,
            "website": website
        ].filter { !$0.value.isEmpty }

        NightlifeService.shared.saveEntertainerProfile(
            uid: uid,
            stageName: stageName,
            bio: bio.isEmpty ? nil : bio,
            genres: genres,
            socials: socials,
            payoutMethod: payoutMethod.isEmpty ? nil : payoutMethod,
            payoutDetails: payoutDetails.isEmpty ? nil : payoutDetails
        ) { err in
            saving = false
            if let err = err { onDone(nil, err) }
            else {
                let updated = EntertainerProfile(id: uid, stageName: stageName, bio: bio, genres: genres, socials: socials, payoutMethod: payoutMethod, payoutDetails: payoutDetails)
                onDone(updated, nil)
                dismiss()
            }
        }
    }
}

// MARK: - Simple Lineup Manager (MVP)

struct LineupManagerView: View {
    let nightId: String
    @State private var slots: [LineupSlot] = []
    @State private var isLoading = true
    @State private var entertainerUid = ""
    @State private var role = "Performer"
    @State private var compText = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section(header: Text("Current Lineup")) {
                if isLoading { ProgressView() }
                ForEach(slots) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.entertainerId).font(.headline) // TODO: replace with stageName lookup
                        Text("\(s.role ?? "Performer") • \(s.status.capitalized)")
                            .font(.footnote).foregroundColor(.secondary)
                        if let c = s.compensation { Text(String(format: "$%.0f", c)).font(.footnote) }
                    }
                }
                if !isLoading && slots.isEmpty {
                    Text("No entertainers yet.").foregroundColor(.secondary)
                }
            }
            Section(header: Text("Add to Lineup (MVP)")) {
                TextField("Entertainer UID", text: $entertainerUid).autocapitalization(.none)
                TextField("Role (e.g. Headliner, DJ)", text: $role)
                TextField("Compensation (optional)", text: $compText).keyboardType(.numberPad)
                Button("Add") { add() }
            }
            if let err = error { Text(err).foregroundColor(.red) }
        }
        .navigationTitle("Lineup")
        .onAppear { reload() }
    }

    private func reload() {
        isLoading = true
        NightlifeService.shared.fetchLineup(nightId: nightId) { list in
            self.slots = list
            self.isLoading = false
        }
    }

    private func add() {
        let comp = Double(compText)
        NightlifeService.shared.upsertLineupSlot(
            nightId: nightId,
            entertainerUid: entertainerUid,
            role: role.isEmpty ? nil : role,
            startAt: nil, endAt: nil,
            compensation: comp,
            status: "invited"
        ) { result in
            switch result {
            case .failure(let e): error = e.localizedDescription
            case .success: error = nil; entertainerUid = ""; compText = ""; reload()
            }
        }
    }
}

// MARK: - Home & Application

struct NightlifeHomeView: View {
    // Routing & UI state
    @State private var roleSelection: String? = nil
    @State private var showPendingScreen = false
    @State private var showApplicationForm = false
    @State private var applicationType: String = "" // "promoter" | "venue" | "entertainer"

    // Sheets
    @State private var showCustomerSheet = false
    @State private var showEntertainerDashboard = false
    @State private var showPromoterDashboard = false
    @State private var showVenueDashboard = false
    @State private var activeVenueId: String? = nil

    // Latency fixes: spinner + single temp listener + timeout
    @State private var isCheckingRole = false
    @State private var appListenerHandle: DatabaseHandle?
    @State private var appListenerPath: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Nightlife")
                .font(.largeTitle).bold()
                .padding(.top)

            roleButton(title: "I'm a Customer", icon: "person.fill") {
                guard !isCheckingRole else { return }
                showCustomerSheet = true
            }
            roleButton(title: "I'm a Promoter", icon: "megaphone.fill") {
                guard !isCheckingRole else { return }
                applicationType = "promoter"
                handleRoleSelectionUnified("promoter")
            }
            roleButton(title: "I'm a Venue", icon: "building.2.fill") {
                guard !isCheckingRole else { return }
                applicationType = "venue"
                handleRoleSelectionUnified("venue")
            }
            roleButton(title: "I'm an Entertainer", icon: "music.mic") {
                guard !isCheckingRole else { return }
                applicationType = "entertainer"
                handleRoleSelectionUnified("entertainer")
            }

            Spacer()
        }
        // Forms / modals
        .sheet(isPresented: $showApplicationForm) {
            NightlifeApplicationForm(type: applicationType)
        }
        .sheet(isPresented: $showPendingScreen) {
            Text("Your application is under review. We'll notify you when approved.")
                .padding()
        }
        .sheet(isPresented: $showCustomerSheet) {
            CustomerExploreView()
        }
        .sheet(isPresented: $showEntertainerDashboard) {
            EntertainerDashboardScreen()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPromoterDashboard) {
            NavigationStack {
                PromoterDashboardView()
                    .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showVenueDashboard) {
            NavigationStack {
                // If you track user's associated venue(s), pass one here
                VenueDashboardView(initialVenueId: activeVenueId)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(.dark)
        }
        // Spinner overlay to avoid "dead tap" feeling
        .overlay {
            if isCheckingRole {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking your status…").font(.footnote)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .allowsHitTesting(!isCheckingRole)
    }

    // MARK: - UI helper
    private func roleButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).bold()
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue.opacity(0.2))
            .cornerRadius(12)
        }
        .padding(.horizontal)
        .disabled(isCheckingRole)
        .opacity(isCheckingRole ? 0.7 : 1.0)
    }

    // MARK: - Role routing (unified; removes old laggy variants)

    private enum RoleType: String { case promoter, venue, entertainer }

    private func liveRolePath(_ type: RoleType, uid: String) -> String {
        switch type {
        case .promoter:    return "promoters/\(uid)"
        case .venue:       return "venueOwners/\(uid)" // if venues are keyed by owner
        case .entertainer: return "entertainers/\(uid)"
        }
    }

    private func applicationPath(_ type: RoleType, uid: String) -> String {
        switch type {
        case .promoter:    return "promoterApplications/\(uid)"
        case .venue:       return "venueApplications/\(uid)"
        case .entertainer: return "entertainerApplications/\(uid)"
        }
    }

    private func openRoleUI(for type: RoleType) {
        switch type {
        case .promoter:    showPromoterDashboard = true
        case .venue:       showVenueDashboard = true
        case .entertainer: showEntertainerDashboard = true
        }
    }

    /// Single entry point used by all role buttons.
    /// Fixes latency by: (1) one-shot cached read, (2) single temp listener, (3) 3s timeout.
    private func handleRoleSelectionUnified(_ rawType: String) {
        guard let uid = Auth.auth().currentUser?.uid,
              let type = RoleType(rawValue: rawType) else { return }

        isCheckingRole = true
        removeAppListenerIfAny()

        let db = Database.database().reference()
        let livePath = liveRolePath(type, uid: uid)
        let appPath  = applicationPath(type, uid: uid)

        // 3s hard timeout so UI never feels stuck
        var timedOut = false
        let timeout = DispatchWorkItem {
            timedOut = true
            isCheckingRole = false
            showPendingScreen = false
            applicationType = type.rawValue
            showApplicationForm = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeout)

        // 1) Fast path: single fetch (hits local cache if warm)
        db.child(livePath).getData { err, snap in
            if timedOut { return }

            if let dict = snap?.value as? [String: Any], (dict["approved"] as? Bool) == true {
                timeout.cancel()
                isCheckingRole = false
                openRoleUI(for: type)
                return
            }

            // 2) Single temporary listener on application node
            let ref = db.child(appPath)

            // IMPORTANT: Use the explicit 'with:' overload to avoid the (DataSnapshot, String?) variant.
            let handle = ref.observe(.value, with: { appSnap in
                if timedOut { return }

                guard appSnap.exists(),
                      let dict = appSnap.value as? [String: Any],
                      let status = dict["status"] as? String else {
                    timeout.cancel()
                    isCheckingRole = false
                    showPendingScreen = false
                    applicationType = type.rawValue
                    showApplicationForm = true
                    removeAppListenerIfAny()
                    return
                }

                switch status {
                case "approved":
                    // Self-heal live node, then open UI
                    var updates: [String: Any] = [
                        "approved": true,
                        "approvedAt": ServerValue.timestamp()
                    ]
                    if type == .entertainer,
                       let stageName = dict["stageName"] as? String, !stageName.isEmpty {
                        updates["stageName"] = stageName
                    }
                    db.child(livePath).updateChildValues(updates) { _, _ in
                        timeout.cancel()
                        isCheckingRole = false
                        showPendingScreen = false
                        showApplicationForm = false
                        openRoleUI(for: type)
                        removeAppListenerIfAny()
                    }

                case "pending":
                    timeout.cancel()
                    isCheckingRole = false
                    showApplicationForm = false
                    showPendingScreen = true
                    // keep listener so auto-advance works when admin approves

                case "rejected":
                    timeout.cancel()
                    isCheckingRole = false
                    showPendingScreen = false
                    applicationType = type.rawValue
                    showApplicationForm = true
                    removeAppListenerIfAny()

                default:
                    timeout.cancel()
                    isCheckingRole = false
                    showApplicationForm = true
                    removeAppListenerIfAny()
                }
            })

            appListenerHandle = handle
            appListenerPath = appPath
        }
    }

    private func removeAppListenerIfAny() {
        guard let path = appListenerPath, let h = appListenerHandle else { return }
        Database.database().reference(withPath: path).removeObserver(withHandle: h)
        appListenerHandle = nil
        appListenerPath = nil
    }
}


// MARK: - Application Form (promoter / venue / entertainer)

struct NightlifeApplicationForm: View {
    /// "promoter" or "venue" or "entertainer"
    let type: String
    @Environment(\.dismiss) private var dismiss

    // Prefill from Auth where possible
    @State private var fullName: String = Auth.auth().currentUser?.displayName ?? ""
    @State private var email: String = Auth.auth().currentUser?.email ?? ""
    @State private var phone: String = ""
    @State private var businessName: String = "" // stageName when entertainer
    @State private var website: String = ""
    @State private var instagram: String = ""
    @State private var tiktok: String = ""
    @State private var descriptionText: String = ""

    @State private var agreeToTerms: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var submitted: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(formTitle)) {
                    TextField("Full name", text: $fullName)
                        .textContentType(.name)

                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)

                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)

                    TextField(businessPlaceholder, text: $businessName)
                        .textContentType(.organizationName)
                }

                Section(header: Text("Online Presence")) {
                    TextField("Website (optional)", text: $website)
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    TextField("Instagram (optional)", text: $instagram)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    TextField("TikTok (optional)", text: $tiktok)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text(descriptionHeader)) {
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 120)
                }

                Section {
                    Toggle("I agree to the platform terms & 2% platform fee policy", isOn: $agreeToTerms)
                }

                if let msg = errorMessage {
                    Section { Text(msg).foregroundColor(.red) }
                }

                if submitted {
                    Section {
                        Label("Application submitted. We’ll review it shortly.", systemImage: "hourglass")
                            .foregroundColor(.green)
                        Button("Close") { dismiss() }
                    }
                } else {
                    Section {
                        Button(action: submit) {
                            if isSubmitting { ProgressView() }
                            else { Label("Submit Application", systemImage: "paperplane.fill") }
                        }
                        .disabled(!isFormValid || isSubmitting)
                    }
                }
            }
            .navigationTitle(formTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear {
            if fullName.isEmpty, let nameFromEmail = email.split(separator: "@").first {
                fullName = String(nameFromEmail).replacingOccurrences(of: ".", with: " ").capitalized
            }
        }
    }

    // Derived
    private var formTitle: String {
        switch type {
        case "venue": return "Venue Application"
        case "entertainer": return "Entertainer Application"
        default: return "Promoter Application"
        }
    }

    private var businessPlaceholder: String {
        switch type {
        case "venue": return "Venue name"
        case "entertainer": return "Stage / Artist name"
        default: return "Business / brand name"
        }
    }

    private var descriptionHeader: String {
        switch type {
        case "venue": return "Tell us about your venue"
        case "entertainer": return "Tell us about your artistry"
        default: return "Tell us about your promotion business"
        }
    }

    private var isFormValid: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.contains("@") &&
        !phone.trimmingCharacters(in: .whitespaces).isEmpty &&
        !businessName.trimmingCharacters(in: .whitespaces).isEmpty &&
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 &&
        agreeToTerms
    }

    // Submit
    private func submit() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "You must be signed in to apply."
            return
        }
        isSubmitting = true
        errorMessage = nil

        let basePayload: [String: Any] = [
            "uid": uid,
            "type": type,
            "fullName": fullName,
            "email": email,
            "phone": phone,
            "businessName": businessName,
            "website": website,
            "instagram": instagram,
            "tiktok": tiktok,
            "description": descriptionText,
            "status": "pending",
            "approved": false,
            "submittedAt": ServerValue.timestamp()
        ]

        let (path, payload): (String, [String: Any])
        switch type {
        case "venue":
            path = "venueApplications/\(uid)"
            payload = basePayload
        case "entertainer":
            path = "entertainerApplications/\(uid)"
            payload = basePayload.merging([
                "stageName": businessName,
                "genres": [] as [String]
            ]) { $1 }
        default:
            path = "promoterApplications/\(uid)"
            payload = basePayload
        }

        Database.database().reference(withPath: path).setValue(payload) { error, _ in
            isSubmitting = false
            if let error = error {
                self.errorMessage = "Submission failed: \(error.localizedDescription)"
            } else {
                self.submitted = true
            }
        }
    }
}

// MARK: - Customer Explore

struct CustomerExploreView: View {
    @Environment(\.dismiss) private var dismiss

    // Internal venues (optional—can be empty if you don't want any DB data)
    @State private var venues: [VenueModel] = []
    @State private var filtered: [VenueModel] = []

    // External feed (HTTP live stream)
    @State private var includeExternal: Bool = true
    @State private var externalEvents: [ExternalEvent] = []
    @State private var externalFiltered: [ExternalEvent] = []

    @State private var isLoading = true
    @State private var showSafari = false
    @State private var safariURL: URL?

    // Search & Date
    @State private var showSearch: Bool = true
    @State private var cityQuery: String = ""
    @State private var selectedDate: Date = Date()   // non-optional → always visible
    @State private var useDateFilter: Bool = false   // toggle to apply date

    // Simple debounce for city typing
    @State private var debounce: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Search controls
                if showSearch {
                    HStack(spacing: 10) {
                        TextField("Search city (e.g. Miami)", text: $cityQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runSearch() } // return key triggers fetch
                            .onChange(of: cityQuery) { _ in
                                // Debounce re-query so we don't spam the backend
                                debounce?.cancel()
                                let work = DispatchWorkItem { runSearch() }
                                debounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                            }
                    }
                    .padding(.horizontal)
                }

                // Filters row
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Toggle(isOn: $useDateFilter) {
                            Label("Filter by date", systemImage: "calendar")
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .onChange(of: useDateFilter) { _ in runSearch() }

                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!useDateFilter)
                            .opacity(useDateFilter ? 1 : 0.4)
                            .onChange(of: selectedDate) { _ in if useDateFilter { runSearch() } }
                    }
                    HStack {
                        Toggle("Include external events", isOn: $includeExternal)
                            .onChange(of: includeExternal) { _ in applyFilters() }
                        Spacer()
                        Button("Reset") { resetFilters() }.font(.footnote)
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)

                if isLoading {
                    ProgressView("Loading…").padding(.top, 24)
                } else if filtered.isEmpty && (!includeExternal || externalFiltered.isEmpty) {
                    VStack(spacing: 8) {
                        Text("No venues or external events match your filters").foregroundColor(.secondary)
                        Button("Reset Filters") { resetFilters() }
                    }
                    .padding(.top, 24)
                } else {
                    List {
                        if !filtered.isEmpty {
                            Section("Venues") {
                                ForEach(filtered, id: \.id) { v in
                                    NavigationLink(value: v) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(v.name).font(.headline)
                                            Text(v.address).font(.subheadline).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if includeExternal && !externalFiltered.isEmpty {
                            Section("External Events") {
                                ForEach(externalFiltered, id: \.id) { e in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(e.title).font(.headline)
                                        Text("\(e.venueName)\(e.venueName.isEmpty ? "" : " • ")\(e.address)")
                                            .font(.subheadline).foregroundColor(.secondary)
                                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.footnote).foregroundColor(.secondary)
                                        HStack {
                                            if let p = e.price { Text(String(format: "$%.0f", p)) }
                                            if let s = e.source { Text(s.capitalized).foregroundColor(.secondary) }
                                            Spacer()
                                            if let u = e.externalURL, let url = URL(string: u) {
                                                Button("View") { safariURL = url; showSafari = true }
                                                    .buttonStyle(.borderedProminent)
                                            }
                                        }
                                        .font(.footnote)
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Nightlife")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { showSearch.toggle() } } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                }
            }
            .navigationDestination(for: VenueModel.self) { venue in
                VenueDetailView(venue: venue)
            }
            .onAppear { initialLoad() }
            .sheet(isPresented: $showSafari) {
                if let url = safariURL { NightlifeSafariView(url: url) }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Data load (live HTTP; DB venues optional)
    private func initialLoad() {
        isLoading = true

        // Optional internal venues
        NightlifeService.shared.fetchVenues { list in
            DispatchQueue.main.async {
                self.venues = list
                self.filtered = list
            }
        }

        runSearch()
    }

    /// Compute current date window for the query
    private func currentWindow() -> (start: Date, end: Date) {
        let cal = Calendar.current
        if useDateFilter {
            let start = cal.startOfDay(for: selectedDate)
            let end = cal.date(byAdding: .day, value: 1, to: start)! // same-day window
            return (start, end)
        } else {
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: 14, to: start)! // default 2 weeks
            return (start, end)
        }
    }

    /// Hit Cloud Functions via ExternalFeedsClient and then apply local filters
    private func runSearch() {
        isLoading = true
        let (start, end) = currentWindow()
        let city = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        ExternalFeedsClient.shared.load(
            city: city.isEmpty ? nil : city,
            start: start,
            end: end
        ) { list in
            self.externalEvents = list
            self.applyFilters()
            self.isLoading = false
        }
    }

    // MARK: - Filtering
    private func resetFilters() {
        cityQuery = ""
        selectedDate = Date()
        useDateFilter = false
        runSearch()
    }

    private func applyFilters() {
        // VENUES (optional; stays local)
        let q = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            self.filtered = venues
        } else {
            self.filtered = venues.filter {
                $0.address.localizedCaseInsensitiveContains(q) ||
                $0.name.localizedCaseInsensitiveContains(q)
            }
        }

        // EXTERNAL (filter locally too)
        var ext = externalEvents
        if !q.isEmpty {
            ext = ext.filter { e in
                e.address.localizedCaseInsensitiveContains(q) ||
                e.venueName.localizedCaseInsensitiveContains(q) ||
                e.title.localizedCaseInsensitiveContains(q)
            }
        }
        if useDateFilter {
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: selectedDate)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
            ext = ext.filter { e in e.date >= dayStart && e.date < dayEnd }
        }
        self.externalFiltered = ext.sorted { $0.date < $1.date }
    }
}

// MARK: - Venue list

struct VenueListView: View {
    @State private var venues: [VenueModel] = []
    @State private var isLoading = true
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Search by venue or city", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                if isLoading {
                    ProgressView("Loading venues...").padding(.top, 24)
                } else {
                    List(filteredVenues) { venue in
                        NavigationLink(destination: VenueDetailView(venue: venue)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(venue.name).font(.headline)
                                Text(venue.address).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Venues")
        }
        .onAppear { loadVenues() }
    }

    private var filteredVenues: [VenueModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return venues }
        return venues.filter { v in
            v.name.localizedCaseInsensitiveContains(q) ||
            v.address.localizedCaseInsensitiveContains(q)
        }
    }

    private func loadVenues() {
        isLoading = true
        NightlifeService.shared.fetchVenues { list in
            DispatchQueue.main.async {
                self.venues = list.sorted { $0.name < $1.name }
                self.isLoading = false
            }
        }
    }
}

// ===== FILE-SCOPE NightlifeService extensions (DO NOT NEST INSIDE A VIEW) =====

// MARK: - NightlifeService: checkout URL, guestlist, payment confirm, reservation hold

extension NightlifeService {
    /// Build your hosted checkout URL (deposit mode aware)
    func buildCheckoutURL(
        nightId: String,
        tableId: String,
        reservationId: String,
        isDeposit: Bool,
        baseAmount: Double,
        platformFeeRate: Double = 0.02,
        promoterId: String? = nil
    ) -> URL? {
        let fee = (baseAmount * platformFeeRate).rounded(toPlaces: 2)
        let total = (baseAmount + fee).rounded(toPlaces: 2)

        var comps = URLComponents(string: "https://blackappios.web.app")!
        comps.queryItems = [
            URLQueryItem(name: "type", value: "table"),
            URLQueryItem(name: "nightId", value: nightId),
            URLQueryItem(name: "tableId", value: tableId),
            URLQueryItem(name: "reservationId", value: reservationId),
            URLQueryItem(name: "depositMode", value: isDeposit ? "true" : "false"),
            URLQueryItem(name: "tableQty", value: "1"),
            URLQueryItem(name: "tablePrice", value: String(baseAmount)),
            URLQueryItem(name: "baseTotal", value: String(baseAmount)),
            URLQueryItem(name: "platformFee", value: String(fee)),
            URLQueryItem(name: "totalWithFee", value: String(total)),
            URLQueryItem(name: "callback", value: "https://blackapp.app/pay/callback")
        ]
        if let promoterId {
            comps.queryItems?.append(URLQueryItem(name: "promoterId", value: promoterId))
        }
        return comps.url
    }

    /// Join guest list for a night
    func joinGuestlist(nightId: String, name: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(.failure(NSError(domain: "auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])))
            return
        }
        let ref = db.child("guestlists").child(nightId).childByAutoId()
        let payload: [String: Any] = [
            "name": name,
            "userId": uid,
            "promoCode": NSNull(),
            "status": "approved", // or "pending"
            "createdAt": Date().timeIntervalSince1970
        ]
        ref.setValue(payload) { err, _ in
            if let err = err { completion(.failure(err)) }
            else { completion(.success(ref.key ?? "")) }
        }
    }

    /// Confirm reservation after hosted checkout callback
    func confirmReservation(
        reservationId: String,
        amountPaid: Double,
        promoterId: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let fn = Functions.functions()
        var payload: [String: Any] = [
            "reservationId": reservationId,
            "amountPaid": amountPaid
        ]
        if let promoterId { payload["promoterId"] = promoterId }

        fn.httpsCallable("confirmPaymentNightlife").call(payload) { _, error in
            if let error = error { completion(.failure(error)) }
            else { completion(.success(())) }
        }
    }

    /// Create reservation hold via callable CF
    func createReservationHold(
        nightId: String,
        tableId: String,
        minSpend: Double,
        depositPercent: Int,
        completion: @escaping (Result<(reservationId: String, holdExpiresAt: TimeInterval, depositAmount: Double), Error>) -> Void
    ) {
        guard Auth.auth().currentUser != nil else {
            completion(.failure(NSError(domain: "auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])))
            return
        }
        let functions = Functions.functions()
        functions.httpsCallable("createReservationHold").call([
            "nightId": nightId,
            "tableId": tableId,
            "minSpend": minSpend,
            "depositPercent": depositPercent
        ]) { result, error in
            if let error = error { return completion(.failure(error)) }
            guard
                let dict = result?.data as? [String: Any],
                let resId = dict["reservationId"] as? String,
                let hold = dict["holdExpiresAt"] as? TimeInterval,
                let dep  = dict["depositAmount"] as? Double
            else {
                return completion(.failure(NSError(domain: "parse", code: 0, userInfo: [NSLocalizedDescriptionKey: "Malformed response"])))
            }
            completion(.success((resId, hold, dep)))
        }
    }
}

// MARK: - NightlifeService: Entertainer APIs & Lineup

extension NightlifeService {
    func fetchEntertainerProfile(uid: String, completion: @escaping (EntertainerProfile?) -> Void) {
        db.child("entertainers").child(uid).observeSingleEvent(of: .value) { snap in
            completion(EntertainerProfile.from(snap))
        }
    }

    func saveEntertainerProfile(
        uid: String,
        stageName: String,
        bio: String?,
        genres: [String],
        socials: [String: String],
        payoutMethod: String?,
        payoutDetails: String?,
        completion: @escaping (Error?) -> Void
    ) {
        let payload: [String: Any?] = [
            "stageName": stageName,
            "bio": bio,
            "genres": genres,
            "socials": socials,
            "payoutMethod": payoutMethod,
            "payoutDetails": payoutDetails,
            "approved": nil  // preserve approval if admin set it
        ]
        let clean = payload.reduce(into: [String: Any]()) { if let v = $1.value { $0[$1.key] = v } }
        db.child("entertainers").child(uid).updateChildValues(clean) { err, _ in completion(err) }
    }

    func fetchEntertainerGigs(
        uid: String,
        since daysBack: Int = 60,
        completion: @escaping ([(slot: LineupSlot, night: NightModel)]) -> Void
    ) {
        let indexRef = db.child("lineupsByEntertainer").child(uid)
        indexRef.observeSingleEvent(of: .value) { idx in
            if let map = idx.value as? [String: String] {
                var out: [(slot: LineupSlot, night: NightModel)] = []
                let group = DispatchGroup()
                for (nightId, slotId) in map {
                    group.enter()
                    self.db.child("nights").child(nightId).observeSingleEvent(of: .value) { ns in
                        guard let n = NightModel.from(ns) else { group.leave(); return }
                        self.db.child("lineups").child(nightId).child(slotId).observeSingleEvent(of: .value) { ss in
                            if let s = LineupSlot.from(nightId: nightId, snap: ss) { out.append((s, n)) }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: .main) {
                    completion(out.sorted { $0.night.date < $1.night.date })
                }
            } else {
                let cut = Date().addingTimeInterval(Double(-daysBack) * 86400).timeIntervalSince1970
                self.db.child("nights").queryOrdered(byChild: "date").queryStarting(atValue: cut).observeSingleEvent(of: .value) { ns in
                    var out: [(slot: LineupSlot, night: NightModel)] = []
                    let group = DispatchGroup()
                    for case let nSnap as DataSnapshot in ns.children {
                        guard let n = NightModel.from(nSnap) else { continue }
                        group.enter()
                        self.db.child("lineups").child(n.id).observeSingleEvent(of: .value) { ls in
                            for case let sSnap as DataSnapshot in ls.children {
                                if let s = LineupSlot.from(nightId: n.id, snap: sSnap), s.entertainerId == uid {
                                    out.append((s, n))
                                }
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        completion(out.sorted { $0.night.date < $1.night.date })
                    }
                }
            }
        }
    }

    func fetchLineup(nightId: String, completion: @escaping ([LineupSlot]) -> Void) {
        db.child("lineups").child(nightId).observeSingleEvent(of: .value) { snap in
            var slots: [LineupSlot] = []
            for case let child as DataSnapshot in snap.children {
                if let s = LineupSlot.from(nightId: nightId, snap: child) { slots.append(s) }
            }
            completion(slots.sorted { ($0.startAt ?? 0) < ($1.startAt ?? 0) })
        }
    }

    func upsertLineupSlot(
        nightId: String,
        slotId: String? = nil,
        entertainerUid: String,
        role: String? = nil,
        startAt: TimeInterval? = nil,
        endAt: TimeInterval? = nil,
        compensation: Double? = nil,
        status: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let ref = (slotId == nil)
            ? db.child("lineups").child(nightId).childByAutoId()
            : db.child("lineups").child(nightId).child(slotId!)

        let payload: [String: Any?] = [
            "entertainerId": entertainerUid,
            "role": role,
            "startAt": startAt,
            "endAt": endAt,
            "compensation": compensation,
            "status": status
        ]
        let clean = payload.reduce(into: [String: Any]()) { if let v = $1.value { $0[$1.key] = v } }

        ref.updateChildValues(clean) { err, _ in
            if let err = err { completion(.failure(err)) }
            else { completion(.success(ref.key ?? "")) }
        }
    }
}
