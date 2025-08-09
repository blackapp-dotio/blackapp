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
    @State private var showOnlyUpcoming = true
    @State private var filterToday = false
    @State private var filterWeekend = false
    @State private var locationQuery = ""
    @State private var ticketMinPrice: Double? = nil
    @State private var ticketMaxPrice: Double? = nil
    @State private var tableMinPrice: Double? = nil
    @State private var tableMaxPrice: Double? = nil
    @State private var showFilters = false  // NEW STATE
    
    let rssFeedURLs = [
        "https://allevents.in/charlotte/afrobeats?format=rss",
        "https://allevents.in/washington/afrobeats?format=rss",
        "https://www.eventbrite.com/d/nc--charlotte/african-events/rss/",
        "https://allevents.in/atlanta/afrobeats?format=rss",
        "https://allevents.in/new%20york/afrobeats?format=rss",
        "https://allevents.in/miami/afrobeats?format=rss"
    ]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Events...")
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        // Toggle Button
                        Button(action: {
                            withAnimation {
                                showFilters.toggle()
                            }
                        }) {
                            HStack {
                                Text(showFilters ? "Hide Filters ▲" : "Show Filters ▼")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        
                        // FILTER SECTION
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
                        
                        Section(header: Text("External Events")) {
                            if rssArticles.isEmpty {
                                Text("No external events available.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(rssArticles) { article in
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
    
    func filteredEvents() -> [EventModel] {
        let now = Date()
        let calendar = Calendar.current
        
        return platformEvents.filter { event in
            // Upcoming filter
            if showOnlyUpcoming && event.date < now {
                return false
            }
            
            // Today filter
            if filterToday && !calendar.isDate(event.date, inSameDayAs: now) {
                return false
            }
            
            // This weekend filter
            if filterWeekend {
                guard let saturday = calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTimePreservingSmallerComponents),
                      let sunday = calendar.date(byAdding: .day, value: 1, to: saturday) else {
                    return false
                }
                
                if !(calendar.isDate(event.date, inSameDayAs: saturday) || calendar.isDate(event.date, inSameDayAs: sunday)) {
                    return false
                }
            }
            
            // Location filter
            if !locationQuery.isEmpty && !event.location.lowercased().contains(locationQuery.lowercased()) {
                return false
            }
            
            // Ticket/Table price range
            let ticketPasses = (ticketMinPrice == nil || event.ticketPrice >= ticketMinPrice!) &&
            (ticketMaxPrice == nil || event.ticketPrice <= ticketMaxPrice!)
            
            let tablePasses = (tableMinPrice == nil || event.tablePrice >= tableMinPrice!) &&
            (tableMaxPrice == nil || event.tablePrice <= tableMaxPrice!)
            
            // If both filters are filled and both fail, exclude the event
            if ticketMinPrice != nil || ticketMaxPrice != nil || tableMinPrice != nil || tableMaxPrice != nil {
                if !ticketPasses && !tablePasses {
                    return false
                }
            }
            
            return true
        }
    }
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
            
            self.platformEvents = events.sorted { $0.date > $1.date }
        }
    }
    
    func fetchFeedsInChunks(chunkSize: Int = 2) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for chunk in chunks {
                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in chunk {
                        group.addTask { return await fetchFeed(urlString: url) }
                    }
                    for await result in group {
                        let filtered = result.filter { $0.imageURL != nil }
                        await MainActor.run {
                            self.rssArticles.append(contentsOf: filtered)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
    
    func fetchFeed(urlString: String) async -> [RSSArticle] {
        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            return []
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = FeedParser(data: data).parse()

            guard case .success(let feed) = result else {
                print("❌ Failed to parse feed: \(urlString)")
                return []
            }

            let items = feed.rssFeed?.items ?? []
            var articles: [RSSArticle] = []

            for item in items.prefix(3) {
                guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let link = item.link,
                      let desc = item.description?.strippedHTML(),
                      let pub = item.pubDate else {
                    print("⚠️ Skipping incomplete item")
                    continue
                }

                // Prefer enclosure or fallback to <img> in description
                let enclosureURL = item.enclosure?.attributes?.url
                let enclosureType = item.enclosure?.attributes?.type ?? ""
                let fallbackImage = extractImageURL(from: item.description ?? "")
                let isVideo = enclosureType.contains("video")

                // Either provide videoURL or imageURL
                let videoURL = isVideo ? URL(string: enclosureURL ?? "") : nil
                let imageURL: URL? = {
                    if isVideo { return nil }
                    if let enclosureURL, enclosureType.contains("image") {
                        return URL(string: enclosureURL)
                    }
                    if let fallback = fallbackImage {
                        return URL(string: fallback)
                    }
                    return nil
                }()

                guard imageURL != nil || videoURL != nil else {
                    print("⛔️ Skipping item due to missing media: \(title)")
                    continue
                }

                articles.append(RSSArticle(
                    title: title,
                    link: link,
                    description: desc,
                    pubDate: pub,
                    imageURL: imageURL,
                    videoURL: videoURL
                ))
            }

            print("✅ Parsed \(articles.count) media-rich articles from \(urlString)")
            return articles

        } catch {
            print("❌ Error fetching from \(urlString):", error.localizedDescription)
            return []
        }
    }

    
    
    
    func extractImageURL(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return (html as NSString).substring(with: match.range(at: 1))
    }
}

/*    import SwiftUI
    import Firebase */
    
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
                    
                    Button(action: {
                        showShare = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                    }
                }
                .font(.caption)
                .padding(.top, 4)
                
                // MARK: - Checkout Button
                Button(action: {
                    showCheckout = true
                }) {
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
                    // Twitter
                    Button(action: {
                        if let url = URL(string: "https://twitter.com/intent/tweet?text=Check out this event! \(eventURL)") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Image(systemName: "bird.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.blue)
                    }
                    
                    // WhatsApp
                    Button(action: {
                        if let url = URL(string: "https://wa.me/?text=Check out this event! \(eventURL)") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.green)
                    }
                    
                    // Facebook
                    Button(action: {
                        if let url = URL(string: "https://www.facebook.com/sharer/sharer.php?u=\(eventURL)") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Image(systemName: "f.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.blue)
                    }
                    
                    // Instagram (Note: Opens profile link, can't deep share natively)
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
