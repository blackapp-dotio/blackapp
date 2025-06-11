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
                            ForEach(platformEvents) { event in
                                EventCardView(event: event)

                            }
                        }
                        
                        Section(header: Text("External Events")) {
                            ForEach(rssArticles) { article in
                                RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Events")
            .background(Color.black)
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

struct EventCardView: View {
    let event: EventModel
    @State private var showCheckoutConfirmation = false

    var body: some View {
        VStack(alignment: .leading) {
            EventImageView(imagePath: event.imagePath)
                .frame(height: 200)
                .clipped()
                .cornerRadius(10)

            Text(event.title)
                .font(.headline)
                .padding(.top, 5)

            Text(event.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            HStack {
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

            Button(action: {
                showCheckoutConfirmation = true
            }) {
                Text("Buy Tickets / Tables")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            .padding(.top, 8)
        }
        .padding()
        .sheet(isPresented: $showCheckoutConfirmation) {
            CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                openCheckout(ticketQty: ticketQty, tableQty: tableQty)
            }
        }
    }

    private func openCheckout(ticketQty: Int, tableQty: Int) {
        let payoutMethod = event.payoutMethod.isEmpty ? "N/A" : event.payoutMethod
        let payoutDetails = event.payoutDetails.isEmpty ? "N/A" : event.payoutDetails

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
            URLQueryItem(name: "ticketQty", value: "\(ticketQty)"),
            URLQueryItem(name: "tableQty", value: "\(tableQty)"),
            URLQueryItem(name: "baseTotal", value: String(format: "%.2f", grossTotal)),
            URLQueryItem(name: "totalWithFee", value: String(format: "%.2f", totalWithFee)),
            URLQueryItem(name: "payoutMethod", value: payoutMethod),
            URLQueryItem(name: "payoutDetails", value: payoutDetails)
        ]

        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }
}


