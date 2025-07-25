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

    let rssFeedURLs = [
        "https://rss.app/feeds/nsmT2WdQXSlshmcy.xml",
        "https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml",
        "https://rss.app/feeds/uCjXryL38K1J4e29.xml",
        "https://rss.app/feeds/pv5YufdSsNN6ROH5.xml",
        "https://rss.app/feeds/keM7mXLp4OlutaGg.xml"
    ]

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Events...")
                        .padding()
                } else {
                    List {
                        Section(header: Text("BlackApp Events")) {
                            if platformEvents.isEmpty {
                                Text("No upcoming events.")
                                    .foregroundColor(.gray)
                                    .italic()
                                    .padding(.vertical)
                            } else {
                                ForEach(platformEvents) { event in
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
        guard let url = URL(string: urlString) else { return [] }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                let parser = FeedParser(URL: url)
                let result = parser.parse()

                var articles: [RSSArticle] = []

                switch result {
                case .success(let feed):
                    let items = feed.rssFeed?.items ?? []
                    articles = items.prefix(3).compactMap {
                        guard let title = $0.title,
                              let link = $0.link,
                              let description = $0.description?.strippedHTML(),
                              let pubDate = $0.pubDate else { return nil }

                        let imageURL = extractImageURL(from: $0)
                        return RSSArticle(title: title, link: link, description: description, pubDate: pubDate, imageURL: imageURL)
                    }
                case .failure(let error):
                    print("❌ Failed to parse feed: \(error)")
                }

                continuation.resume(returning: articles)
            }
        }
    }

    func extractImageURL(from item: RSSFeedItem) -> URL? {
        if let mediaURL = item.media?.mediaContents?.first?.attributes?.url {
            return URL(string: mediaURL)
        }

        if let desc = item.description,
           let imgTagRange = desc.range(of: "<img[^>]+src=\"([^\"]+)\"", options: .regularExpression),
           let match = desc[imgTagRange].range(of: "src=\"([^\"]+)\"", options: .regularExpression),
           let urlRange = desc[match].range(of: #"(?<=src=\")[^\"]+"#, options: .regularExpression) {
            return URL(string: String(desc[match][urlRange]))
        }

        return nil
    }
}

import SwiftUI
import Firebase

struct EventCardView: View {
    let event: EventModel

    @State private var showCheckout = false
    @State private var showShare = false
    @State private var isSaved = false
    @State private var showCopiedAlert = false

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
