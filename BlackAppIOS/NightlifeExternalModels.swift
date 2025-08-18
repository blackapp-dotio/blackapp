//
//  NightlifeExternalModels.swift
//  BlackAppIOS
//

import Foundation
import SwiftUI
import SafariServices
import FirebaseDatabase

// MARK: - Unified Venue & Price helpers (compat with older call-sites)

public struct ExternalVenue: Hashable, Codable {
    public var name: String
    public var address: String?
    public var city: String?
    public var lat: Double?
    public var lng: Double?
    public var imageURL: String?
    public var sourceId: String?

    public init(name: String,
                address: String? = nil,
                city: String? = nil,
                lat: Double? = nil,
                lng: Double? = nil,
                imageURL: String? = nil,
                sourceId: String? = nil) {
        self.name = name
        self.address = address
        self.city = city
        self.lat = lat
        self.lng = lng
        self.imageURL = imageURL
        self.sourceId = sourceId
    }
}

public struct ExternalPrice: Hashable, Codable {
    public var min: Double?
    public var max: Double?
    public var currency: String?

    public init(min: Double? = nil, max: Double? = nil, currency: String? = nil) {
        self.min = min
        self.max = max
        self.currency = currency
    }
}

// MARK: - Affiliate toggle

enum AffiliateSwitch {
    static var useAffiliateLinks = false
}

struct AffiliateIDs {
    static var impactIdSeatGeek: String = ""
    static var impactIdStubHub: String = ""
    static var ticketmasterImpactBase: String = "" // https://ticketmaster.evyy.net/c/XXXX/... ?u=
    static var eventbriteFlexBase: String = ""     // https://track.flexlinkspro.com/g.ashx?...&fobs=
    static var sovrnSiteId: String = ""            // Sovrn/Skimlinks site id (fallback)
}

func affiliateURLWrapped(source: String, original: URL, subId: String? = nil) -> URL {
    guard AffiliateSwitch.useAffiliateLinks else { return original }
    let encoded = original.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? original.absoluteString

    switch source.lowercased() {
    case "ticketmaster":
        if !AffiliateIDs.ticketmasterImpactBase.isEmpty {
            var link = AffiliateIDs.ticketmasterImpactBase + encoded
            if let subId { link += "&subId=\(subId)" }
            return URL(string: link) ?? original
        } else if !AffiliateIDs.sovrnSiteId.isEmpty {
            let link = "https://redirect.sovrn.com/click?site_id=\(AffiliateIDs.sovrnSiteId)&url=\(encoded)"
            return URL(string: link) ?? original
        }
        return original

    case "seatgeek":
        if !AffiliateIDs.impactIdSeatGeek.isEmpty {
            let link = "https://go.impact.com/aff_c?offer_id=\(AffiliateIDs.impactIdSeatGeek)&url=\(encoded)"
            return URL(string: link) ?? original
        }
        return original

    case "stubhub":
        if !AffiliateIDs.impactIdStubHub.isEmpty {
            let link = "https://go.impact.com/aff_c?offer_id=\(AffiliateIDs.impactIdStubHub)&url=\(encoded)"
            return URL(string: link) ?? original
        }
        return original

    case "eventbrite":
        if !AffiliateIDs.eventbriteFlexBase.isEmpty {
            let link = AffiliateIDs.eventbriteFlexBase + encoded
            return URL(string: link) ?? original
        }
        return original

    default:
        if var comps = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            var q = comps.queryItems ?? []
            q.append(contentsOf: [
                URLQueryItem(name: "utm_source", value: "blackapp"),
                URLQueryItem(name: "utm_medium", value: "referral"),
                URLQueryItem(name: "utm_campaign", value: "nightlife")
            ])
            comps.queryItems = q
            return comps.url ?? original
        }
        return original
    }
}

// MARK: - CodingKey helper

fileprivate struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

// MARK: - ExternalFeedItem (network DTO; avoids conflicts with any existing FeedItem)

