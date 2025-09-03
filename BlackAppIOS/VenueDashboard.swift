import SwiftUI
import FirebaseAuth
import FirebaseDatabase

// MARK: - Local Aesthetic (violet glass)

fileprivate struct VDGlassBackground: View {
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
                center: .center, startRadius: 100, endRadius: 900
            )
            .ignoresSafeArea()

            AngularGradient(
                gradient: Gradient(colors: [
                    Color.purple.opacity(0.0),
                    Color.purple.opacity(animate ? 0.25 : 0.05),
                    Color.pink.opacity(animate ? 0.15 : 0.03),
                    Color.purple.opacity(0.0)
                ]),
                center: .center
            )
            .blendMode(.screen)
            .blur(radius: animate ? 60 : 120)
            .opacity(0.8)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    animate.toggle()
                }
            }
        }
    }
}

fileprivate struct VDGlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .background(
                ZStack {
                    Color.white.opacity(0.03)
                    LinearGradient(
                        colors: [Color.purple.opacity(0.08), Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            )
            .background(.ultraThinMaterial.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.35), Color.pink.opacity(0.25), Color.clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.purple.opacity(0.15), radius: 20, x: 0, y: 8)
    }
}

fileprivate struct VDStatusPill: View {
    let text: String
    var color: Color {
        switch text.lowercased() {
        case "paid": return .green
        case "held": return .orange
        case "expired", "cancelled": return .red
        case "available", "published": return .teal
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

fileprivate struct VDKPI: View {
    let title: String
    let value: String
    var body: some View {
        VDGlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(.white.opacity(0.7))
                Text(value).font(.headline).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Edit Model & Sheet

struct NightEditModel: Identifiable, Equatable {
    var id: String?                // nil => new night
    var venueId: String
    var title: String
    var date: Date
    var description: String
    var status: String             // "draft" | "published"
    var imagePath: String?

    static func createNew(venueId: String, venueName: String) -> NightEditModel {
        .init(
            id: nil,
            venueId: venueId,
            title: "\(venueName) Night",
            date: Date().addingTimeInterval(86400),
            description: "",
            status: "published",
            imagePath: nil
        )
    }
}

fileprivate struct EditNightSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Accept value; store as local @State
    private let onSaved: (NightModel) -> Void
    @State private var model: NightEditModel
    @State private var saving = false
    @State private var errorText: String?

    init(model: NightEditModel, onSaved: @escaping (NightModel) -> Void) {
        self._model = State(initialValue: model)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Title", text: $model.title)
                    DatePicker("Date",
                               selection: $model.date,
                               displayedComponents: [.date, .hourAndMinute])
                    Picker("Status", selection: $model.status) {
                        Text("Published").tag("published")
                        Text("Draft").tag("draft")
                    }
                    TextField("Image URL (optional)",
                              text: Binding(
                                  get: { model.imagePath ?? "" },
                                  set: { model.imagePath = $0.isEmpty ? nil : $0 }
                              )
                    )
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                }

                Section("Description") {
                    TextEditor(text: $model.description).frame(minHeight: 120)
                }

                if let e = errorText {
                    Section { Text(e).foregroundColor(.red) }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(saving || model.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(model.id == nil ? "Create Night" : "Edit Night")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func save() {
        guard !model.venueId.isEmpty else { errorText = "Missing venue ID."; return }
        saving = true; errorText = nil

        let ref = Database.database().reference().child("nights")
        let payload: [String: Any?] = [
            "venueId": model.venueId,
            "date": model.date.timeIntervalSince1970,
            "title": model.title,
            "description": model.description,
            "status": model.status,
            "imagePath": model.imagePath,
            "promoterIds": nil
        ]
        let clean = payload.reduce(into: [String: Any]()) { if let v = $1.value { $0[$1.key] = v } }

        if let id = model.id {
            ref.child(id).updateChildValues(clean) { err, _ in
                saving = false
                if let err = err { errorText = err.localizedDescription; return }
                let night = NightModel(
                    id: id,
                    venueId: model.venueId,
                    date: model.date,
                    title: model.title,
                    description: model.description,
                    imagePath: model.imagePath,
                    promoterIds: [:],
                    status: model.status
                )
                onSaved(night); dismiss()
            }
        } else {
            let child = ref.childByAutoId()
            child.setValue(clean) { err, _ in
                saving = false
                if let err = err { errorText = err.localizedDescription; return }
                let night = NightModel(
                    id: child.key ?? UUID().uuidString,
                    venueId: model.venueId,
                    date: model.date,
                    title: model.title,
                    description: model.description,
                    imagePath: model.imagePath,
                    promoterIds: [:],
                    status: model.status
                )
                onSaved(night); dismiss()
            }
        }
    }
}

// MARK: - Dashboard

struct VenueDashboardView: View {
    // If you know the venue to open, pass it. Otherwise user can pick.
    var initialVenueId: String?

    // UI
    enum Tab: String, CaseIterable { case overview = "Overview", nights = "Nights", reservations = "Tables", tickets = "Tickets", lineup = "Lineup" }
    @State private var tab: Tab = .overview

    // Venue list + selection
    @State private var venues: [VenueModel] = []
    @State private var selectedVenueId: String? = nil
    @State private var selectedVenue: VenueModel? = nil
    @State private var venueError: String? = nil

    // Nights
    @State private var nights: [NightModel] = []
    @State private var editingModel: NightEditModel? = nil

    // KPIs
    @State private var kpiTotalNights: Int = 0
    @State private var kpiReservationsPaid: Int = 0
    @State private var kpiReservationsHeld: Int = 0
    @State private var kpiGMV: Double = 0

    // Per-night working state
    @State private var selectedNightId: String? = nil
    @State private var inventory: [InventoryItem] = []
    @State private var tickets: [TicketSKU] = []
    @State private var lineup: [LineupSlot] = []

    var body: some View {
        ZStack {
            VDGlassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if let err = venueError {
                        VDGlassCard { Text(err).foregroundColor(.red) }
                    }

                    // KPIs
                    if selectedVenue != nil {
                        HStack(spacing: 12) {
                            VDKPI(title: "Nights", value: "\(kpiTotalNights)")
                            VDKPI(title: "Paid", value: "\(kpiReservationsPaid)")
                            VDKPI(title: "Held", value: "\(kpiReservationsHeld)")
                            VDKPI(title: "GMV", value: "$\(Int(kpiGMV))")
                        }
                    }

                    // Tab control
                    if selectedVenue != nil {
                        VDGlassCard {
                            HStack(spacing: 8) {
                                ForEach(Tab.allCases, id: \.self) { t in
                                    Button {
                                        tab = t
                                    } label: {
                                        Text(t.rawValue)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(tab == t ? Color.purple.opacity(0.25) : Color.white.opacity(0.05))
                                            )
                                    }
                                    .foregroundColor(.white)
                                }
                                Spacer()
                            }
                        }
                    }

                    // Content
                    Group {
                        switch tab {
                        case .overview: overviewSection
                        case .nights: nightsSection
                        case .reservations: reservationsSection
                        case .tickets: ticketsSection
                        case .lineup: lineupSection
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear(perform: initialLoad)
        .sheet(item: $editingModel) { model in
            EditNightSheet(model: model) { saved in
                // Refresh nights + KPIs
                loadNights()
                recalcKPIs()
                if selectedNightId == nil { selectedNightId = saved.id }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Venue Console").font(.title2).bold().foregroundColor(.white)
                Spacer()
                if let v = selectedVenue {
                    // Share Venue (Gossip-first)
                    Button {
                        shareVenue(v)
                    } label: {
                        Label("Share Venue", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)

                    Button {
                        editingModel = NightEditModel.createNew(venueId: v.id, venueName: v.name)
                    } label: {
                        Label("Create Night", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }

            // Venue picker
            VDGlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "building.2.fill").foregroundColor(.purple.opacity(0.9))
                    if venues.isEmpty && venueError == nil {
                        Text("Loading venues…").foregroundColor(.white.opacity(0.7))
                    } else if venues.isEmpty {
                        Text("No venues found for this account.").foregroundColor(.white.opacity(0.7))
                    } else {
                        Picker("Venue", selection: Binding(
                            get: { selectedVenueId ?? "" },
                            set: { newVal in
                                selectedVenueId = newVal.isEmpty ? nil : newVal
                                selectedVenue = venues.first(where: { $0.id == selectedVenueId })
                                venueError = nil
                                loadNights()
                                recalcKPIs()
                            })
                        ) {
                            ForEach(venues, id: \.id) { v in
                                Text(v.name).tag(v.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .foregroundColor(.white)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Overview

    private var overviewSection: some View {
        Group {
            if let v = selectedVenue {
                VStack(alignment: .leading, spacing: 12) {
                    Text(v.name).foregroundColor(.white).font(.headline)
                    if !v.address.isEmpty {
                        Text(v.address).foregroundColor(.white.opacity(0.7)).font(.subheadline)
                    }

                    if nights.isEmpty {
                        VDGlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No nights yet").foregroundColor(.white).bold()
                                Text("Tap “Create Night” to add your first event night.")
                                    .foregroundColor(.white.opacity(0.7)).font(.footnote)
                            }
                        }
                    } else {
                        VDGlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Upcoming Nights").foregroundColor(.white).font(.headline)
                                ForEach(nights.prefix(5), id: \.id) { n in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(n.title).foregroundColor(.white).font(.subheadline).bold()
                                            Text(DateFormatter.shortDate.string(from: n.date)).foregroundColor(.white.opacity(0.7)).font(.caption)
                                        }
                                        Spacer()
                                        VDStatusPill(text: n.status)

                                        // Share Night (Gossip-first)
                                        Button {
                                            shareNight(n, venueName: v.name)
                                        } label: {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.purple)

                                        Button {
                                            editingModel = NightEditModel(
                                                id: n.id,
                                                venueId: n.venueId,
                                                title: n.title,
                                                date: n.date,
                                                description: n.description,
                                                status: n.status,
                                                imagePath: n.imagePath
                                            )
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.purple)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                                }
                            }
                        }
                    }
                }
            } else {
                VDGlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pick a venue").foregroundColor(.white).bold()
                        Text("Select which venue to manage from the picker above.")
                            .foregroundColor(.white.opacity(0.7)).font(.footnote)
                    }
                }
            }
        }
    }

    // MARK: Nights

    private var nightsSection: some View {
        Group {
            if selectedVenue == nil {
                emptyHint("Select a venue to view its nights.")
            } else if nights.isEmpty {
                emptyHint("No nights created for this venue yet.")
            } else {
                VStack(spacing: 12) {
                    ForEach(nights, id: \.id) { n in
                        VDGlassCard {
                            HStack(alignment: .center, spacing: 12) {
                                // image
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.14))
                                    if let path = n.imagePath, let url = URL(string: path) {
                                        AsyncImage(url: url) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: { Color.purple.opacity(0.08) }
                                    } else {
                                        Image(systemName: "photo")
                                            .foregroundColor(.purple.opacity(0.6))
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(n.title).foregroundColor(.white).font(.headline)
                                        Spacer()
                                        VDStatusPill(text: n.status)
                                    }
                                    Text(DateFormatter.shortDate.string(from: n.date))
                                        .foregroundColor(.white.opacity(0.8))
                                        .font(.subheadline)

                                    HStack(spacing: 10) {
                                        Button {
                                            selectedNightId = n.id
                                            tab = .reservations
                                            loadInventory()
                                        } label: { pill("Tables", "square.grid.3x2.fill") }

                                        Button {
                                            selectedNightId = n.id
                                            tab = .tickets
                                            loadTickets()
                                        } label: { pill("Tickets", "ticket.fill") }

                                        Button {
                                            selectedNightId = n.id
                                            tab = .lineup
                                            loadLineup()
                                        } label: { pill("Lineup", "music.note.list") }

                                        Button {
                                            editingModel = NightEditModel(
                                                id: n.id,
                                                venueId: n.venueId,
                                                title: n.title,
                                                date: n.date,
                                                description: n.description,
                                                status: n.status,
                                                imagePath: n.imagePath
                                            )
                                        } label: { pill("Edit", "pencil") }

                                        // Share (Gossip-first)
                                        Button {
                                            shareNight(n, venueName: selectedVenue?.name)
                                        } label: { pill("Share", "square.and.arrow.up") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Reservations / Tables

    private var reservationsSection: some View {
        Group {
            if selectedVenue == nil { emptyHint("Select a venue to manage tables.") }
            else if selectedNightId == nil {
                if let firstUpcoming = nights.first(where: { $0.date >= Date() })?.id ?? nights.first?.id {
                    VStack(spacing: 8) {
                        Text("Tip").foregroundColor(.white).bold()
                        Text("Pick a night from the list above or Nights tab. Showing first night by default.")
                            .foregroundColor(.white.opacity(0.7)).font(.footnote)
                        Button("Select First Night") {
                            selectedNightId = firstUpcoming
                            loadInventory()
                        }.buttonStyle(.borderedProminent).tint(.purple)
                    }
                    .padding(.top, 4)
                } else {
                    emptyHint("No nights available. Create one first.")
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    pickerForNightSelection()

                    if inventory.isEmpty {
                        VDGlassCard {
                            Text("No inventory set for this night.")
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else {
                        ForEach(inventory, id: \.id) { item in
                            VDGlassCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Table \(item.tableId)").foregroundColor(.white).bold()
                                        HStack(spacing: 10) {
                                            Text("Min Spend: $\(Int(item.minSpend))").foregroundColor(.white.opacity(0.85))
                                            if let slot = item.timeSlot { Text(slot).foregroundColor(.white.opacity(0.7)) }
                                        }
                                        .font(.footnote)
                                        VDStatusPill(text: item.status)
                                    }
                                    Spacer()
                                    if item.status == "available" {
                                        Button("Hold & Checkout") { holdAndCheckout(item) }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.purple)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Tickets

    private var ticketsSection: some View {
        Group {
            if selectedVenue == nil { emptyHint("Select a venue to view tickets.") }
            else if selectedNightId == nil {
                emptyHint("Pick a night to view ticket SKUs.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    pickerForNightSelection()

                    if tickets.isEmpty {
                        VDGlassCard {
                            Text("No ticket SKUs defined for this night.")
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else {
                        ForEach(tickets, id: \.id) { sku in
                            VDGlassCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sku.name).foregroundColor(.white).bold()
                                        HStack(spacing: 10) {
                                            Text(String(format: "$%.0f", sku.price)).foregroundColor(.white.opacity(0.85))
                                            if let q = sku.qtyAvailable { Text("Qty: \(q)").foregroundColor(.white.opacity(0.7)) }
                                            if let s = sku.source { Text(s.capitalized).foregroundColor(.white.opacity(0.6)) }
                                        }
                                        .font(.footnote)
                                    }
                                    Spacer()
                                    if let u = sku.externalURL, let url = URL(string: u) {
                                        // You could also offer a Gossip share for ticket links here if desired:
                                        // GossipShareManager.shared.presentShare(from: presenter, payload: .link(url: url, text: "Tickets: \(sku.name)"))
                                        Link("Sell", destination: url)
                                            .buttonStyle(.borderedProminent)
                                            .tint(.purple)
                                    } else {
                                        Text("Internal sale TBD").foregroundColor(.white.opacity(0.6)).font(.footnote)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Lineup

    @State private var addEntertainerUid: String = ""
    @State private var addRole: String = "Performer"
    @State private var addCompText: String = ""

    private var lineupSection: some View {
        Group {
            if selectedVenue == nil { emptyHint("Select a venue to manage lineup.") }
            else if selectedNightId == nil { emptyHint("Pick a night to manage lineup.") }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    pickerForNightSelection()

                    if lineup.isEmpty {
                        VDGlassCard {
                            Text("No entertainers yet. Add one below.")
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else {
                        ForEach(lineup, id: \.id) { slot in
                            VDGlassCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(slot.entertainerId).foregroundColor(.white).bold() // Replace with stageName lookup if desired
                                        HStack(spacing: 10) {
                                            Text(slot.role ?? "Performer").foregroundColor(.white.opacity(0.85))
                                            Text(slot.status.capitalized).foregroundColor(.white.opacity(0.7))
                                            if let c = slot.compensation {
                                                Text(String(format: "$%.0f", c)).foregroundColor(.white.opacity(0.7))
                                            }
                                        }.font(.footnote)
                                    }
                                    Spacer()
                                    VDStatusPill(text: slot.status)
                                }
                            }
                        }
                    }

                    VDGlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add to Lineup").foregroundColor(.white).bold()
                            TextField("Entertainer UID", text: $addEntertainerUid).autocapitalization(.none)
                                .textFieldStyle(.roundedBorder).tint(.purple)
                            TextField("Role (e.g. Headliner, DJ)", text: $addRole).textFieldStyle(.roundedBorder)
                            TextField("Compensation (optional)", text: $addCompText)
                                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            Button("Add") { addLineupSlot() }
                                .buttonStyle(.borderedProminent).tint(.purple)
                                .disabled(addEntertainerUid.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    // MARK: Small helpers

    private func pill(_ title: String, _ system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.caption2)
            Text(title).font(.caption).bold()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
        .foregroundColor(.white.opacity(0.9))
    }

    private func emptyHint(_ message: String) -> some View {
        VDGlassCard {
            Text(message).foregroundColor(.white.opacity(0.8))
        }
    }

    private func pickerForNightSelection() -> some View {
        VDGlassCard {
            HStack(spacing: 12) {
                Image(systemName: "calendar").foregroundColor(.purple.opacity(0.9))
                Picker("Night", selection: Binding(
                    get: { selectedNightId ?? "" },
                    set: { newVal in
                        selectedNightId = newVal.isEmpty ? nil : newVal
                        loadInventory()
                        loadTickets()
                        loadLineup()
                    })
                ) {
                    ForEach(nights, id: \.id) { n in
                        Text("\(DateFormatter.shortDate.string(from: n.date)) – \(n.title)").tag(n.id)
                    }
                }
                .pickerStyle(.menu)
                .foregroundColor(.white)
                Spacer()
            }
        }
    }

    // MARK: Data loading

    private func initialLoad() {
        // First, try your service (works if /venues documents already include "name")
        NightlifeService.shared.fetchVenues { list in
            DispatchQueue.main.async {
                let sorted = list.sorted { $0.name < $1.name }
                self.venues = sorted

                if let vid = initialVenueId, let v = sorted.first(where: { $0.id == vid }) {
                    self.selectedVenueId = v.id
                    self.selectedVenue = v
                    self.venueError = nil
                    self.loadNights()
                    self.recalcKPIs()
                } else if let v = sorted.first {
                    self.selectedVenueId = v.id
                    self.selectedVenue = v
                    self.venueError = nil
                    self.loadNights()
                    self.recalcKPIs()
                } else {
                    // Fallback if fetchVenues can't build VenueModel (e.g., only "businessName" exists)
                    fallbackResolveVenueFromUID()
                }
            }
        }
    }

    /// Fallback: resolve venue using /venues/{uid}, accept "businessName" as name
    private func fallbackResolveVenueFromUID() {
        guard let uid = Auth.auth().currentUser?.uid else {
            self.venueError = "You must be signed in."
            return
        }
        let ref = Database.database().reference().child("venues").child(uid)
        ref.observeSingleEvent(of: .value) { snap in
            guard let raw = snap.value as? [String: Any] else {
                self.venueError = "No venue record found for this account."
                return
            }
            // Approval gate
            let approved = (raw["approved"] as? Bool) ?? false
            guard approved else {
                self.venueError = "This venue is not approved yet."
                return
            }
            // Build a VenueModel even if "name" is missing
            let name = (raw["name"] as? String) ?? (raw["businessName"] as? String) ?? "My Venue"
            let address = (raw["address"] as? String) ?? ""
            let photos = (raw["photos"] as? [String]) ?? []
            let genres = (raw["genres"] as? [String]) ?? []
            let dress = raw["dressCode"] as? String
            let hours = raw["hours"] as? [String: [String: String]]

            let minimal = VenueModel(
                id: snap.key,
                name: name,
                address: address,
                geo: nil,
                photos: photos,
                genres: genres,
                dressCode: dress,
                hours: hours
            )
            self.venues = [minimal]
            self.selectedVenueId = minimal.id
            self.selectedVenue = minimal
            self.venueError = nil
            self.loadNights()
            self.recalcKPIs()
        }
    }

    private func loadNights() {
        guard let vid = selectedVenueId else {
            nights = []; selectedNightId = nil; inventory = []; tickets = []; lineup = []; return
        }
        NightlifeService.shared.fetchNights(for: vid) { list in
            DispatchQueue.main.async {
                self.nights = list.sorted { $0.date < $1.date }
                // If no selected night, pick upcoming or first
                if self.selectedNightId == nil {
                    self.selectedNightId = self.nights.first(where: { $0.date >= Date() })?.id ?? self.nights.first?.id
                }
            }
        }
    }

    private func recalcKPIs() {
        guard selectedVenueId != nil else {
            kpiTotalNights = 0; kpiReservationsPaid = 0; kpiReservationsHeld = 0; kpiGMV = 0; return
        }
        // Nights already loaded
        let venueNightIds = Set(nights.map { $0.id })
        kpiTotalNights = nights.count

        // Pull all reservations and filter to this venue's nights (MVP)
        Database.database().reference().child("reservations").observeSingleEvent(of: .value) { snap in
            var paidCount = 0
            var heldCount = 0
            var gmv: Double = 0
            for case let child as DataSnapshot in snap.children {
                guard let r = ReservationModel.from(child) else { continue }
                guard venueNightIds.contains(r.nightId) else { continue }
                switch r.status {
                case "paid": paidCount += 1; gmv += r.amountPaid
                case "held": heldCount += 1
                default: break
                }
            }
            DispatchQueue.main.async {
                self.kpiReservationsPaid = paidCount
                self.kpiReservationsHeld = heldCount
                self.kpiGMV = gmv
            }
        }
    }

    private func loadInventory() {
        guard let nid = selectedNightId else { inventory = []; return }
        NightlifeService.shared.fetchInventory(nightId: nid) { list in
            DispatchQueue.main.async {
                self.inventory = list.sorted { $0.minSpend < $1.minSpend }
            }
        }
    }

    private func loadTickets() {
        guard let nid = selectedNightId else { tickets = []; return }
        NightlifeService.shared.fetchTicketInventory(nightId: nid) { list in
            DispatchQueue.main.async {
                self.tickets = list.sorted { $0.price < $1.price }
            }
        }
    }

    private func loadLineup() {
        guard let nid = selectedNightId else { lineup = []; return }
        NightlifeService.shared.fetchLineup(nightId: nid) { list in
            DispatchQueue.main.async { self.lineup = list }
        }
    }

    // MARK: Actions

    private func holdAndCheckout(_ item: InventoryItem) {
        guard let nid = selectedNightId else { return }
        let depositPercent = item.depositPercent ?? 0
        NightlifeService.shared.createReservationHold(
            nightId: nid,
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
                    nightId: nid,
                    tableId: item.tableId,
                    reservationId: payload.reservationId,
                    isDeposit: isDeposit,
                    baseAmount: base
                ) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func addLineupSlot() {
        guard let nid = selectedNightId else { return }
        let comp = Double(addCompText)
        NightlifeService.shared.upsertLineupSlot(
            nightId: nid,
            entertainerUid: addEntertainerUid,
            role: addRole.isEmpty ? nil : addRole,
            startAt: nil, endAt: nil,
            compensation: comp,
            status: "invited"
        ) { result in
            switch result {
            case .failure(let e):
                print("Lineup add failed:", e.localizedDescription)
            case .success:
                addEntertainerUid = ""; addRole = "Performer"; addCompText = ""
                loadLineup()
            }
        }
    }

    // MARK: Gossip-first share helpers

    private func shareVenue(_ venue: VenueModel) {
        guard let presenter = UIApplication.shared.keyWindowTopMostController,
              let url = URL(string: buildVenueDeepLink(venueId: venue.id)) else { return }
        let caption = "Come through to \(venue.name) — tap for nights & tables."
        GossipShareManager.shared.presentShare(
            from: presenter,
            payload: .link(url: url, text: caption)
        )
    }

    private func shareNight(_ night: NightModel, venueName: String?) {
        guard let presenter = UIApplication.shared.keyWindowTopMostController,
              let url = buildNightShareURL(night) else { return }
        let caption = makeNightShareCaption(night: night, venueName: venueName)
        GossipShareManager.shared.presentShare(
            from: presenter,
            payload: .link(url: url, text: caption)
        )
    }

    // Deep links / captions

    private func buildVenueDeepLink(venueId: String) -> String {
        // Consistent with promoter share route
        return "https://blackapp.app/nightlife/venue/\(venueId)"
    }

    private func buildNightShareURL(_ night: NightModel) -> URL? {
        var comps = URLComponents(string: "https://blackapp.app/nightlife/venue/\(night.venueId)")
        comps?.queryItems = [URLQueryItem(name: "nightId", value: night.id)]
        return comps?.url
    }

    private func makeNightShareCaption(night: NightModel, venueName: String?) -> String {
        let when = DateFormatter.shortDate.string(from: night.date)
        let whereStr = venueName ?? "the venue"
        return "\(night.title) @ \(whereStr) • \(when)"
    }
}
