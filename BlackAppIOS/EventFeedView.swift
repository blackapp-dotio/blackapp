import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase
import FeedKit
import WebKit

// MARK: - EventFeedView
struct EventFeedView: View {
    @State private var platformEvents: [EventModel] = []
    @State private var rssArticles: [RSSArticle] = []
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false
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

    // === MERGED RSS LIST (web + iOS), de-duped ===
    private let rssFeedURLs: [String] = {
        let web = [
            "https://rss.app/feeds/nsmT2WdQXSlshmcy.xml",
            "https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml",
            "https://rss.app/feeds/uCjXryL38K1J4e29.xml",
            "https://rss.app/feeds/pv5YufdSsNN6ROH5.xml",
            "https://rss.app/feeds/keM7mXLp4OlutaGg.xml",
            "https://rss.app/feeds/KwsTlmbvwXiY4YX6.xml",
            "https://rss.app/feeds/fQ6cY8V57Sk5ayox.xml"
        ]
        let ios = [
            "https://allevents.in/charlotte/afrobeats?format=rss",
            "https://allevents.in/washington/afrobeats?format=rss",
            "https://www.eventbrite.com/d/nc--charlotte/african-events/rss/",
            "https://allevents.in/atlanta/afrobeats?format=rss",
            "https://allevents.in/new%20york/afrobeats?format=rss",
            "https://allevents.in/miami/afrobeats?format=rss"
        ]
        return Array(Set(web + ios))
    }()

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