public struct ExternalFeedItem: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let venueName: String
    public let address: String
    public let date: String                // ISO-8601 "Z" string from the server
    public let price: Double?
    public let externalURL: String?
    public let source: String              // "ticketmaster" | "eventbrite"
    public let heroImage: String?
}

// MARK: - ExternalEvent (app model)

public struct ExternalEvent: Identifiable, Hashable, Codable {
    public var id: String
    public var title: String
    public var venueName: String
    public var address: String
    public var date: Date
    public var price: Double?
    public var externalURL: String?
    public var source: String?
    public var heroImage: String?

    // Compatibility:

    public var venue: ExternalVenue {
        ExternalVenue(
            name: venueName,
            address: address,
            city: ExternalEvent.extractCity(from: address),
            imageURL: heroImage
        )
    }

    public var ticketPrice: ExternalPrice? {
        guard let p = price else { return nil }
        return ExternalPrice(min: p, max: p, currency: "USD")
    }

    public var startsAt: Date? { date }
    public var purchaseURL: String { externalURL ?? "" }

    public init(
        id: String,
        title: String,
        venueName: String,
        address: String,
        date: Date,
        price: Double? = nil,
        externalURL: String? = nil,
        source: String? = nil,
        heroImage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.venueName = venueName
        self.address = address
        self.date = date
        self.price = price
        self.externalURL = externalURL
        self.source = source
        self.heroImage = heroImage
    }

    // Convert from network DTO
    public init(from item: ExternalFeedItem) {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let when = iso.date(from: item.date) ?? Date()
        self.init(
            id: item.id,
            title: item.title,
            venueName: item.venueName,
            address: item.address,
            date: when,
            price: item.price,
            externalURL: item.externalURL,
            source: item.source,
            heroImage: item.heroImage
        )
    }

    // Flexible Decodable for legacy payloads
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        func str(_ keys: [String]) -> String? {
            for k in keys {
                if let v = try? c.decodeIfPresent(String.self, forKey: AnyKey(k)) { return v }
            }
            return nil
        }

