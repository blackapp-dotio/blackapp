//
//  EventFeedView.swift (stable)
//  BlackAppIOS
//

import SwiftUI
import UIKit
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase

// =====================================================
// MARK: - Eventbrite lightweight model (namespaced here)
// =====================================================
struct EBEvent: Identifiable {
    let id: String
    let title: String
    let venueName: String
    let address: String
    let date: Date
    let imageURL: String?
    let externalURL: String?
    let source: String // "eventbrite"
}

fileprivate let _iso8601Z: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    // Our function emits ISO-8601 with 'Z', sometimes with fractional seconds.
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// =====================================================
// MARK: - EventFeedView (Platform + Eventbrite)
// =====================================================
struct EventFeedView: View {
    @State private var platformEvents: [EventModel] = []
    @State private var externalEvents: [EBEvent] = []   // ⬅️ namespaced model
    @State private var isLoading: Bool = true

    // Filters
    @State private var showOnlyUpcoming: Bool = true
    @State private var filterToday: Bool = false
    @State private var filterWeekend: Bool = false
    @State private var locationQuery: String = ""
    @State private var ticketMinPrice: Double? = nil
    @State private var ticketMaxPrice: Double? = nil
    @State private var tableMinPrice: Double? = nil
    @State private var tableMaxPrice: Double? = nil
    @State private var showFilters: Bool = false

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Events...")
                        .padding()
                } else {
                    // ---------------- Filters header ----------------
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

                    // ---------------- Lists ----------------
                    List {
                        // Platform events
                        Section(header: Text("BlackApp Events")) {
                            if platformEvents.isEmpty {
                                Text("No upcoming events.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(filteredPlatformEvents(), id: \.id) { event in
                                    NavigationLink(destination: EventDetailView(event: event)) {
                                        EventCardView(event: event)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }

                        // Imported Eventbrite events
                        Section(header: Text("Eventbrite")) {
                            if externalEvents.isEmpty {
                                Text("No imported Eventbrite events.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(filteredExternalEvents()) { ev in
                                    EventbriteCardView(item: ev)
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
                // Load both sources in parallel
                fetchPlatformEvents()
                fetchExternalEventbrite()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// =====================================================
// MARK: - DATA LOADERS
// =====================================================
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
            maybeFinishLoading()
        }
    }

    func fetchExternalEventbrite() {
        let ref = Database.database().reference()
            .child("externalEvents")
            .child("eventbrite")

        ref.observeSingleEvent(of: .value) { snapshot in
            var out: [EBEvent] = []

            for case let child as DataSnapshot in snapshot.children {
                guard let dict = child.value as? [String: Any] else { continue }

                let id: String = child.key
                let title: String = (dict["title"] as? String) ?? "Event"
                let venueName: String = (dict["venueName"] as? String) ?? ""
                let address: String = (dict["address"] as? String) ?? ""
                let isoDate: String = (dict["date"] as? String) ?? ""
                let imageURL: String? = (dict["imageURL"] as? String) ?? (dict["heroImage"] as? String)
                let externalURL: String? = (dict["externalURL"] as? String)
                let source: String = (dict["source"] as? String) ?? "eventbrite"

                // Parse ISO8601 to Date with explicit fallback
                let parsedDate: Date = {
                    if let d = _iso8601Z.date(from: isoDate) { return d }
                    let alt = ISO8601DateFormatter()
                    if let d2 = alt.date(from: isoDate) { return d2 }
                    return Date()
                }()

                out.append(EBEvent(
                    id: id,
                    title: title,
                    venueName: venueName,
                    address: address,
                    date: parsedDate,
                    imageURL: imageURL,
                    externalURL: externalURL,
                    source: source
                ))
            }

            self.externalEvents = out.sorted { $0.date < $1.date }
            maybeFinishLoading()
        }
    }

    private func maybeFinishLoading() {
        // Simple spinner gate: once either loader completes, turn off.
        // If you want stricter gating, track two booleans and end only after both finish.
        if isLoading { isLoading = false }
    }
}

// =====================================================
// MARK: - FILTERING
// =====================================================
extension EventFeedView {
    func filteredPlatformEvents() -> [EventModel] {
        var out: [EventModel] = platformEvents

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

    func filteredExternalEvents() -> [EBEvent] {
        var out: [EBEvent] = externalEvents

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
            out = out.filter {
                $0.address.lowercased().contains(q) ||
                $0.venueName.lowercased().contains(q) ||
                $0.title.lowercased().contains(q)
            }
        }
        // Price filters are platform-only; Eventbrite feed doesn't include our ticket/table fields.

        return out.sorted { $0.date < $1.date }
    }
}

import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage

// =====================================================
// MARK: - Flyer image loader (Firebase Storage -> UIImage)
// =====================================================
fileprivate final class FlyerImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

fileprivate struct FlyerStorageImageFitView: View {
    let imagePath: String
    var onAspectResolved: ((CGFloat) -> Void)? = nil // aspect = width/height

    @State private var uiImage: UIImage? = nil
    @State private var isLoading: Bool = false
    @State private var didResolveAspect: Bool = false

    var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(img.size, contentMode: .fit) // ✅ no crop
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.02))
                    .onAppear {
                        guard !didResolveAspect else { return }
                        didResolveAspect = true
                        if img.size.width > 0, img.size.height > 0 {
                            onAspectResolved?(img.size.width / img.size.height)
                        }
                    }
            } else if isLoading {
                ZStack {
                    Color.black.opacity(0.06)
                    ProgressView()
                }
            } else {
                Color.gray.opacity(0.18)
            }
        }
        .onAppear { load() }
        .onChange(of: imagePath) { _ in
            uiImage = nil
            didResolveAspect = false
            load()
        }
    }

    private func load() {
        let trimmed = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isLoading else { return }

        if let cached = FlyerImageCache.shared.object(forKey: trimmed as NSString) {
            self.uiImage = cached
            return
        }

        isLoading = true
        let storageRef = Storage.storage().reference().child(trimmed)

        storageRef.downloadURL { url, _ in
            guard let url = url else {
                DispatchQueue.main.async { self.isLoading = false }
                return
            }

            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    self.isLoading = false
                    guard let data = data, let img = UIImage(data: data) else { return }
                    FlyerImageCache.shared.setObject(img, forKey: trimmed as NSString)
                    self.uiImage = img
                }
            }.resume()
        }
    }
}

