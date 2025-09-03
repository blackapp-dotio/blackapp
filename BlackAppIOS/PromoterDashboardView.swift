import SwiftUI
import PhotosUI
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage

// MARK: - Helpers (shared)
fileprivate extension TimeInterval {
    var asShortDateTime: String {
        let d = Date(timeIntervalSince1970: self)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

fileprivate func shortDate(_ date: Date) -> String {
    DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
}

// MARK: - Pulsating violet console background
fileprivate struct VioletConsoleBackground: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 24/255, green: 0/255, blue: 40/255)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.65)
                ]),
                center: .center,
                startRadius: 100,
                endRadius: 900
            )
            .ignoresSafeArea()

            AngularGradient(
                gradient: Gradient(colors: [
                    Color.purple.opacity(0.0),
                    Color.purple.opacity(animate ? 0.23 : 0.05),
                    Color.pink.opacity(animate ? 0.13 : 0.03),
                    Color.purple.opacity(0.0)
                ]),
                center: .center
            )
            .blendMode(.screen)
            .blur(radius: animate ? 70 : 120)
            .opacity(0.75)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    animate.toggle()
                }
            }
        }
    }
}

// MARK: - Violet glass card
fileprivate struct VioletGlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .background(
                ZStack {
                    Color.white.opacity(0.03)
                    LinearGradient(
                        colors: [Color.purple.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .background(.ultraThinMaterial.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.pink.opacity(0.25), Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.purple.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Stats model
struct PromoterStats {
    var gmv: Double
    var paidCount: Int
    var heldCount: Int
    var expiredCount: Int
    static var empty: PromoterStats { .init(gmv: 0, paidCount: 0, heldCount: 0, expiredCount: 0) }
}

// MARK: - Event model for "My Events" (owned by user)
fileprivate struct PromoterEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let date: TimeInterval?
    let venueName: String
    let address: String
    // Storage model
    var imagePath: String?
    // Legacy direct URL support (older rows)
    var imageURL: String?
    let status: String?
    let ownerId: String
    // Runtime-resolved public URL for UI
    var resolvedImageURL: URL?

    // NEW: advanced editing fields
    var payoutMethod: String?
    var payoutDetails: String?
    var ticketPrice: Double?
    var ticketQuantity: Int?
    var tablePrice: Double?
    var tableQuantity: Int?
    var depositPercent: Int?

    static func from(_ snap: DataSnapshot) -> PromoterEvent? {
        guard let v = snap.value as? [String: Any] else { return nil }

        // Owner
        let owner = (v["userId"] as? String)
                 ?? (v["createdBy"] as? String)
                 ?? (v["ownerId"] as? String)
                 ?? ""
        guard !owner.isEmpty else { return nil }

        // Title
        guard let title = (v["title"] as? String) ?? (v["name"] as? String) else { return nil }

        // Date
        let dateTs = (v["date"] as? TimeInterval)
                  ?? (v["startAt"] as? TimeInterval)
                  ?? (v["startTime"] as? TimeInterval)
                  ?? (v["timestamp"] as? TimeInterval)

        // Venue / address
        let venueName = (v["venueName"] as? String) ?? (v["venue"] as? String) ?? ""
        let address = (v["address"] as? String) ?? (v["location"] as? String) ?? ""

        // Image fields
        let imagePath = v["imagePath"] as? String // ✅ current source of truth
        let legacyURL = (v["imageURL"] as? String)
                     ?? (v["coverImageURL"] as? String)
                     ?? (v["image"] as? String)
                     ?? (v["cover"] as? String)

        let status = v["status"] as? String

        // NEW: advanced fields
        let payoutMethod = v["payoutMethod"] as? String
        let payoutDetails = v["payoutDetails"] as? String
        let ticketPrice = v["ticketPrice"] as? Double
        let ticketQuantity = (v["ticketQuantity"] as? Int) ?? (v["ticketQty"] as? Int)
        let tablePrice = v["tablePrice"] as? Double
        let tableQuantity = (v["tableQuantity"] as? Int) ?? (v["tableQty"] as? Int)
        let depositPercent = v["depositPercent"] as? Int

        return PromoterEvent(
            id: snap.key,
            title: title,
            date: dateTs,
            venueName: venueName,
            address: address,
            imagePath: imagePath,
            imageURL: legacyURL,
            status: status,
            ownerId: owner,
            resolvedImageURL: nil,
            payoutMethod: payoutMethod,
            payoutDetails: payoutDetails,
            ticketPrice: ticketPrice,
            ticketQuantity: ticketQuantity,
            tablePrice: tablePrice,
            tableQuantity: tableQuantity,
            depositPercent: depositPercent
        )
    }
}

// MARK: - UI Bits
fileprivate struct KPI: View {
    let title: String; let value: String
    var body: some View {
        VioletGlassCard {
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundColor(.white.opacity(0.7))
                Text(value).font(.headline).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

fileprivate struct StatusPill: View {
    let text: String
    init(_ t: String) { self.text = t }
    var color: Color {
        switch text {
        case "paid": return .green
        case "held": return .orange
        case "expired": return .red
        default: return .gray
        }
    }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
            .foregroundColor(.white)
    }
}

// MARK: - Share sheet (Gossip-first + QR, powered by GossipShareKit)
struct PromoterShareSheet: View, Identifiable {
    let night: NightModel
    var id: String { night.id }
    @Environment(\.dismiss) var dismiss

    // Optional: resolve a flyer image to seed the Gossip composer
    @State private var flyerURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            Text("Share your event")
                .font(.headline)
                .foregroundColor(.white)

            // 1) Primary action: Post to Gossip (first!)
            Button {
                if let presenter = UIApplication.shared.keyWindowTopMostController {
                    GossipShareManager.shared.presentShare(
                        from: presenter,
                        payload: .event(night: night, flyerURL: flyerURL, deepLink: shareURL)
                    )
                }
            } label: {
                Label("Post to Gossip", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Divider().padding(.vertical, 4)

            // 2) Secondary: external share + QR
            if let link = shareURL {
                Text(link.absoluteString)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                QRCodeView(text: link.absoluteString)
                    .padding(.vertical, 8)

                if #available(iOS 16.0, *) {
                    ShareLink(item: link) {
                        Label("Share externally", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                } else {
                    ShareSheetController(items: [link])
                        .frame(height: 0) // no-op host; use button below if you'd rather
                    Button {
                        presentSystemShare(items: [link])
                    } label: {
                        Label("Share externally", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                }
            } else {
                Text("Couldn’t build link.").foregroundColor(.red)
            }

            Button("Close") { dismiss() }
                .tint(.purple)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.6))
        )
        .padding()
        .onAppear {
            resolveFlyerIfPossible()
        }
    }

    // Deep link that other surfaces can also share
    private var shareURL: URL? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        var comps = URLComponents(string: "https://blackapp.app/nightlife/venue/\(night.venueId)")!
        comps.queryItems = [
            URLQueryItem(name: "nightId", value: night.id),
            URLQueryItem(name: "promoterId", value: uid)
        ]
        return comps.url
    }

    // Optional: try to resolve a flyer from Storage if your NightModel stores a path
    private func resolveFlyerIfPossible() {
        // If NightModel has imagePath (as in your module), turn it into a download URL for the composer
        guard let path = night.imagePath, !path.isEmpty else { return }
        let ref = Storage.storage().reference(withPath: path)
        ref.downloadURL { url, _ in
            if let url { flyerURL = url }
        }
    }

    // Fallback system share for iOS < 16 or if you prefer an explicit button
    private func presentSystemShare(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.keyWindowTopMostController?.present(vc, animated: true)
    }
}

// MARK: - UIKit Share sheet bridge (kept for backwards compatibility)
fileprivate struct ShareSheetController: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Image upload helper (stores to Storage and returns the STORAGE PATH, not a URL)
fileprivate enum EventCoverUploader {
    static func uploadJPEG(_ data: Data, eventId: String, completion: @escaping (Result<String, Error>) -> Void) {
        let path = "eventCovers/\(eventId).jpg"
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        ref.putData(data, metadata: meta) { _, err in
            if let err = err {
                completion(.failure(err))
            } else {
                // ✅ Return the path; we store imagePath in DB
                completion(.success(path))
            }
        }
    }
}

// MARK: - Numeric text field helper
fileprivate struct NumberField<Value: LosslessStringConvertible>: View {
    let title: String
    @Binding var value: Value?
    var keyboard: UIKeyboardType = .decimalPad

    @State private var text: String = ""

    var body: some View {
        TextField(title, text: Binding(
            get: { text.isEmpty ? (value.map { String($0) } ?? "") : text },
            set: { new in
                text = new
                value = Value(new)
            }
        ))
        .keyboardType(keyboard)
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
    }
}

// MARK: - Edit Event Sheet
fileprivate struct EditEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    let eventId: String

    @State var title: String
    @State var venueName: String
    @State var address: String
    @State var date: Date
    @State var imagePath: String?          // ✅ storage path we will save
    @State var imagePreviewURL: String?    // for preview
    @State var published: Bool

    // NEW: Pricing & payout state
    @State var payoutMethod: String = "PayPal"
    @State var payoutDetails: String = ""
    @State var ticketPrice: Double?
    @State var ticketQuantity: Int?
    @State var tablePrice: Double?
    @State var tableQuantity: Int?
    @State var depositPercent: Int?

    @State private var saving = false
    @State private var errorText: String?

    // Photo picker
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedJPEG: Data?

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Title", text: $title)
                    TextField("Venue name", text: $venueName)
                    TextField("Address", text: $address)
                }

                Section("Date & Time") {
                    DatePicker("Event Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }

                Section("Cover Image") {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15))
                            if let data = pickedJPEG, let ui = UIImage(data: data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                            } else if let s = imagePreviewURL, let u = URL(string: s) {
                                AsyncImage(url: u) { img in img.resizable().scaledToFill() }
                                    placeholder: { Color.gray.opacity(0.12) }
                            } else {
                                Image(systemName: "photo").font(.title3).foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 90, height: 90)
                        .clipped()

                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Label("Choose Photo", systemImage: "photo.on.rectangle")
                        }
                        .onChange(of: pickedItem) { _ in
                            Task {
                                if let data = try? await pickedItem?.loadTransferable(type: Data.self) {
                                    if let img = UIImage(data: data),
                                       let jpeg = img.jpegData(compressionQuality: 0.9) {
                                        pickedJPEG = jpeg
                                    } else {
                                        pickedJPEG = data
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                }

                // NEW: Sales & Pricing
                Section("Sales & Pricing") {
                    NumberField(title: "Ticket price (e.g. 25.00)", value: $ticketPrice, keyboard: .decimalPad)
                    NumberField(title: "Ticket quantity", value: $ticketQuantity, keyboard: .numberPad)

                    NumberField(title: "Table price (e.g. 300.00)", value: $tablePrice, keyboard: .decimalPad)
                    NumberField(title: "Table quantity", value: $tableQuantity, keyboard: .numberPad)

                    NumberField(title: "Deposit percent (0–100)", value: $depositPercent, keyboard: .numberPad)
                }

                // NEW: Payout
                Section("Payout") {
                    Picker("Method", selection: $payoutMethod) {
                        Text("PayPal").tag("PayPal")
                    }
                    .pickerStyle(.segmented)

                    TextField("PayPal email", text: $payoutDetails)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled(true)
                }

                Section {
                    Toggle(isOn: $published) {
                        Label("Published", systemImage: published ? "checkmark.seal.fill" : "pause.fill")
                    }
                }

                if let e = errorText {
                    Section { Text(e).foregroundColor(.red) }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        if saving { ProgressView() } else { Text("Save Changes").bold() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Edit Event")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func save() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorText = "You must be signed in."
            return
        }
        saving = true; errorText = nil

        func write(with newPath: String?) {
            let ref = Database.database().reference().child("events").child(eventId)
            var payload: [String: Any] = [
                "title": title,
                "venueName": venueName,
                "address": address,
                "date": date.timeIntervalSince1970,
                "status": published ? "published" : "draft",
                "userId": uid
            ]
            if let newPath { payload["imagePath"] = newPath }

            // --- NEW: pricing + payout (only write if provided) ---
            if let tp = ticketPrice { payload["ticketPrice"] = tp }
            if let tq = ticketQuantity { payload["ticketQuantity"] = tq }
            if let ap = tablePrice { payload["tablePrice"] = ap }
            if let aq = tableQuantity { payload["tableQuantity"] = aq }
            if let dp = depositPercent { payload["depositPercent"] = max(0, min(100, dp)) }

            // Payout (PayPal-only per your spec)
            if !payoutMethod.trimmingCharacters(in: .whitespaces).isEmpty {
                payload["payoutMethod"] = payoutMethod
            }
            if !payoutDetails.trimmingCharacters(in: .whitespaces).isEmpty {
                payload["payoutDetails"] = payoutDetails
            }
            // ------------------------------------------------------

            ref.updateChildValues(payload) { err, _ in
                saving = false
                if let err = err { errorText = err.localizedDescription }
                else { dismiss() }
            }
        }

        if let jpeg = pickedJPEG {
            EventCoverUploader.uploadJPEG(jpeg, eventId: eventId) { result in
                switch result {
                case .failure(let e): saving = false; errorText = e.localizedDescription
                case .success(let path): write(with: path)
                }
            }
        } else {
            write(with: imagePath) // keep existing path if any
        }
    }
}

// MARK: - Edit sheet adapter (maps PromoterEvent -> EditEventSheet)
fileprivate struct EditSheetModel: Identifiable {
    let id: String
    let title: String
    let venueName: String
    let address: String
    let date: Date
    let published: Bool
    let imagePath: String?
    let imagePreviewURL: String? // resolved for preview (or legacy)

    // NEW: advanced fields
    let payoutMethod: String?
    let payoutDetails: String?
    let ticketPrice: Double?
    let ticketQuantity: Int?
    let tablePrice: Double?
    let tableQuantity: Int?
    let depositPercent: Int?

    init(from e: PromoterEvent) {
        self.id = e.id
        self.title = e.title
        self.venueName = e.venueName
        self.address = e.address
        self.date = Date(timeIntervalSince1970: e.date ?? Date().timeIntervalSince1970)
        self.published = (e.status ?? "draft") == "published"
        self.imagePath = e.imagePath
        // Prefer resolved URL, fallback to legacy direct URL if present
        self.imagePreviewURL = e.resolvedImageURL?.absoluteString ?? e.imageURL

        self.payoutMethod = e.payoutMethod
        self.payoutDetails = e.payoutDetails
        self.ticketPrice = e.ticketPrice
        self.ticketQuantity = e.ticketQuantity
        self.tablePrice = e.tablePrice
        self.tableQuantity = e.tableQuantity
        self.depositPercent = e.depositPercent
    }
}

// MARK: - Promoter Dashboard (Combined)
struct PromoterDashboardView: View {
    enum Window: String, CaseIterable { case today = "Today", week = "7d", month = "30d", all = "All" }

    // Filters / state
    @State private var window: Window = .week

    // Your original data
    @State private var nights: [NightModel] = []
    @State private var reservations: [ReservationModel] = []
    @State private var stats: PromoterStats = .empty
    @State private var selectedNightForShare: NightModel?

    // “My Events” (owned) + UI
    @State private var myEvents: [PromoterEvent] = []
    @State private var eventsSearch = ""
    @State private var isLoadingEvents = true
    @State private var eventsError: String?

    // Edit / share / duplicate
    @State private var editEvent: PromoterEvent?
    @State private var eventShareURL: URL?
    @State private var showEventShareSheet = false
    @State private var dupSource: PromoterEvent?
    @State private var showDuplicateAlert = false

    // Cache for flyer resolutions
    @State private var flyerURLCache: [String: URL] = [:]

    var body: some View {
        ZStack {
            VioletConsoleBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Promoter Console")
                                .font(.title2).bold()
                                .foregroundColor(.white)
                            Text("Track revenue, manage nights & reservations — and edit your events.")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                    }

                    // Window control
                    VioletGlassCard {
                        HStack {
                            ForEach(Window.allCases, id: \.self) { w in
                                Button(action: { window = w; reload() }) {
                                    Text(w.rawValue)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(window == w ? Color.purple.opacity(0.25) : Color.white.opacity(0.05))
                                        )
                                }
                                .foregroundColor(.white)
                            }
                            Spacer()
                        }
                    }

                    // KPI cards
                    HStack(spacing: 12) {
                        KPI(title: "GMV", value: "$\(Int(stats.gmv))")
                        KPI(title: "Paid", value: "\(stats.paidCount)")
                        KPI(title: "Held", value: "\(stats.heldCount)")
                        KPI(title: "Expired", value: "\(stats.expiredCount)")
                    }

                    // Nights you promote
                    VioletGlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("My Nights").font(.headline).foregroundColor(.white)
                                Spacer()
                                Menu {
                                    ForEach(nights, id: \.id) { n in
                                        Button("\(n.title) – \(shortDate(n.date))") {
                                            selectedNightForShare = n
                                        }
                                    }
                                } label: {
                                    Label("Share Link", systemImage: "square.and.arrow.up")
                                        .foregroundColor(.white)
                                }
                                .disabled(nights.isEmpty)
                            }

                            if nights.isEmpty {
                                Text("No attached nights yet. Ask a venue admin to add you.")
                                    .font(.footnote).foregroundColor(.white.opacity(0.7))
                            } else {
                                ForEach(nights.prefix(5), id: \.id) { n in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(n.title).font(.subheadline).bold().foregroundColor(.white)
                                            Text(shortDate(n.date))
                                                .font(.caption).foregroundColor(.white.opacity(0.7))
                                        }
                                        Spacer()
                                        Button("Share") {
                                            selectedNightForShare = n
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.purple)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                                }
                            }
                        }
                    }

                    // Reservations list
                    VioletGlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("My Reservations").font(.headline).foregroundColor(.white)
                            if reservations.isEmpty {
                                Text("No reservations yet for this window.")
                                    .font(.footnote).foregroundColor(.white.opacity(0.7))
                            } else {
                                ForEach(reservations, id: \.id) { r in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Reservation \(r.id.suffix(6))")
                                                .font(.subheadline).bold().foregroundColor(.white)
                                            Text("Table \(r.tableId) • Min $\(Int(r.minSpend))")
                                                .font(.caption).foregroundColor(.white.opacity(0.7))
                                        }
                                        Spacer()
                                        StatusPill(r.status)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                                }
                            }
                        }
                    }

                    // My Events (owned)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("My Events").font(.headline).foregroundColor(.white)
                        VioletGlassCard {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").foregroundColor(.purple.opacity(0.9))
                                TextField("Search by title, venue or city", text: $eventsSearch)
                                    .textInputAutocapitalization(.words)
                                    .disableAutocorrection(true)
                                    .foregroundColor(.white)
                            }
                        }

                        if isLoadingEvents {
                            ProgressView("Loading your events…").tint(.purple)
                        } else if let e = eventsError {
                            Text(e).foregroundColor(.red)
                        } else if filteredEvents.isEmpty {
                            Text("No events found. Create an event from the main Events tab; any event you own appears here.")
                                .font(.footnote).foregroundColor(.white.opacity(0.7))
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredEvents) { ev in
                                    VioletGlassCard {
                                        HStack(alignment: .top, spacing: 12) {
                                            // cover
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.15))
                                                if let u = ev.resolvedImageURL {
                                                    AsyncImage(url: u) { img in
                                                        img.resizable().scaledToFill()
                                                    } placeholder: {
                                                        Color.purple.opacity(0.08)
                                                    }
                                                } else if let s = ev.imageURL, let u = URL(string: s) {
                                                    // legacy direct URL fallback
                                                    AsyncImage(url: u) { img in
                                                        img.resizable().scaledToFill()
                                                    } placeholder: {
                                                        Color.purple.opacity(0.08)
                                                    }
                                                } else {
                                                    Image(systemName: "photo")
                                                        .font(.title2)
                                                        .foregroundColor(.purple.opacity(0.6))
                                                }
                                            }
                                            .frame(width: 72, height: 72)
                                            .clipped()
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))

                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack {
                                                    Text(ev.title)
                                                        .font(.headline).foregroundColor(.white)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    if let s = ev.status, !s.isEmpty {
                                                        Text(s.uppercased())
                                                            .font(.caption2).bold()
                                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                                            .background(Capsule().fill(Color.purple.opacity(0.18)))
                                                            .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
                                                            .foregroundColor(.white)
                                                    }
                                                }

                                                if let ts = ev.date {
                                                    Text(ts.asShortDateTime)
                                                        .font(.subheadline).foregroundColor(.white.opacity(0.85))
                                                }

                                                HStack(spacing: 6) {
                                                    if !ev.venueName.isEmpty {
                                                        Label(ev.venueName, systemImage: "building.2.fill")
                                                            .font(.caption).foregroundColor(.white.opacity(0.8))
                                                    }
                                                    if !ev.address.isEmpty {
                                                        Text("• \(ev.address)")
                                                            .font(.caption).foregroundColor(.white.opacity(0.65))
                                                            .lineLimit(1)
                                                    }
                                                }

                                                // NEW: quick glance at pricing
                                                HStack(spacing: 10) {
                                                    if let p = ev.ticketPrice {
                                                        Text(String(format: "Ticket: $%.0f", p))
                                                            .font(.caption).foregroundColor(.white.opacity(0.75))
                                                    }
                                                    if let t = ev.tablePrice {
                                                        Text(String(format: "Table: $%.0f", t))
                                                            .font(.caption).foregroundColor(.white.opacity(0.75))
                                                    }
                                                    if let d = ev.depositPercent {
                                                        Text("Deposit: \(d)%")
                                                            .font(.caption).foregroundColor(.white.opacity(0.6))
                                                    }
                                                }

                                                // Actions: Edit / Publish / Duplicate / Share
                                                HStack(spacing: 10) {
                                                    Button { editEvent = ev } label: { labelPill("Edit", "pencil") }

                                                    Button { togglePublish(ev) } label: {
                                                        let isPub = (ev.status ?? "draft") == "published"
                                                        labelPill(isPub ? "Unpublish" : "Publish", isPub ? "pause.fill" : "checkmark.seal.fill")
                                                    }

                                                    Button {
                                                        dupSource = ev
                                                        showDuplicateAlert = true
                                                    } label: { labelPill("Duplicate", "doc.on.doc.fill") }

                                                    Button {
                                                        if let deepLink = URL(string: "https://blackapp.app/e/\(ev.id)") {
                                                            eventShareURL = deepLink
                                                            showEventShareSheet = true
                                                        }
                                                    } label: { labelPill("Share", "square.and.arrow.up") }
                                                }
                                                .padding(.top, 2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(item: $selectedNightForShare) { night in
            PromoterShareSheet(night: night)
        }
        .sheet(isPresented: $showEventShareSheet) {
            if let link = eventShareURL {
                if #available(iOS 16.0, *) {
                    ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
                        .presentationDetents([.medium])
                        .padding()
                } else {
                    ShareSheetController(items: [link])
                }
            }
        }
        .sheet(item: Binding(
            get: { editEvent.map(EditSheetModel.init(from:)) },
            set: { _ in self.editEvent = nil }
        )) { model in
            EditEventSheet(
                eventId: model.id,
                title: model.title,
                venueName: model.venueName,
                address: model.address,
                date: model.date,
                imagePath: model.imagePath,                 // ✅ pass path
                imagePreviewURL: model.imagePreviewURL,     // ✅ preview URL
                published: model.published,

                // NEW: wire through advanced fields
                payoutMethod: model.payoutMethod ?? "PayPal",
                payoutDetails: model.payoutDetails ?? "",
                ticketPrice: model.ticketPrice,
                ticketQuantity: model.ticketQuantity,
                tablePrice: model.tablePrice,
                tableQuantity: model.tableQuantity,
                depositPercent: model.depositPercent
            )
        }
        .alert("Duplicate this event?", isPresented: $showDuplicateAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") { duplicate() }
        } message: {
            Text("We’ll create a draft copy. You can tweak the date, photo, and details.")
        }
        .preferredColorScheme(.dark)
        .onAppear {
            reload()
            fetchMyEvents()
        }
    }

    private func labelPill(_ title: String, _ system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.caption2)
            Text(title).font(.caption).bold()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
        .foregroundColor(.white.opacity(0.9))
    }

    // MARK: - Data (your original, plus events)
    private func reload() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        fetchPromoterNights(promoterId: uid) { ns in
            DispatchQueue.main.async { self.nights = ns }
        }

        let start: Date? = {
            let now = Date()
            switch window {
            case .today: return Calendar.current.startOfDay(for: now)
            case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
            case .all:   return nil
            }
        }()

        fetchPromoterReservations(promoterId: uid, windowStart: start) { rs in
            let s = computeStats(for: rs)
            DispatchQueue.main.async {
                self.reservations = rs.sorted { $0.amountPaid > $1.amountPaid }
                self.stats = s
            }
        }
    }

    private func fetchPromoterNights(promoterId: String, completion: @escaping ([NightModel]) -> Void) {
        let ref = Database.database().reference().child("nights")
        ref.observeSingleEvent(of: .value) { snap in
            var out: [NightModel] = []
            for case let child as DataSnapshot in snap.children {
                guard let n = NightModel.from(child) else { continue }
                if n.promoterIds[promoterId] == true { out.append(n) }
            }
            completion(out.sorted { $0.date < $1.date })
        }
    }

    private func fetchPromoterReservations(promoterId: String,
                                           windowStart: Date?,
                                           completion: @escaping ([ReservationModel]) -> Void) {
        let ref = Database.database().reference().child("reservations")
        ref.observeSingleEvent(of: .value) { snap in
            var out: [ReservationModel] = []
            for case let child as DataSnapshot in snap.children {
                guard let r = ReservationModel.from(child) else { continue }

                // Only those attributed to this promoter (field may be missing on older data)
                let promoterIdField = (child.value as? [String: Any])?["promoterId"] as? String
                guard promoterIdField == promoterId else { continue }

                // Optional window filter could be implemented if reservation stores time; skipped for now
                out.append(r)
            }
            completion(out)
        }
    }

    private func computeStats(for reservations: [ReservationModel]) -> PromoterStats {
        let paid = reservations.filter { $0.status == "paid" }
        let held = reservations.filter { $0.status == "held" }
        let expired = reservations.filter { $0.status == "expired" }
        let gmv = paid.map { $0.amountPaid }.reduce(0, +)
        return PromoterStats(gmv: gmv,
                             paidCount: paid.count,
                             heldCount: held.count,
                             expiredCount: expired.count)
    }

    // MARK: - My Events (owned)
    private var filteredEvents: [PromoterEvent] {
        let q = eventsSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = myEvents.sorted { ($0.date ?? 0) > ($1.date ?? 0) }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.venueName.localizedCaseInsensitiveContains(q) ||
            $0.address.localizedCaseInsensitiveContains(q)
        }
    }

    // Cache + resolver
    private func resolveFlyers(for events: [PromoterEvent], completion: @escaping ([PromoterEvent]) -> Void) {
        let group = DispatchGroup()
        var updated = events

        for i in updated.indices {
            if let path = updated[i].imagePath, !path.isEmpty {
                if let cached = flyerURLCache[path] {
                    updated[i].resolvedImageURL = cached
                    continue
                }
                group.enter()
                let ref = Storage.storage().reference(withPath: path)
                ref.downloadURL { url, _ in
                    if let url {
                        flyerURLCache[path] = url
                        updated[i].resolvedImageURL = url
                    }
                    group.leave()
                }
            } else if let legacy = updated[i].imageURL, let url = URL(string: legacy) {
                // Legacy direct URL fallback if present
                updated[i].resolvedImageURL = url
            }
        }

        group.notify(queue: .main) { completion(updated) }
    }

    private func fetchMyEvents() {
        guard let uid = Auth.auth().currentUser?.uid else {
            self.eventsError = "You must be signed in."
            self.isLoadingEvents = false
            return
        }
        isLoadingEvents = true
        eventsError = nil

        let ref = Database.database().reference().child("events")
        let group = DispatchGroup()
        var a: [PromoterEvent] = []  // userId=uid
        var b: [PromoterEvent] = []  // createdBy=uid

        // Query by userId
        group.enter()
        ref.queryOrdered(byChild: "userId").queryEqual(toValue: uid).observeSingleEvent(of: .value) { snap in
            var list: [PromoterEvent] = []
            for case let child as DataSnapshot in snap.children {
                if let e = PromoterEvent.from(child) { list.append(e) }
            }
            a = list; group.leave()
        }

        // Query by createdBy
        group.enter()
        ref.queryOrdered(byChild: "createdBy").queryEqual(toValue: uid).observeSingleEvent(of: .value) { snap in
            var list: [PromoterEvent] = []
            for case let child as DataSnapshot in snap.children {
                if let e = PromoterEvent.from(child) { list.append(e) }
            }
            b = list; group.leave()
        }

        group.notify(queue: .main) {
            var map: [String: PromoterEvent] = [:]
            (a + b).forEach { map[$0.id] = $0 }
            let merged = Array(map.values)

            self.resolveFlyers(for: merged) { resolved in
                self.myEvents = resolved
                self.isLoadingEvents = false
            }

            // Live listen (userId branch) to keep fresh
            ref.queryOrdered(byChild: "userId").queryEqual(toValue: uid).observe(.value) { snap in
                var live: [PromoterEvent] = []
                for case let child as DataSnapshot in snap.children {
                    if let e = PromoterEvent.from(child) { live.append(e) }
                }
                var mmap: [String: PromoterEvent] = [:]
                (live + b).forEach { mmap[$0.id] = $0 }
                let mergedLive = Array(mmap.values)
                self.resolveFlyers(for: mergedLive) { resolved in
                    self.myEvents = resolved
                }
            }
        }
    }

    private func togglePublish(_ ev: PromoterEvent) {
        let isPub = (ev.status ?? "draft") == "published"
        Database.database().reference()
            .child("events").child(ev.id)
            .updateChildValues(["status": isPub ? "draft" : "published"])
    }

    private func duplicate() {
        guard let src = dupSource, let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("events").childByAutoId()
        var copy: [String: Any] = [
            "title": (src.title.isEmpty ? "Untitled" : src.title) + " (Copy)",
            "venueName": src.venueName,
            "address": src.address,
            "date": (src.date ?? Date().timeIntervalSince1970),
            "status": "draft",
            "userId": uid
        ]
        // ✅ copy storage path if present (preferred)
        if let path = src.imagePath { copy["imagePath"] = path }
        // (Optional) else ignore legacy URL; keeping it would work but we want to normalize to imagePath moving forward.
        ref.setValue(copy)
    }
}