        func dbl(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = try? c.decodeIfPresent(Double.self, forKey: AnyKey(k)) { return v }
                if let i = try? c.decodeIfPresent(Int.self, forKey: AnyKey(k)) { return Double(i) }
                if let i64 = try? c.decodeIfPresent(Int64.self, forKey: AnyKey(k)) { return Double(i64) }
                if let s = try? c.decodeIfPresent(String.self, forKey: AnyKey(k)) {
                    let sanitized = s.replacingOccurrences(of: ",", with: "")
                    if let v = Double(sanitized) { return v }
                }
            }
            return nil
        }

        let fallbackId = str(["id","eventId","uuid","pk"]) ?? UUID().uuidString
        let t = str(["title","name"]) ?? "Event"
        let vn = str(["venueName","venue","place","locationName"]) ?? ""
        let addr = str(["address","address1","formatted_address","venueAddress"]) ?? ""

        // Date can be seconds/ms/ISO string
        let dateSeconds = dbl(["date","startTime","start","timestamp"])
        let dateString = str(["date","startTime","start","timestamp","isoDate"])

        let parsedDate: Date = {
            if let s = dateSeconds {
                let secs = s > 10_000_000_000 ? s / 1000.0 : s
                return Date(timeIntervalSince1970: secs)
            }
            if let ds = dateString {
                let iso = ISO8601DateFormatter()
                if let d = iso.date(from: ds) { return d }
                let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                if let d = f1.date(from: ds) { return d }
                let f2 = DateFormatter(); f2.dateStyle = .medium; f2.timeStyle = .short
                if let d = f2.date(from: ds) { return d }
                let f3 = DateFormatter(); f3.dateStyle = .short; f3.timeStyle = .none
                if let d = f3.date(from: ds) { return d }
            }
            return Date()
        }()

        let priceVal = dbl(["price","ticketPrice","minPrice","lowestPrice"])
        let urlVal = str(["url","externalURL","link","purchaseUrl","purchaseURL"])
        let sourceVal = str(["source","provider"])
        let heroVal = str(["heroImage","image","imageUrl","imageURL","thumbnail"])

        self.init(
            id: fallbackId,
            title: t,
            venueName: vn,
            address: addr,
            date: parsedDate,
            price: priceVal,
            externalURL: urlVal,
            source: sourceVal,
            heroImage: heroVal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(venueName, forKey: AnyKey("venueName"))
        try c.encode(address, forKey: AnyKey("address"))
        try c.encode(date.timeIntervalSince1970, forKey: AnyKey("date"))
        try c.encodeIfPresent(price, forKey: AnyKey("price"))
        try c.encodeIfPresent(externalURL, forKey: AnyKey("externalURL"))
        try c.encodeIfPresent(source, forKey: AnyKey("source"))
        try c.encodeIfPresent(heroImage, forKey: AnyKey("heroImage"))
    }

    // Firebase snapshot helper
    public static func from(_ snap: DataSnapshot) -> ExternalEvent? {
        guard let v = snap.value as? [String: Any] else { return nil }

        let id = snap.key
        let title = (v["title"] as? String) ?? (v["name"] as? String) ?? "Event"
        let venueName = (v["venueName"] as? String) ?? (v["venue"] as? String) ?? ""
        let address = (v["address"] as? String) ?? ""

        let dateAny = v["date"] ?? v["startTime"] ?? v["start"] ?? v["timestamp"]
        let date = parseDate(from: dateAny) ?? Date()

        let price = (v["price"] as? Double) ?? (v["ticketPrice"] as? Double)
        let externalURL = (v["url"] as? String) ?? (v["externalURL"] as? String) ?? (v["link"] as? String)
        let source = (v["source"] as? String) ?? (v["provider"] as? String)
        let heroImage = (v["heroImage"] as? String) ?? (v["image"] as? String) ?? (v["imageUrl"] as? String) ?? (v["imageURL"] as? String)

        return ExternalEvent(
            id: id,
            title: title,
            venueName: venueName,
            address: address,
            date: date,
            price: price,
            externalURL: externalURL,
            source: source,
            heroImage: heroImage
        )
    }

    private static func parseDate(from any: Any?) -> Date? {
        if let t = any as? TimeInterval {
            let secs = t > 10_000_000_000 ? t / 1000.0 : t
            return Date(timeIntervalSince1970: secs)
        }
        if let n = any as? NSNumber {
            let secs = n.doubleValue > 10_000_000_000 ? n.doubleValue / 1000.0 : n.doubleValue
            return Date(timeIntervalSince1970: secs)
        }
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            if let d = f1.date(from: s) { return d }
            let f2 = DateFormatter(); f2.dateStyle = .medium; f2.timeStyle = .short
            if let d = f2.date(from: s) { return d }
            let f3 = DateFormatter(); f3.dateStyle = .short; f3.timeStyle = .none
            if let d = f3.date(from: s) { return d }
        }
        return nil
    }

    private static func extractCity(from address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts.last
    }
}

// MARK: - Array helper for legacy call-sites

extension Array where Element == ExternalEvent {
    public func sorted(using areInIncreasingOrder: (ExternalEvent, ExternalEvent) -> Bool) -> [ExternalEvent] {
        sorted(by: areInIncreasingOrder)
    }
}

// MARK: - Image-first sort helper

