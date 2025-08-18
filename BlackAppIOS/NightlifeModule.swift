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

// MARK: - Service Layer

final class NightlifeService: ObservableObject {
    static let shared = NightlifeService()
    private init() {}

    // NOTE: internal visibility so extensions in this file can use it
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

// MARK: - Views

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

                // Join Guest List when a night is selected
                if let n = selectedNight {
                    Divider().padding(.vertical, 8)
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

// MARK: - Home & Application

struct NightlifeHomeView: View {
    @State private var roleSelection: String? = nil
    @State private var isLoading = false
    @State private var showPendingScreen = false
    @State private var showApplicationForm = false
    @State private var applicationType: String = "" // "promoter" or "venue"

    // Customer sheet
    @State private var showCustomerSheet = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Nightlife")
                .font(.largeTitle).bold()
                .padding(.top)

            roleButton(title: "I'm a Customer", icon: "person.fill") {
                showCustomerSheet = true
            }
            roleButton(title: "I'm a Promoter", icon: "megaphone.fill") {
                applicationType = "promoter"
                handleRoleSelection(type: "promoter")
            }
            roleButton(title: "I'm a Venue", icon: "building.2.fill") {
                applicationType = "venue"
                handleRoleSelection(type: "venue")
            }

            Spacer()
        }
        // If you also want a push-based flow, you can add a navigationDestination here.
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
    }

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
    }

    private func handleRoleSelection(type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let refPath = type == "promoter" ? "promoters/\(uid)" : "venues/\(uid)"
        Database.database().reference(withPath: refPath).observeSingleEvent(of: .value) { snapshot in
            if snapshot.exists(), let dict = snapshot.value as? [String: Any], dict["approved"] as? Bool == true {
                roleSelection = type
            } else {
                checkApplicationStatus(type: type)
            }
        }
    }

    private func checkApplicationStatus(type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let appPath = type == "promoter" ? "promoterApplications/\(uid)" : "venueApplications/\(uid)"
        Database.database().reference(withPath: appPath).observeSingleEvent(of: .value) { snapshot in
            if snapshot.exists(), let dict = snapshot.value as? [String: Any], dict["status"] as? String == "pending" {
                showPendingScreen = true
            } else {
                showApplicationForm = true
            }
        }
    }
}

struct NightlifeApplicationForm: View {
    /// "promoter" or "venue"
    let type: String
    @Environment(\.dismiss) private var dismiss

    // Prefill from Auth where possible
    @State private var fullName: String = Auth.auth().currentUser?.displayName ?? ""
    @State private var email: String = Auth.auth().currentUser?.email ?? ""
    @State private var phone: String = ""
    @State private var businessName: String = ""
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

                Section(header: Text("Tell us about your \(type == "venue" ? "venue" : "promotion business")")) {
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 120)
                }

                Section {
                    Toggle("I agree to the platform terms & 2% platform fee policy", isOn: $agreeToTerms)
                }

                if let msg = errorMessage {
                    Section {
                        Text(msg).foregroundColor(.red)
                    }
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
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Label("Submit Application", systemImage: "paperplane.fill")
                            }
                        }
                        .disabled(!isFormValid || isSubmitting)
                    }
                }
            }
            .navigationTitle(formTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if fullName.isEmpty, let nameFromEmail = email.split(separator: "@").first {
                fullName = String(nameFromEmail).replacingOccurrences(of: ".", with: " ").capitalized
            }
        }
    }

    // Derived
    private var formTitle: String {
        type == "venue" ? "Venue Application" : "Promoter Application"
    }

    private var businessPlaceholder: String {
        type == "venue" ? "Venue name" : "Business / brand name"
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

        let path = type == "venue" ? "venueApplications/\(uid)" : "promoterApplications/\(uid)"
        let ref = Database.database().reference(withPath: path)

        let payload: [String: Any] = [
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

        ref.setValue(payload) { error, _ in
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
import SwiftUI
import SafariServices

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

        // EXTERNAL (filter locally too, in case the server returned broad results)
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

    // Filter by name OR address (city is typically in the address string)
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

// MARK: - NightlifeService: checkout URL, guestlist, payment confirm
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
}
import FirebaseFunctions

extension NightlifeService {
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