                        // --- External events (RSS) ---
                        Section(header: Text("External Events")) {
                            let external = filteredExternalArticles()
                            if external.isEmpty {
                                Text("No external events available.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(external) { article in
                                    RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
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
                fetchFeedsInChunks()
            }
            .sheet(isPresented: $showWebView) {
                if let url = selectedURL {
                    WebView(url: url).edgesIgnoringSafeArea(.all)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - DATA (Platform + RSS)
extension EventFeedView {

    // Replace with your actual DB fetch if needed.
    func fetchPlatformEvents() {
        // Example fetch keeping only future events:
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
        }
    }

    // Chunked RSS fetch (mirrors your working web logic)
    func fetchFeedsInChunks(chunkSize: Int = 3) {
        Task {
            var all: [RSSArticle] = []

            for chunk in chunkedArray(rssFeedURLs, size: chunkSize) {
                var chunkArticles: [RSSArticle] = []
                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in chunk {
                        group.addTask { await fetchFeed(urlString: url) }
                    }
                    for await items in group { chunkArticles.append(contentsOf: items) }
                }
                all.append(contentsOf: chunkArticles)
            }

            // De-dupe (title+link) and sort by publish date desc
            let unique = dedupe(all) { "\($0.title.lowercased())|\($0.link)" }
            let sorted = unique.sorted { $0.pubDate > $1.pubDate }

            await MainActor.run {
                rssArticles = sorted
                isLoading = false
            }
        }
    }

    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try FeedParser(data: data).parse()
            guard case .success(let feed) = result, let items = feed.rssFeed?.items else { return [] }

            var events: [RSSArticle] = []
            for item in items {
                guard
                    let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                    let link = item.link
                else { continue }

                let pubDate = item.pubDate ?? Date.distantPast
                let plain = extractPlainText(from: item.description ?? "")

                // Prefer media:content / enclosure, else first <img> in description
                let enc = item.enclosure?.attributes?.url
                let mediaURL = enc ?? firstMediaURL(from: item.media?.mediaContents)
                let imageURL = mediaURL.flatMap(URL.init) ??
                               extractImageURL(from: item.description ?? "").flatMap(URL.init)

                events.append(RSSArticle(
                    title: title,
                    link: link,
                    description: plain,
                    pubDate: pubDate,
                    imageURL: imageURL,
                    videoURL: nil
                ))
            }
            return events
        } catch {
            print("❌ RSS fetch error (\(urlString)): \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - FILTERING
extension EventFeedView {
    // Apply your platform filters (upcoming/today/weekend/location/price)
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
            // NOTE: EventModel uses `title`, not `name`
            out = out.filter { $0.location.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        }

        // Optional price filters (adapt to your fields)
        if let min = ticketMinPrice { out = out.filter { $0.ticketPrice >= min } }
        if let max = ticketMaxPrice { out = out.filter { $0.ticketPrice <= max } }
        if let tmin = tableMinPrice { out = out.filter { $0.tablePrice >= tmin } }
        if let tmax = tableMaxPrice { out = out.filter { $0.tablePrice <= tmax } }

        return out.sorted { $0.date < $1.date }
    }

    // Filter external RSS in a similar spirit (by text + date)
    func filteredExternalArticles() -> [RSSArticle] {
        var arr = rssArticles

        if !locationQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = locationQuery.lowercased()
            arr = arr.filter {
                $0.title.lowercased().contains(q) || $0.description.lowercased().contains(q)
            }
        }

        let cal = Calendar.current
        if showOnlyUpcoming {
            arr = arr.filter { $0.pubDate >= Date() || cal.isDateInToday($0.pubDate) }
        }
        if filterToday {
            arr = arr.filter { cal.isDateInToday($0.pubDate) }
        }
        if filterWeekend {
            arr = arr.filter { cal.isDateInWeekend($0.pubDate) }
        }

        return arr
    }
}

// MARK: - Helpers (HTML, media, chunking, dedupe)
extension EventFeedView {
    func extractImageURL(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<img[^>]+src=[\"']([^\"']+)[\"']",
            options: .caseInsensitive
        ) else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    func extractPlainText(from html: String) -> String {
        guard let data = html.data(using: .utf8) else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func firstMediaURL(from contents: [MediaContent]?) -> String? {
        guard let contents else { return nil }
        for c in contents {
            if let u = c.attributes?.url { return u }
        }
        return nil
    }

    func chunkedArray<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        var res: [[T]] = []
        var idx = 0
        while idx < array.count {
            let end = min(idx + size, array.count)
            res.append(Array(array[idx..<end]))
            idx = end
        }
        return res
    }

    func dedupe<T>(_ array: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for el in array {
            let k = key(el)
            if !seen.contains(k) {
                out.append(el)
                seen.insert(k)
            }
        }
        return out
    }
}

// =======================
// MARK: - Event Card View
// =======================

struct EventCardView: View {
    let event: EventModel

    @State private var showCheckout = false
    @State private var showShare = false
    @State private var isSaved = false
    @State private var showCopiedAlert = false

    var ticketsRemaining: Int {
        max(event.ticketQuantity - (event.ticketsSold), 0)
    }

    var tablesRemaining: Int {
        max(event.tableQuantity - (event.tablesSold), 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EventImageView(imagePath: event.imagePath)
                .frame(height: 200)
                .clipped()
                .cornerRadius(12)

            Text(event.title)
                .font(.headline)
                .padding(.top, 4)

            Text(event.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.gray)
                Text(event.location)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            // MARK: - Ticket & Table Prices
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

            // MARK: - Remaining Count with Color Indicators
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

            // MARK: - Save & Share
            HStack {
                Button(action: {
                    isSaved.toggle()
                    saveEventToFirebase(event: event, isSaved: isSaved)
                }) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .foregroundColor(isSaved ? .yellow : .white)
                }

                Spacer()

                Button(action: { showShare = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
            }
            .font(.caption)
            .padding(.top, 4)

            // MARK: - Checkout Button
            Button(action: { showCheckout = true }) {
                Text("Buy Tickets / Tables")
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear(perform: checkIfSaved)
        .sheet(isPresented: $showCheckout) {
            CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                openCheckout(ticketQty: ticketQty, tableQty: tableQty)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareModal(eventId: event.id, showCopiedAlert: $showCopiedAlert)
        }
        .alert(isPresented: $showCopiedAlert) {
            Alert(title: Text("Link Copied"), message: Text("Event link copied to clipboard."), dismissButton: .default(Text("OK")))
        }
    }

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
            let payload: [String: Any] = [
                "eventId": event.id,
                "timestamp": Date().timeIntervalSince1970
            ]
            ref.setValue(payload)
        } else {
            ref.removeValue()
        }
    }

    private func openCheckout(ticketQty: Int, tableQty: Int) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❌ No user logged in")
            return
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
}

// MARK: - Share Modal
struct ShareModal: View {
    let eventId: String
    @Binding var showCopiedAlert: Bool
    @Environment(\.presentationMode) var presentationMode

    var eventURL: String {
        "https://blackappios.web.app/event.html?eventId=\(eventId)"
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Share This Event")
                .font(.title2)
                .bold()

            Button(action: {
                UIPasteboard.general.string = eventURL
                showCopiedAlert = true
                presentationMode.wrappedValue.dismiss()
            }) {
                Label("Copy Link", systemImage: "doc.on.doc")
                    .foregroundColor(.blue)
            }

            HStack(spacing: 30) {
                Button(action: {
                    if let url = URL(string: "https://twitter.com/intent/tweet?text=Check out this event! \(eventURL)") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.blue)
                }

                Button(action: {
                    if let url = URL(string: "https://wa.me/?text=Check out this event! \(eventURL)") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.green)
                }

                Button(action: {
                    if let url = URL(string: "https://www.facebook.com/sharer/sharer.php?u=\(eventURL)") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Image(systemName: "f.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.blue)
                }

                Button(action: {
                    if let url = URL(string: "https://www.instagram.com/") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.pink)
                }
            }

            Spacer()
        }
        .padding()
    }
}