// =====================================================
// MARK: - Auto-height swipe carousel (real paging + full flyer visible)
// =====================================================
fileprivate struct EventImageCarouselView: View {
    let imagePaths: [String]

    // Tuning knobs
    private let minHeight: CGFloat = 320
    private let maxHeight: CGFloat = 820
    private let fallbackAspectWH: CGFloat = 4.0 / 5.0 // width/height fallback

    @State private var pageIndex: Int = 0
    @State private var aspectByPath: [String: CGFloat] = [:] // path -> width/height

    private var normalizedPaths: [String] {
        imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)

            let currentPath: String = {
                if pageIndex >= 0, pageIndex < normalizedPaths.count { return normalizedPaths[pageIndex] }
                return normalizedPaths.first ?? ""
            }()

            let aspectWH = max(aspectByPath[currentPath] ?? fallbackAspectWH, 0.1)
            let computedHeight = clamp(width / aspectWH, minHeight, maxHeight)

            ZStack(alignment: .topTrailing) {
                TabView(selection: $pageIndex) {
                    ForEach(Array(normalizedPaths.enumerated()), id: \.offset) { idx, path in
                        FlyerStorageImageFitView(
                            imagePath: path,
                            onAspectResolved: { wh in
                                if wh > 0.1 { aspectByPath[path] = wh }
                            }
                        )
                        .tag(idx)
                        .frame(width: width, height: computedHeight)
                        .background(Color.black.opacity(0.08))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: normalizedPaths.count > 1 ? .automatic : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(width: width, height: computedHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if normalizedPaths.count > 1 {
                    Text("\(pageIndex + 1)/\(normalizedPaths.count)")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
            }
            .frame(width: width, height: computedHeight)
        }
        // Ensure GeometryReader doesn't collapse before first image resolves
        .frame(height: 420)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}

// =====================================================
// MARK: - Event Card View (UPDATED)
// =====================================================
struct EventCardView: View {
    let event: EventModel

    @State private var isSaved: Bool = false
    @State private var showShareOptions: Bool = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var dateText: String { Self.dateFormatter.string(from: event.date) }
    private var timeText: String { Self.timeFormatter.string(from: event.date) }

    private var ticketsRemaining: Int { max(event.ticketQuantity - event.ticketsSold, 0) }
    private var tablesRemaining: Int { max(event.tableQuantity - event.tablesSold, 0) }

    // ✅ Uses gallery when present, else legacy cover
    private var resolvedImagePaths: [String] {
        let legacy = event.imagePath.trimmingCharacters(in: .whitespacesAndNewlines)

        // If EventModel does NOT yet have imagePaths, temporarily return [legacy].
        // If it DOES, this will compile and work:
        let gallery = event.imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !gallery.isEmpty { return gallery }
        return legacy.isEmpty ? [] : [legacy]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            ZStack(alignment: .bottomLeading) {
                if resolvedImagePaths.isEmpty {
                    Color.gray.opacity(0.2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    EventImageCarouselView(imagePaths: resolvedImagePaths)
                }

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 84)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    Label(dateText, systemImage: "calendar")
                    Label(timeText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(10)
            }

            Text(event.title)
                .font(.headline)
                .foregroundColor(.white)

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

            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse").foregroundColor(.gray)
                Text(event.location)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

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

            HStack {
                Button {
                    isSaved.toggle()
                    saveEventToFirebase(isSaved: isSaved)
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .foregroundColor(isSaved ? .yellow : .white)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button { showShareOptions = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onAppear(perform: checkIfSaved)
        .confirmationDialog(
            "Share Event",
            isPresented: $showShareOptions,
            titleVisibility: .visible
        ) {
            Button("Share Event to Gossip") { shareToGossip() }
            Button("Share via…") { shareToSystem() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Save / load
    private func checkIfSaved() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)
        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }

    private func saveEventToFirebase(isSaved: Bool) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)
        if isSaved {
            ref.setValue(["eventId": event.id, "timestamp": Date().timeIntervalSince1970])
        } else {
            ref.removeValue()
        }
    }

    // MARK: - Share helpers (these MUST stay inside EventCardView)
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
        let d = Self.dateFormatter.string(from: event.date)
        let t = Self.timeFormatter.string(from: event.date)
        var parts: [String] = [event.title, "\(d) • \(t)"]
        if !event.location.isEmpty { parts.append(event.location) }
        if event.ticketPrice > 0 { parts.append(String(format: "Tickets $%.0f", event.ticketPrice)) }
        if event.tablePrice > 0 { parts.append(String(format: "Tables $%.0f", event.tablePrice)) }
        return parts.joined(separator: " • ")
    }
}

// =====================================================
// MARK: - Eventbrite Card (External events UI)
// =====================================================
fileprivate struct EventbriteCardView: View {
    let item: EBEvent

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private var dateText: String { Self.dateFormatter.string(from: item.date) }
    private var timeText: String { Self.timeFormatter.string(from: item.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Remote hero image
            if let urlStr = item.imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ZstackLoader()
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Color.gray.opacity(0.2)
                    @unknown default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Title + source badge
            HStack(spacing: 8) {
                Text(item.title).font(.headline)
                Spacer()
                Text("via Eventbrite")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Label(dateText, systemImage: "calendar")
                Label(timeText, systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.9))

            if !item.venueName.isEmpty || !item.address.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse").foregroundColor(.gray)
                    Text(item.venueName.isEmpty ? item.address : "\(item.venueName), \(item.address)")
                        .font(.subheadline).foregroundColor(.gray)
                        .lineLimit(2)
                }
            }

            // --- Actions ---
            VStack(spacing: 8) {
                // Get inside BlackApp (embedded checkout page)
                Button {
                    let uid = Auth.auth().currentUser?.uid ?? "anon"
                    if let url = URL(string: "https://blackappios.web.app/eb.html?eventId=\(item.id)&userId=\(uid)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Get tickets in BlackApp")
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
                .buttonStyle(.borderless)

                // Open directly on Eventbrite (fallback / alternative)
                if let urlStr = item.externalURL, let url = URL(string: urlStr) {
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
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// Small loader view for AsyncImage empty state
fileprivate struct ZstackLoader: View {
    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            ProgressView()
        }
    }
}

// =====================================================
// MARK: - Generic share presenters (existing helpers)
// =====================================================
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
