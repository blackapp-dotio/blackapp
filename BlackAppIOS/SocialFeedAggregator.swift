// SocialFeedAggregator.swift
// MVP logic for aggregating feeds based on user-selected interests

import Foundation

struct FeedItem: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let imageURL: String?
    let link: String
    let source: String
    let timestamp: Date
}

enum FeedCategory: String, CaseIterable, Identifiable {
    var id: String { self.rawValue }

    case music = "Music"
    case tech = "Tech"
    case news = "News"
    case popCulture = "Pop Culture"
    case fashion = "Fashion"
    case finance = "Finance"
}

struct SocialFeedAggregator {
    // RSS sources per category
    static let rssSources: [FeedCategory: [String]] = [
        .music: [
            "https://www.okayafrica.com/rss/",                      // African music + culture
            "https://www.thefader.com/rss",                         // Global + African diaspora music
            "https://notjustok.com/feed/",                          // Afrobeats + Naija music
            "https://tooxclusive.com/feed/"                         // Nigerian music
        ],
        .tech: [
            "https://techcabal.com/feed/",                          // African tech startups
            "https://techpoint.africa/feed/",                       // Nigerian tech hub
            "https://bongotech.co.tz/feed/",                        // East African tech scene
            "https://disrupt-africa.com/feed/"                      // Pan-African innovation
        ],
        .news: [
            "https://www.pulse.ng/news/rss",                        // Nigerian + African news
            "https://www.aljazeera.com/xml/rss/all.xml",            // African stories global angle
            "https://www.citinewsroom.com/feed/",                   // Ghanaian news
            "https://www.sabcnews.com/sabcnews/feed/"               // South African Broadcasting
        ],
        .popCulture: [
            "https://www.bellanaija.com/feed/",                     // Nigerian lifestyle + celeb
            "https://guardian.ng/life/feed/",                       // Culture + entertainment
            "https://www.okayplayer.com/rss",                       // Black music + diaspora stories
            "https://www.essence.com/feed/"                         // Black women, celeb, culture
        ],
        .fashion: [
            "https://fashionghana.com/site/feed/",                  // African fashion + designers
            "https://www.bellanaija.com/feed/",                     // Style + weddings
            "https://www.essence.com/feed/",                        // Black fashion
            "https://www.okayafrica.com/rss/"                       // Afro fashion/culture mix
        ],
        .finance: [
            "https://nairametrics.com/feed/",                       // Nigerian markets & economy
            "https://african.business/feed/",                       // African continent economics
            "https://www.moneyweb.co.za/feed/",                     // Southern Africa finance
            "https://guardian.ng/business/feed/"                    // Nigerian + diaspora economy
        ]
    ]


    static func fetchFeeds(for categories: [FeedCategory], completion: @escaping ([FeedItem]) -> Void) {
        let selectedFeeds = categories.flatMap { rssSources[$0] ?? [] }
        let feedGroups = selectedFeeds.chunked(into: 2)

        var aggregatedItems: [FeedItem] = []
        let group = DispatchGroup()

        for groupFeeds in feedGroups {
            for feedURL in groupFeeds {
                group.enter()
                RSSParser.parseFeed(urlString: feedURL) { items in
                    aggregatedItems.append(contentsOf: items)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let sorted = aggregatedItems.sorted(by: { $0.timestamp > $1.timestamp })
            completion(sorted)
        }
    }
}


