import SwiftUI
import UIKit
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase

// MARK: - EventFeedView (Internal events only)
struct EventFeedView: View {
    @State private var platformEvents: [EventModel] = []
    @State private var isLoading = true

    // Filters
    @State private var showOnlyUpcoming = true
    @State private var filterToday = false
    @State private var filterWeekend = false
    @State private var locationQuery = ""
    @State private var ticketMinPrice: Double? = nil
    @State private var ticketMaxPrice: Double? = nil
    @State private var tableMinPrice: Double? = nil
    @State private var tableMaxPrice: Double? = nil
    @State private var showFilters = false

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Events...")
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: { withAnimation { showFilters.toggle() } }) {
                            HStack {
                                Text(showFilters ? "Hide Filters ▲" : "Show Filters ▼")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }

                        if showFilters {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Show Upcoming Only", isOn: $showOnlyUpcoming)

                                HStack {
                                    Toggle("Today", isOn: $filterToday)
                                    Toggle("This Weekend", isOn: $filterWeekend)
                                }

                                TextField("Search by location", text: $locationQuery)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("🎟 Ticket Price Range")
                                        .font(.caption)
                                        .foregroundColor(.gray)

                                    HStack {
                                        TextField("Min", value: $ticketMinPrice, format: .number)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                        TextField("Max", value: $ticketMaxPrice, format: .number)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                    }

                                    Text("🍾 Table Price Range")
                                        .font(.caption)
                                        .foregroundColor(.gray)

                                    HStack {
                                        TextField("Min", value: $tableMinPrice, format: .number)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                        TextField("Max", value: $tableMaxPrice, format: .number)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                    }
                                }
                            }
                            .transition(.opacity.combined(with: .slide))
                        }
                    }
                    .padding(.horizontal)

                    List {
                        // --- Platform events (your own) ---
                        Section(header: Text("BlackApp Events")) {
                            if platformEvents.isEmpty {
                                Text("No upcoming events.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(filteredEvents(), id: \.id) { event in
                                    EventCardView(event: event)
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Events")
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .onAppear {
                isLoading = true
                fetchPlatformEvents()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - DATA (Platform only)
extension EventFeedView {
    func fetchPlatformEvents() {
        let ref = Database.database().reference().child("events")
        ref.observeSingleEvent(of: .value) { snapshot in
            var events: [EventModel] = []
            let now = Date()
            for case let child as DataSnapshot in snapshot.children {
                if let event = EventModel.from(snapshot: child), event.date > now {
                    events.append(event)
                }
            }
            platformEvents = events.sorted { $0.date > $1.date }
            isLoading = false
        }
    }
}

// MARK: - FILTERING (applies to internal events)
extension EventFeedView {
    func filteredEvents() -> [EventModel] {
        var out = platformEvents

        if showOnlyUpcoming {
            out = out.filter { $0.date >= Date() }
        }
        if filterToday {
            let cal = Calendar.current
            out = out.filter { cal.isDateInToday($0.date) }
        }
        if filterWeekend {
            let cal = Calendar.current
            out = out.filter { cal.isDateInWeekend($0.date) }
        }

        if !locationQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = locationQuery.lowercased()
            out = out.filter { $0.location.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        }

        if let min = ticketMinPrice { out = out.filter { $0.ticketPrice >= min } }
        if let max = ticketMaxPrice { out = out.filter { $0.ticketPrice <= max } }
        if let tmin = tableMinPrice { out = out.filter { $0.tablePrice >= tmin } }
        if let tmax = tableMaxPrice { out = out.filter { $0.tablePrice <= tmax } }

        return out.sorted { $0.date < $1.date }
    }
}

// =======================
// MARK: - Event Card View
// =======================

struct EventCardView: View {
    let event: EventModel

    @State private var showCheckout = false
    @State private var isSaved = false
    @State private var showShareOptions = false   // stays, but dialog moved to container

    // Compact formatters
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private var dateText: String { Self.dateFormatter.string(from: event.date) }
    private var timeText: String { Self.timeFormatter.string(from: event.date) }
    var ticketsRemaining: Int { max(event.ticketQuantity - (event.ticketsSold), 0) }
    var tablesRemaining: Int { max(event.tableQuantity - (event.tablesSold), 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Flyer with date/time overlay
            ZStack(alignment: .bottomLeading) {
                EventImageView(imagePath: event.imagePath)
                    .frame(height: 200)
                    .clipped()

                LinearGradient(colors: [Color.clear, Color.black.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
                    .frame(maxWidth: .infinity, alignment: .bottom)

                HStack(spacing: 12) {
                    Label(dateText, systemImage: "calendar")
                    Label(timeText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(event.title)
                .font(.headline)
                .padding(.top, 4)

            HStack(spacing: 12) {
                Label(dateText, systemImage: "calendar")
                Label(timeText, systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.9))

            Text(event.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse").foregroundColor(.gray)
                Text(event.location).font(.subheadline).foregroundColor(.gray)
            }

            // Prices
            HStack(spacing: 16) {
                if event.ticketPrice > 0 {
                    Label("$\(String(format: "%.2f", event.ticketPrice)) Tickets", systemImage: "ticket")
                        .font(.caption)
                }
                if event.tablePrice > 0 {
                    Label("$\(String(format: "%.2f", event.tablePrice)) Tables", systemImage: "person.3.fill")
                        .font(.caption)
                }
            }
            .foregroundColor(.white)

            // Remaining counts
            HStack(spacing: 16) {
                if event.ticketQuantity > 0 {
                    Label("\(ticketsRemaining) tickets left", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(ticketsRemaining <= 5 ? .red : (ticketsRemaining <= 10 ? .yellow : .white))
                }
                if event.tableQuantity > 0 {
                    Label("\(tablesRemaining) tables left", systemImage: "person.3.sequence.fill")
                        .font(.caption)
                        .foregroundColor(tablesRemaining <= 2 ? .red : (tablesRemaining <= 5 ? .yellow : .white))
                }
            }

            // Save & Share (buttons are now 'borderless' so taps don't bubble to row)
            HStack {
                Button(action: {
                    isSaved.toggle()
                    saveEventToFirebase(event: event, isSaved: isSaved)
                }) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .foregroundColor(isSaved ? .yellow : .white)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: { showShareOptions = true }) {
                    Image(systemName: "square.and.arrow.up").foregroundColor(.white)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.top, 4)

            // Checkout (also borderless so the row never hijacks it)
            Button(action: { showCheckout = true }) {
                Text("Buy Tickets / Tables")
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .contentShape(Rectangle())                 // keep taps well-scoped
        .onAppear(perform: checkIfSaved)
        .sheet(isPresented: $showCheckout) {
            CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                openCheckout(ticketQty: ticketQty, tableQty: tableQty)
            }
        }
        // ⬇️ Moved here: ONLY shows when showShareOptions is set by the Share button
        .confirmationDialog("Share Event",
                            isPresented: $showShareOptions,
                            titleVisibility: .visible) {
            Button("Share to Gossip (recommended)") { shareToGossip() }
            Button("Share via…") { shareToSystem() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: Save / load
    private func checkIfSaved() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }

    private func saveEventToFirebase(event: EventModel, isSaved: Bool) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)
        if isSaved {
            ref.setValue(["eventId": event.id, "timestamp": Date().timeIntervalSince1970])
        } else {
            ref.removeValue()
        }
    }

    // MARK: Checkout deep link (existing)
    private func openCheckout(ticketQty: Int, tableQty: Int) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❌ No user logged in"); return
        }
        let payoutMethod = event.payoutMethod.isEmpty ? "N/A" : event.payoutMethod
        let payoutDetails = event.payoutDetails.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "N/A"
        let ticketTotal = Double(ticketQty) * event.ticketPrice
        let tableTotal = Double(tableQty) * event.tablePrice
        let grossTotal = ticketTotal + tableTotal
        let totalWithFee = grossTotal * 1.02

        var components = URLComponents()
        components.scheme = "https"
        components.host = "blackappios.web.app"
        components.path = "/checkout"
        components.queryItems = [
            URLQueryItem(name: "eventId", value: event.id),
            URLQueryItem(name: "eventName", value: event.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
            URLQueryItem(name: "eventTime", value: "\(Int(event.date.timeIntervalSince1970))"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "ticketQty", value: "\(ticketQty)"),
            URLQueryItem(name: "ticketPrice", value: "\(event.ticketPrice)"),
            URLQueryItem(name: "tableQty", value: "\(tableQty)"),
            URLQueryItem(name: "tablePrice", value: "\(event.tablePrice)"),
            URLQueryItem(name: "baseTotal", value: String(format: "%.2f", grossTotal)),
            URLQueryItem(name: "totalWithFee", value: String(format: "%.2f", totalWithFee)),
            URLQueryItem(name: "payoutMethod", value: payoutMethod),
            URLQueryItem(name: "payoutDetails", value: payoutDetails),
            URLQueryItem(name: "eventImagePath", value: event.imagePath)
        ]
        if let url = components.url {
            print("🔗 Checkout URL:", url.absoluteString)
            UIApplication.shared.open(url)
        } else {
            print("❌ Failed to create checkout URL")
        }
    }

    // MARK: Share helpers (unchanged)
    private func shareToGossip() {
        guard let url = buildEventDeepLink() else {
            shareToSystem(); return
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
        var parts: [String] = []
        parts.append(event.title)
        parts.append("\(dateText) • \(timeText)")
        if !event.location.isEmpty { parts.append(event.location) }
        if event.ticketPrice > 0 { parts.append(String(format: "Tickets $%.0f", event.ticketPrice)) }
        if event.tablePrice > 0 { parts.append(String(format: "Tables $%.0f", event.tablePrice)) }
        return parts.joined(separator: " • ")
    }
}


// MARK: - Generic share presenters (safe fallback)
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