fileprivate extension Array where Element == ExternalEvent {
    func sortedImageFirstThenDate() -> [ExternalEvent] {
        self.sorted { a, b in
            let ai = (a.heroImage?.isEmpty == false) ? 1 : 0
            let bi = (b.heroImage?.isEmpty == false) ? 1 : 0
            if ai != bi { return ai > bi }            // images first
            if a.date != b.date { return a.date < b.date }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: - RTDB merged fetch (optional)

extension NightlifeService {
    /// Pull from multiple likely RTDB paths and merge/dedupe.
    public func fetchExternalEventsMerged(
        paths: [String] = ["externalEvents", "external/events", "feeds/external/events"],
        completion: @escaping ([ExternalEvent]) -> Void
    ) {
        let group = DispatchGroup()
        var all: [ExternalEvent] = []

        for p in paths {
            group.enter()
            db.child(p).observeSingleEvent(of: .value) { snap in
                if snap.exists() {
                    for case let child as DataSnapshot in snap.children {
                        if let e = ExternalEvent.from(child) { all.append(e) }
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            let deduped = all.filter { e in
                let key = "\(e.source ?? "")|\(e.id)|\(e.title)|\(Int(e.date.timeIntervalSince1970))"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
            .sortedImageFirstThenDate()

            completion(deduped)
        }
    }
}

// MARK: - Two frontend paths to get data

// A) Direct Cloud Functions (recommended primary)
public final class FeedsAPI {
    public static let shared = FeedsAPI()
    private init() {}

    private let base = URL(string: "https://us-central1-blackappios.cloudfunctions.net")!

    // Use a dedicated session: no brotli, sensible timeouts.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 35
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip, deflate"
        ]
        return URLSession(configuration: cfg)
    }()

    public enum Endpoint: String {
        case ticketmaster = "feedTicketmaster"
        case eventbrite   = "feedEventbrite"
    }

    @discardableResult
    public func fetch(
        _ endpoint: FeedsAPI.Endpoint,
        city: String,
        start: Date,
        end: Date,
        requireImage: Bool = true,
        imagesFirst: Bool = true,
        timeout: TimeInterval = 25
    ) async throws -> [ExternalFeedItem] {
        var comps = URLComponents(
            url: base.appendingPathComponent(endpoint.rawValue),
            resolvingAgainstBaseURL: false
        )!

        // Ensure city is ALWAYS present
        let cityParam = city.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "city", value: cityParam.isEmpty ? "New York" : cityParam),
            URLQueryItem(name: "start", value: FeedsAPI.iso8601Z(start)),
            URLQueryItem(name: "end",   value: FeedsAPI.iso8601Z(end)),
            URLQueryItem(name: "requireImage", value: requireImage ? "1" : "0"),
            URLQueryItem(name: "imagesFirst",  value: imagesFirst  ? "1" : "0")
        ]
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        do {
            return try JSONDecoder().decode([ExternalFeedItem].self, from: data)
        } catch {
            // If server sent HTML or anything odd, just propagate empty
            return []
        }
    }

    private static let iso8601NoMS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    public static func iso8601Z(_ date: Date) -> String { iso8601NoMS.string(from: date) }
}


// B) Hosting proxy fallback client (tries Hosting /api if you add rewrites)
fileprivate enum ExternalAPI {
    /// Direct Cloud Functions base (Express mounted at root)
    static let functionsBase = "https://us-central1-blackappios.cloudfunctions.net"
    /// Firebase Hosting proxy (rewrite /api/** -> functions) — optional
    static let hostingBase   = "https://blackappios.web.app/api" // or firebaseapp.com/api
}

fileprivate final class ExternalHTTP {
    static let shared = ExternalHTTP()
    private init() {}

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 35
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 3
        // Remove "br" to avoid -1017 when CFNetwork/HTTP3 trips
        cfg.httpAdditionalHeaders = ["Accept": "application/json", "Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: cfg)
    }()

    struct HTTPError: Error, CustomStringConvertible {
        let status: Int
        let bodySnippet: String
        var description: String { "HTTP \(status) \(bodySnippet)" }
    }

    /// Fetch JSON array `[ExternalEvent]` from a path like "/feedTicketmaster"
    func fetchEvents(path: String, query: [URLQueryItem], completion: @escaping (Result<[ExternalEvent], Error>) -> Void) {
        // Try direct CF first, then hosting proxy
        let bases = [ExternalAPI.functionsBase, ExternalAPI.hostingBase]

        func attempt(index: Int, retry: Int) {
            guard index < bases.count else {
                completion(.failure(NSError(domain: "ExternalHTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "No base succeeded."])))
                return
            }
            var comps = URLComponents(string: bases[index] + path)!
            comps.queryItems = query.isEmpty ? nil : query

            guard let url = comps.url else {
                completion(.failure(NSError(domain: "ExternalHTTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"])))
                return
            }

            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let task = session.dataTask(with: req) { data, resp, err in
                if let err = err as? URLError {
                    #if DEBUG
                    print("❌ \(path) transport error [base \(index)] \(err.code.rawValue): \(err.localizedDescription)")
                    #endif
                    if retry < 2 {
                        let delay = pow(2.0, Double(retry))
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            attempt(index: index, retry: retry + 1)
                        }
                    } else {
                        attempt(index: index + 1, retry: 0)
                    }
                    return
                }

                guard let http = resp as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "ExternalHTTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])))
                    return
                }

                let is2xx = (200..<300).contains(http.statusCode)
                let mime = http.mimeType?.lowercased() ?? ""
                let looksJSON = mime.contains("application/json") || mime.contains("text/json") || mime.contains("application/octet-stream")

                if !is2xx {
                    let snippet = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(180) ?? ""
                    #if DEBUG
                    print("❌ \(path) HTTP \(http.statusCode) [base \(index)] \(snippet)")
                    #endif
                    attempt(index: index + 1, retry: 0)
                    return
                }

                guard let data = data else {
                    completion(.success([]))
                    return
                }

                guard looksJSON else {
                    let snippet = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                    #if DEBUG
                    print("❌ \(path) unexpected MIME '\(mime)'. Body: \(snippet)")
                    #endif
                    if index + 1 < bases.count {
                        attempt(index: index + 1, retry: 0)
                    } else {
                        completion(.failure(HTTPError(status: http.statusCode, bodySnippet: String(snippet))))
                    }
                    return
                }

                do {
                    // Decode into ExternalFeedItem (DTO), then map to app model
                    let list = try JSONDecoder().decode([ExternalFeedItem].self, from: data)
                    let events = list.map(ExternalEvent.init(from:))
                    completion(.success(events))
                } catch {
                    #if DEBUG
                    let snippet = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                    print("❌ \(path) JSON decode failed: \(error). Body: \(snippet)")
                    #endif
                    if index + 1 < bases.count {
                        attempt(index: index + 1, retry: 0)
                    } else {
                        completion(.failure(error))
                    }
                }
            }
            task.resume()
        }

        attempt(index: 0, retry: 0)
    }
}

// MARK: - Public aggregator (Ticketmaster + Eventbrite) with dual-path strategy

final class ExternalFeedsClient {
    static let shared = ExternalFeedsClient()
    private init() {}

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Loads external events. Strategy:
    /// 1) Try **direct Cloud Functions** (FeedsAPI) for both feeds.
    /// 2) If either fails, **fallback** to the Hosting proxy client (ExternalHTTP).
    func load(city: String?, start: Date?, end: Date?, completion: @escaping ([ExternalEvent]) -> Void) {
        // Always carry a city; endpoints behave better with it.
        let cityVal: String = {
            let v = (city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? "New York" : v
        }()

        let s = start ?? Date()
        let e = end ?? Calendar.current.date(byAdding: .day, value: 14, to: s) ?? Date().addingTimeInterval(14*86400)

        Task {
            // --- Path A: Direct Cloud Functions ---
            do {
                // First pass: require images
                async let tm: [ExternalFeedItem] = FeedsAPI.shared.fetch(.ticketmaster, city: cityVal, start: s, end: e, requireImage: true, imagesFirst: true)
                async let eb: [ExternalFeedItem] = FeedsAPI.shared.fetch(.eventbrite,   city: cityVal, start: s, end: e, requireImage: true, imagesFirst: true)
                var events = (try await tm + eb).map(ExternalEvent.init(from:))

                // Soft fallback: if strict image filter yields nothing, retry without the filter
                if events.isEmpty {
                    async let tm2: [ExternalFeedItem] = FeedsAPI.shared.fetch(.ticketmaster, city: cityVal, start: s, end: e, requireImage: false, imagesFirst: true)
                    async let eb2: [ExternalFeedItem] = FeedsAPI.shared.fetch(.eventbrite,   city: cityVal, start: s, end: e, requireImage: false, imagesFirst: true)
                    events = (try await tm2 + eb2).map(ExternalEvent.init(from:))
                }

                events = ExternalFeedsClient.dedupeAndSortImageFirst(events)
                await MainActor.run { completion(events) }
                return
            } catch {
                #if DEBUG
                print("ℹ️ Direct CF path failed, falling back to Hosting proxy: \(error)")
                #endif
            }

            // --- Path B: Hosting proxy /api fallback ---
            let group = DispatchGroup()
            var all: [ExternalEvent] = []

            func qItems(requireImage: Bool) -> [URLQueryItem] {
                return [
                    URLQueryItem(name: "city", value: cityVal),
                    URLQueryItem(name: "start", value: iso.string(from: s)),
                    URLQueryItem(name: "end",   value: iso.string(from: e)),
                    URLQueryItem(name: "requireImage", value: requireImage ? "1" : "0"),
                    URLQueryItem(name: "imagesFirst",  value: "1")
                ]
            }

            func fetch(_ path: String, requireImage: Bool) {
                group.enter()
                ExternalHTTP.shared.fetchEvents(path: path, query: qItems(requireImage: requireImage)) { result in
                    if case .success(let list) = result { all.append(contentsOf: list) }
                    group.leave()
                }
            }

            // First pass: image-only
            fetch("/feedTicketmaster", requireImage: true)
            fetch("/feedEventbrite",   requireImage: true)

            group.notify(queue: .main) {
                if all.isEmpty {
                    // Retry once without the strict image gate
                    let g2 = DispatchGroup()
                    var again: [ExternalEvent] = []
                    func f2(_ path: String) {
                        g2.enter()
                        ExternalHTTP.shared.fetchEvents(path: path, query: qItems(requireImage: false)) { result in
                            if case .success(let list) = result { again.append(contentsOf: list) }
                            g2.leave()
                        }
                    }
                    f2("/feedTicketmaster"); f2("/feedEventbrite")
                    g2.notify(queue: .main) {
                        completion(ExternalFeedsClient.dedupeAndSortImageFirst(again))
                    }
                } else {
                    completion(ExternalFeedsClient.dedupeAndSortImageFirst(all))
                }
            }
        }
    }


    private static func dedupeAndSortImageFirst(_ list: [ExternalEvent]) -> [ExternalEvent] {
        var seen = Set<String>()
        let deduped = list.filter { e in
            let k = "\(e.source ?? "")|\(e.id)|\(e.title)|\(Int(e.date.timeIntervalSince1970))"
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }
        return deduped.sortedImageFirstThenDate()
    }
}

// MARK: - Buy sheet

public struct BuyExternalEventSheet: View {
    public let event: ExternalEvent
    @Environment(\.dismiss) private var dismiss

    public init(event: ExternalEvent) { self.event = event }

    public var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let img = event.heroImage, let url = URL(string: img) {
                    AsyncImage(url: url) { i in
                        i.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(height: 180)
                    .clipped()
                    .cornerRadius(12)
                }

                Text(event.title)
                    .font(.title3).bold()

                Text(event.venueName + (cityFromAddress(event.address).map { " • \($0)" } ?? ""))
                    .foregroundColor(.secondary)

                if let p = event.ticketPrice {
                    Text("Tickets: " + priceString(p))
                        .font(.subheadline)
                }

                Spacer()

                Button {
                    guard let raw = URL(string: event.purchaseURL) else { return }
                    let final = affiliateURLWrapped(source: event.source ?? "", original: raw, subId: nil)
                    UIApplication.shared.open(final)
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Continue on \(event.source?.capitalized ?? "Site")")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.bottom)
            }
            .padding()
            .navigationBarItems(leading: Button("Close") { dismiss() })
        }
    }

    private func priceString(_ p: ExternalPrice) -> String {
        let min = p.min.map { "$\(Int($0))" } ?? "—"
        let max = p.max.map { "$\(Int($0))" }
        return max != nil ? "\(min)–\(max!)" : min
    }

    private func cityFromAddress(_ address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts.last
    }
}

// MARK: - Safari wrapper (renamed to avoid collisions elsewhere)

fileprivate struct ExternalSafariBridge: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Explorer UI (pulls from ExternalFeedsClient)

public struct ExternalEventsExplorerView: View {
    @State private var all: [ExternalEvent] = []
    @State private var filtered: [ExternalEvent] = []
    @State private var isLoading = true

    @State private var cityQuery = ""
    @State private var useDateFilter = false
    @State private var selectedDate = Date()

    @State private var showSafari = false
    @State private var safariURL: URL?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Search + date filters
                VStack(spacing: 8) {
                    HStack {
                        TextField("City / venue / event", text: $cityQuery)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: cityQuery) { _ in applyFilters() }
                    }
                    HStack(spacing: 12) {
                        Toggle(isOn: $useDateFilter) { Label("Filter by date", systemImage: "calendar") }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!useDateFilter)
                            .opacity(useDateFilter ? 1 : 0.4)
                            .onChange(of: selectedDate) { _ in if useDateFilter { applyFilters() } }
                        Spacer()
                        Button("Reset") { resetFilters() }.font(.footnote)
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if isLoading {
                    ProgressView("Loading…").padding(.top, 24)
                } else if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Text("No external events match your filters").foregroundColor(.secondary)
                        Button("Reset Filters") { resetFilters() }
                    }
                    .padding(.top, 24)
                } else {
                    List(filtered, id: \.id) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                if let src = e.heroImage, let url = URL(string: src) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .empty: Color.gray.opacity(0.15)
                                        case .success(let img): img.resizable().scaledToFill()
                                        case .failure: Color.gray.opacity(0.15)
                                        @unknown default: Color.gray.opacity(0.15)
                                        }
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(e.title).font(.headline).lineLimit(2)
                                    Text("\(e.venueName)\(e.venueName.isEmpty ? "" : " • ")\(e.address)")
                                        .font(.subheadline).foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 8)
                            }

                            HStack {
                                if let p = e.price { Text(String(format: "$%.0f", p)) }
                                if let s = e.source { Text(s.capitalized).foregroundColor(.secondary) }
                                Spacer()
                                if let u = e.externalURL, let url = URL(string: u) {
                                    Button("View") { safariURL = url; showSafari = true }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 6)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Explore Events")
            .onAppear { initialLoad() }
            .sheet(isPresented: $showSafari) {
                if let url = safariURL { ExternalSafariBridge(url: url) }
            }
        }
    }

    private func initialLoad() {
        isLoading = true
        ExternalFeedsClient.shared.load(
            city: "New York", // ensure the endpoints get a city immediately
            start: Date(),
            end: Calendar.current.date(byAdding: .day, value: 30, to: Date())
        ) { list in
            self.all = list
            self.applyFilters()
            self.isLoading = false
        }
    }

    private func resetFilters() {
        cityQuery = ""
        useDateFilter = false
        selectedDate = Date()
        applyFilters()
    }

    private func applyFilters() {
        var out = all

        let q = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            out = out.filter { e in
                e.address.localizedCaseInsensitiveContains(q) ||
                e.venueName.localizedCaseInsensitiveContains(q) ||
                e.title.localizedCaseInsensitiveContains(q)
            }
        }

        if useDateFilter {
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: selectedDate)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
            out = out.filter { $0.date >= dayStart && $0.date < dayEnd }
        }

        // 👇 Image-first sort here as well for a consistent, visually-appealing feed
        filtered = out.sortedImageFirstThenDate()
    }
}
