// RSSParser.swift
// Parses RSS feeds and returns FeedItem arrays

import Foundation
import FeedKit

struct RSSParser {
    static func parseFeed(urlString: String, completion: @escaping ([FeedItem]) -> Void) {
        guard let feedURL = URL(string: urlString) else {
            completion([])
            return
        }

        let parser = FeedParser(URL: feedURL)
        parser.parseAsync(queue: DispatchQueue.global(qos: .background)) { result in
            switch result {
            case .success(let feed):
                var items: [FeedItem] = []

                if let rssFeed = feed.rssFeed {
                    for entry in rssFeed.items ?? [] {
                        guard let title = entry.title,
                              let link = entry.link else { continue }

                        let description = entry.description ?? entry.content?.contentEncoded ?? ""
                        let pubDate = entry.pubDate ?? Date()
                        let source = rssFeed.title ?? "RSS"

                        let imageURL = entry.media?.mediaContents?.first?.attributes?.url ??
                            entry.enclosure?.attributes?.url ??
                            extractFirstImageURL(from: description)

                        let feedItem = FeedItem(
                            title: title,
                            description: description.strippedHTML(),
                            imageURL: imageURL,
                            link: link,
                            source: source,
                            timestamp: pubDate
                        )

                        items.append(feedItem)
                    }
                }

                completion(items)

            case .failure(let error):
                print("❌ RSS Parse error: \(error.localizedDescription)")
                completion([])
            }
        }
    }

    private static func extractFirstImageURL(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=\\\"(.*?)\\\"", options: .caseInsensitive),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) else {
            return nil
        }

        if let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        return nil
    }
}

// Simple HTML stripper
extension String {
    func strippedHTML() -> String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        return self
    }
}
