
import SwiftUI
import FirebaseDatabase
import FeedKit
import WebKit

struct EventFeedView: View {
    @State private var platformEvents: [Event] = []
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
                                                EventCardView(event: event, selectedURL: $selectedURL, showWebView: $showWebView)
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
                    WebView(url: url)
                        .edgesIgnoringSafeArea(.all)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    func fetchPlatformEvents() {
        let ref = Database.database().reference().child("events")
        ref.observeSingleEvent(of: .value) { snapshot in
            var tempEvents: [Event] = []
            for case let child as DataSnapshot in snapshot.children {
                if let event = Event.from(snapshot: child) {
                    tempEvents.append(event)
                }
            }
            self.platformEvents = tempEvents.sorted { $0.date > $1.date }
        }
    }

    func fetchFeedsInChunks(chunkSize: Int = 2) {
        Task {
            let chunks = rssFeedURLs.chunked(into: chunkSize)
            for chunk in chunks {
                await withTaskGroup(of: [RSSArticle].self) { group in
                    for url in chunk {
                        group.addTask {
                            return await fetchFeed(urlString: url)
                        }
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
        let parser = FeedParser(URL: url)
        let result = parser.parse()
        switch result {
        case .success(let feed):
            let items = feed.rssFeed?.items ?? []
            return items.prefix(2).compactMap {
                guard let title = $0.title,
                      let link = $0.link,
                      let description = $0.description?.strippedHTML(),
                      let pubDate = $0.pubDate else { return nil }

                let imageURL = extractImageURL(from: $0)
                return RSSArticle(title: title, link: link, description: description, pubDate: pubDate, imageURL: imageURL)
            }
        default: return []
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
