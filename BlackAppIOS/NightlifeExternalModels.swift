//
//  NightlifeExternalModels.swift
//  BlackAppIOS
//

import Foundation
import SwiftUI
import SafariServices
import FirebaseDatabase

// MARK: - Small logging helpers

@inline(__always)
func NLLog(_ msg: @autoclosure () -> String) {
#if DEBUG
    print(msg())
#endif
}

@inline(__always)
func bodyPreview(_ data: Data, max: Int = 600) -> String {
    guard !data.isEmpty else { return "∅" }
    let s = String(decoding: data, as: UTF8.self)
    if s.count <= max { return s }
    return String(s.prefix(max)) + "…(\(s.count - max) more)"
}

/// If a function responses wraps JSON with any debug text, attempt to recover.
/// This is conservative; if it can't find an array/object start, returns original.
@inline(__always)
func stripDebugEnvelope(_ data: Data) -> Data {
    guard let s = String(data: data, encoding: .utf8) else { return data }
    if let i = s.firstIndex(where: { $0 == "[" || $0 == "{" }) {
        let trimmed = String(s[i...])
        return trimmed.data(using: .utf8) ?? data
    }
    return data
}

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

// MARK: - ExternalFeedItem (network DTO; accepts heroImage OR imageURL)

public struct ExternalFeedItem: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let venueName: String
    public let address: String
    public let date: String                // ISO-8601 "Z" string from the server
    public let price: Double?
    public let externalURL: String?
    public let source: String              // "ticketmaster" | "eventbrite"
    public let heroImage: String?          // primary field
    public let imageURL: String?           // alias/back-compat

    enum CodingKeys: String, CodingKey {
        case id, title, venueName, address, date, price, externalURL, source, heroImage, imageURL
        case image = "image"
        case imageUrl = "imageUrl"
        case thumbnail = "thumbnail"
        case poster = "poster"
        case flyer = "flyer"
    }

    public init(id: String, title: String, venueName: String, address: String, date: String, price: Double?, externalURL: String?, source: String, heroImage: String?, imageURL: String?) {
        self.id = id
        self.title = title
        self.venueName = venueName
        self.address = address
        self.date = date
        self.price = price
        self.externalURL = externalURL
        self.source = source
        self.heroImage = heroImage
        self.imageURL = imageURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = (try? c.decode(String.self, forKey: .title)) ?? "Event"
        self.venueName = (try? c.decode(String.self, forKey: .venueName)) ?? ""
        self.address = (try? c.decode(String.self, forKey: .address)) ?? ""
        self.date = (try? c.decode(String.self, forKey: .date)) ?? ISO8601DateFormatter().string(from: Date())
        self.price = try? c.decode(Double.self, forKey: .price)
        self.externalURL = (try? c.decode(String.self, forKey: .externalURL))
        self.source = (try? c.decode(String.self, forKey: .source)) ?? ""

        let heroRaw = try? c.decode(String.self, forKey: .heroImage)

        var imgURLRaw: String? = nil
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .imageURL) }
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .image) }
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .imageUrl) }
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .thumbnail) }
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .poster) }
        if imgURLRaw == nil { imgURLRaw = try? c.decode(String.self, forKey: .flyer) }

        func https(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            if s.hasPrefix("http:") { return "https:" + s.dropFirst(5) }
            return s
        }

        self.heroImage = https(heroRaw)
        self.imageURL  = https(imgURLRaw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(venueName, forKey: .venueName)
        try c.encode(address, forKey: .address)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(price, forKey: .price)
        try c.encodeIfPresent(externalURL, forKey: .externalURL)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(heroImage, forKey: .heroImage)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
    }
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

    // Convert from network DTO — prefers heroImage then imageURL
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
            heroImage: item.heroImage ?? item.imageURL
        )
    }

    // Flexible Decodable for legacy payloads — UPDATED
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
                    let sanitized = s
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let dateSeconds = dbl(["date","startTime","start","timestamp","start_ts","startMillis"])
        let dateString = str(["date","startTime","start","timestamp","isoDate","when","startISO"])

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

        // break up long alias chain for the type-checker
        var heroVal: String? = str(["heroImage"])
        if heroVal == nil { heroVal = str(["image"]) }
        if heroVal == nil { heroVal = str(["imageUrl"]) }
        if heroVal == nil { heroVal = str(["imageURL"]) }
        if heroVal == nil { heroVal = str(["thumbnail"]) }
        if heroVal == nil { heroVal = str(["poster"]) }
        if heroVal == nil { heroVal = str(["flyer"]) }

        let priceVal = dbl(["price","ticketPrice","minPrice","lowestPrice"])
        let urlVal = str(["url","externalURL","link","purchaseUrl","purchaseURL"])
        let sourceVal = str(["source","provider"])

        func https(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            if s.hasPrefix("http:") { return "https:" + s.dropFirst(5) }
            return s
        }

        self.init(
            id: fallbackId,
            title: t,
            venueName: vn,
            address: addr,
            date: parsedDate,
            price: priceVal,
            externalURL: urlVal,
            source: sourceVal,
            heroImage: https(heroVal)
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

        var heroVal: String? =
            (v["heroImage"] as? String) ??
            (v["image"] as? String) ??
            (v["imageUrl"] as? String) ??
            (v["imageURL"] as? String) ??
            (v["thumbnail"] as? String) ??
            (v["poster"] as? String) ??
            (v["flyer"] as? String)

        if let hv = heroVal, hv.hasPrefix("http:") {
            heroVal = "https:" + hv.dropFirst(5)
        }

        return ExternalEvent(
            id: id,
            title: title,
            venueName: venueName,
            address: address,
            date: date,
            price: price,
            externalURL: externalURL,
            source: source,
            heroImage: heroVal
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

    static func extractCity(from address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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

// MARK: - Image-first sort helper (for internal use)

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

// MARK: - RTDB fallback (top-level; no NightlifeService dependency)

public func fetchExternalEventsMergedFallback(
    paths: [String] = ["externalEvents", "external/events", "feeds/external/events"],
    completion: @escaping ([ExternalEvent]) -> Void
) {
    let db = Database.database().reference()
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
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
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
        timeout: TimeInterval = 25,
        debug: Bool = false
    ) async throws -> [ExternalFeedItem] {
        var comps = URLComponents(
            url: base.appendingPathComponent(endpoint.rawValue),
            resolvingAgainstBaseURL: false
        )!

        let cityParam = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [URLQueryItem] = [
            URLQueryItem(name: "city", value: cityParam.isEmpty ? "New York" : cityParam),
            URLQueryItem(name: "start", value: FeedsAPI.iso8601Z(start)),
            URLQueryItem(name: "end",   value: FeedsAPI.iso8601Z(end)),
            URLQueryItem(name: "requireImage", value: requireImage ? "1" : "0"),
            URLQueryItem(name: "imagesFirst",  value: imagesFirst  ? "1" : "0"),
            URLQueryItem(name: "debug", value: debug ? "1" : "0")
        ]
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = max(30, timeout)
        req.setValue("application/json, text/plain; q=0.8, */*; q=0.1", forHTTPHeaderField: "Accept")
        req.setValue("utf-8", forHTTPHeaderField: "Accept-Charset")
        // Do NOT set "Connection: close"—causes HTTP/3 parser weirdness.

        NLLog("🔎 [CF:\(endpoint.rawValue)] → \(req.url?.absoluteString ?? "")")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            let status = http.statusCode
            let ct     = http.value(forHTTPHeaderField: "Content-Type") ?? "(nil)"
            let enc    = http.value(forHTTPHeaderField: "Content-Encoding") ?? "none"
            let clen   = http.value(forHTTPHeaderField: "Content-Length") ?? "\(data.count)"

            NLLog("🧾 [CF:\(endpoint.rawValue)] status=\(status) ct=\(ct) enc=\(enc) len=\(clen) bytes(rcv=\(data.count))")
            #if DEBUG
            NLLog("📦 [CF:\(endpoint.rawValue)] body preview:\n\(bodyPreview(data))")
            #endif

            // Non-2xx → allow fallback
            guard (200..<300).contains(status) else {
                NLLog("🟥 [CF:\(endpoint.rawValue)] non-2xx → returning []")
                return []
            }

            // Hosting sometimes returns HTML even with 200.
            if ct.lowercased().contains("text/html") {
                NLLog("🟨 [CF:\(endpoint.rawValue)] got HTML instead of JSON → returning []")
                return []
            }

            // Try decode; if fails, try after stripping any debug envelope.
            do {
                return try JSONDecoder().decode([ExternalFeedItem].self, from: data)
            } catch {
                NLLog("🟨 [CF:\(endpoint.rawValue)] JSON decode failed, attempting to strip envelope…")
                let pruned = stripDebugEnvelope(data)
                return try JSONDecoder().decode([ExternalFeedItem].self, from: pruned)
            }
        } catch {
            let ns = error as NSError
            NLLog("🧨 [CF:\(endpoint.rawValue)] network error domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case -1017:
                    NLLog("ℹ️ NSURLErrorCannotParseResponse (-1017). Often a proxy/transport mismatch or unexpected body.")
                case -1005:
                    NLLog("ℹ️ NSURLErrorNetworkConnectionLost (-1005). QUIC/HTTP3 path flakiness; retry/fallback.")
                default: break
                }
            }
            throw error
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

// B) Hosting proxy /api fallback HTTP client

fileprivate enum ExternalAPI {
    static let functionsBase = "https://us-central1-blackappios.cloudfunctions.net"
    static let hostingBase   = "https://blackappios.web.app/api"
    static let hostingAlt    = "https://blackappios.firebaseapp.com/api"
}

fileprivate final class ExternalHTTP {
    static let shared = ExternalHTTP()
    private init() {}

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 35
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.httpAdditionalHeaders = ["Accept": "application/json", "Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: cfg)
    }()

    struct HTTPError: Error, CustomStringConvertible {
        let status: Int
        let bodySnippet: String
        var description: String { "HTTP \(status) \(bodySnippet)" }
    }

    func fetchEvents(path: String, query: [URLQueryItem], completion: @escaping (Result<[ExternalEvent], Error>) -> Void) {
        let bases = [ExternalAPI.functionsBase, ExternalAPI.hostingBase, ExternalAPI.hostingAlt]

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

            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let task = session.dataTask(with: req) { data, resp, _ in
                guard let http = resp as? HTTPURLResponse, let data = data else {
                    attempt(index: index + 1, retry: 0); return
                }

                if let ct = http.value(forHTTPHeaderField: "Content-Type"),
                   ct.lowercased().contains("text/html") {
                    attempt(index: index + 1, retry: 0)
                    return
                }

                do {
                    let list = try JSONDecoder().decode([ExternalFeedItem].self, from: data)
                    completion(.success(list.map(ExternalEvent.init(from:))))
                    return
                } catch {
                    if !(200..<300).contains(http.statusCode) {
                        attempt(index: index + 1, retry: 0)
                        return
                    }
                    attempt(index: index + 1, retry: 0)
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

    func load(city: String?, start: Date?, end: Date?, completion: @escaping ([ExternalEvent]) -> Void) {
        let cityVal: String = {
            let v = (city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? "New York" : v
        }()

        let s = start ?? Date()
        let e = end ?? Calendar.current.date(byAdding: .day, value: 14, to: s) ?? Date().addingTimeInterval(14*86400)

        Task {
            // --- Path A: Direct Cloud Functions ---
            do {
                async let tm: [ExternalFeedItem] = FeedsAPI.shared.fetch(.ticketmaster, city: cityVal, start: s, end: e, requireImage: true, imagesFirst: true)
                async let eb: [ExternalFeedItem] = FeedsAPI.shared.fetch(.eventbrite,   city: cityVal, start: s, end: e, requireImage: true, imagesFirst: true)
                var events = (try await tm + eb).map(ExternalEvent.init(from:))

                if events.isEmpty {
                    async let tm2: [ExternalFeedItem] = FeedsAPI.shared.fetch(.ticketmaster, city: cityVal, start: s, end: e, requireImage: false, imagesFirst: true)
                    async let eb2: [ExternalFeedItem] = FeedsAPI.shared.fetch(.eventbrite,   city: cityVal, start: s, end: e, requireImage: false, imagesFirst: true)
                    events = (try await tm2 + eb2).map(ExternalEvent.init(from:))
                }

                let final = ExternalFeedsClient.dedupeAndSortImageFirst(events)
                DispatchQueue.main.async { completion(final) }
                return
            } catch {
                #if DEBUG
                print("ℹ️ Direct CF path failed, will try Hosting proxy: \(error)")
                #endif
            }

            // --- Path B: Hosting proxy /api fallback ---
            let group = DispatchGroup()
            var all: [ExternalEvent] = []
            let lock = NSLock()

            func qItems(requireImage: Bool) -> [URLQueryItem] {
                [
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
                    if case .success(let list) = result {
                        lock.lock(); all.append(contentsOf: list); lock.unlock()
                    }
                    group.leave()
                }
            }

            // Pass 1: require images
            fetch("/feedTicketmaster", requireImage: true)
            fetch("/feedEventbrite",   requireImage: true)

            group.notify(queue: .global()) {
                if all.isEmpty {
                    // Pass 2: allow entries without images
                    let g2 = DispatchGroup()
                    var again: [ExternalEvent] = []
                    let lock2 = NSLock()

                    func f2(_ path: String) {
                        g2.enter()
                        ExternalHTTP.shared.fetchEvents(path: path, query: qItems(requireImage: false)) { result in
                            if case .success(let list) = result {
                                lock2.lock(); again.append(contentsOf: list); lock2.unlock()
                            }
                            g2.leave()
                        }
                    }

                    f2("/feedTicketmaster"); f2("/feedEventbrite")

                    g2.notify(queue: .main) {
                        let merged = again
                        if merged.isEmpty {
                            // --- Path C: RTDB fallback
                            fetchExternalEventsMergedFallback { mergedRTDB in
                                let final = ExternalFeedsClient.dedupeAndSortImageFirst(mergedRTDB)
                                completion(final)
                            }
                        } else {
                            completion(ExternalFeedsClient.dedupeAndSortImageFirst(merged))
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(ExternalFeedsClient.dedupeAndSortImageFirst(all))
                    }
                }
            }
        }
    }

    /// Prefer events that have a hero image, then sort by date; also de-dupes by (id|title|date)
    static func dedupeAndSortImageFirst(_ list: [ExternalEvent]) -> [ExternalEvent] {
        var seen = Set<String>()
        let deduped = list.filter { e in
            let k = "\(e.id)|\(e.title)|\(Int(e.date.timeIntervalSince1970))"
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }
        return deduped.sorted { a, b in
            let aHas = !(a.heroImage?.isEmpty ?? true)
            let bHas = !(b.heroImage?.isEmpty ?? true)
            if aHas != bHas { return aHas && !bHas } // photos first
            return a.date < b.date
        }
    }
}

// MARK: - Client-side image enrichment (OpenGraph/Twitter) + cache

final class OGImageCache {
    static let shared = OGImageCache()
    private var mem: [String: String] = [:]
    private let lock = NSLock()

    func get(_ url: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return mem[url]
    }
    func set(_ url: String, image: String) {
        guard !image.isEmpty else { return }
        lock.lock(); mem[url] = image; lock.unlock()
    }
}

func fetchOGImageIfNeeded(for event: ExternalEvent, completion: @escaping (String?) -> Void) {
    guard event.heroImage == nil,
          let link = event.externalURL,
          OGImageCache.shared.get(link) == nil,
          let url = URL(string: link) else { completion(nil); return }

    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")

    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard let data = data, !data.isEmpty,
              let html = String(data: data, encoding: .utf8) else { completion(nil); return }

        func meta(_ name: String) -> String? {
            let pattern = "<meta[^>]+(?:property|name)=[\"']\(name)[\"'][^>]+content=[\"']([^\"']+)[\"']"
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            guard let m = r.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
            guard let gr = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[gr])
        }

        let found = meta("og:image") ?? meta("twitter:image") ?? meta("twitter:image:src")
        if let img = found, img.lowercased().hasPrefix("http") {
            OGImageCache.shared.set(link, image: img)
            completion(img)
        } else {
            completion(nil)
        }
    }.resume()
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

// MARK: - Flyer-first explorer (grid by default)

public struct ExternalEventsExplorerView: View {
    enum LayoutMode: String, CaseIterable, Identifiable { case flyers = "Flyers", list = "List"; var id: String { rawValue } }

    @State private var all: [ExternalEvent] = []
    @State private var filtered: [ExternalEvent] = []
    @State private var isLoading = true

    @State private var query = ""
    @State private var useDateFilter = false
    @State private var selectedDate = Date()
    @State private var onlyWithPhotos = true   // default to photos-first
    @State private var layout: LayoutMode = .flyers

    @State private var showSafari = false
    @State private var safariURL: URL?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Filters
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Search city / venue / event", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: query) { _ in applyFilters() }

                        Picker("", selection: $layout) {
                            ForEach(LayoutMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }

                    HStack(spacing: 12) {
                        Toggle(isOn: $useDateFilter) { Label("Date", systemImage: "calendar") }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!useDateFilter)
                            .opacity(useDateFilter ? 1 : 0.4)
                            .onChange(of: selectedDate) { _ in if useDateFilter { applyFilters() } }

                        Toggle("Photos only", isOn: $onlyWithPhotos)
                            .onChange(of: onlyWithPhotos) { _ in applyFilters() }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

                        Spacer()
                        Button("Reset") { resetFilters() }
                            .font(.footnote)
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
                        Text("No events match your filters").foregroundColor(.secondary)
                        Button("Reset Filters") { resetFilters() }
                    }
                    .padding(.top, 24)
                } else {
                    ScrollView {
                        if layout == .flyers {
                            // 2-column flyer grid
                            let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                            LazyVGrid(columns: cols, spacing: 10) {
                                ForEach(filtered, id: \.id) { e in
                                    FlyerTile(e: e) {
                                        if let u = e.externalURL, let url = URL(string: u) {
                                            safariURL = url
                                            showSafari = true
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 6)
                            .padding(.bottom, 12)
                        } else {
                            // Compact list (thumb + text)
                            LazyVStack(spacing: 12) {
                                ForEach(filtered, id: \.id) { e in
                                    ExternalEventSearchRow(e: e) {
                                        if let u = e.externalURL, let url = URL(string: u) {
                                            safariURL = url
                                            showSafari = true
                                        }
                                    }
                                    Divider().background(Color(.separator))
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                        }
                    }
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
            city: "New York",
            start: Date(),
            end: Calendar.current.date(byAdding: .day, value: 30, to: Date())
        ) { list in
            self.all = list
            self.applyFilters()
            self.isLoading = false
        }
    }

    private func resetFilters() {
        query = ""
        useDateFilter = false
        onlyWithPhotos = true
        selectedDate = Date()
        applyFilters()
    }

    private func applyFilters() {
        var out = all

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
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

        var filteredOut = out
        if onlyWithPhotos {
            filteredOut = out.filter { !($0.heroImage?.isEmpty ?? true) }
            // Auto-relax if that killed everything but there *are* events
            if filteredOut.isEmpty, !out.isEmpty {
                onlyWithPhotos = false
                filteredOut = out
            }
        }

        filtered = ExternalFeedsClient.dedupeAndSortImageFirst(filteredOut)
    }
}

// MARK: - Flyer tile (grid cell) with OG image enrichment & placeholder

fileprivate struct FlyerTile: View {
    let e: ExternalEvent
    var onTap: () -> Void
    @State private var resolvedImage: String?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let hero = resolvedImage ?? e.heroImage, let url = URL(string: hero) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                        switch phase {
                        case .empty:
                            Color.gray.opacity(0.18).overlay(ProgressView())
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        case .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }

                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.title)
                        .font(.subheadline).bold()
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(radius: 2)

                    Text(shortMeta)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(10)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onAppear {
            guard resolvedImage == nil else { return }
            fetchOGImageIfNeeded(for: e) { img in
                if let img { DispatchQueue.main.async { resolvedImage = img } }
            }
        }
    }

    private var shortMeta: String {
        let city = cityFromAddress(e.address) ?? ""
        let when = e.date.formatted(date: .abbreviated, time: .shortened)
        let venue = e.venueName.isEmpty ? "" : e.venueName
        return [venue, city, when].filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private var placeholder: some View {
        LinearGradient(colors: [.gray.opacity(0.25), .gray.opacity(0.35)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "ticket")
                        Text(e.source?.capitalized ?? "Event").bold()
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())

                    Spacer(minLength: 0)

                    Text(e.title).font(.headline).foregroundColor(.white).lineLimit(2)
                    Text(shortMeta).font(.caption).foregroundColor(.white.opacity(0.9)).lineLimit(1)
                }
                .padding(10),
                alignment: .bottomLeading
            )
    }

    private func cityFromAddress(_ address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts.last
    }
}

// MARK: - Compact list row (thumb + text) with OG fallback

fileprivate struct ExternalEventSearchRow: View {
    let e: ExternalEvent
    var onTap: () -> Void
    @State private var resolvedImage: String?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    if let hero = resolvedImage ?? e.heroImage, let url = URL(string: hero) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty: Color.gray.opacity(0.2).overlay(ProgressView())
                            case .success(let image): image.resizable().scaledToFill()
                            case .failure: thumbPlaceholder
                            @unknown default: thumbPlaceholder
                            }
                        }
                    } else {
                        thumbPlaceholder
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(e.title).font(.headline).lineLimit(2)
                    Text("\(e.venueName)\(e.venueName.isEmpty ? "" : " • ")\(cityFromAddress(e.address) ?? "")")
                        .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundColor(.secondary)
                        if let p = e.price {
                            Text(String(format: "$%.0f", p)).font(.caption).bold()
                        }
                        Spacer()
                        if let s = e.source {
                            Text(s.capitalized).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            guard resolvedImage == nil else { return }
            fetchOGImageIfNeeded(for: e) { img in
                if let img { DispatchQueue.main.async { resolvedImage = img } }
            }
        }
    }

    private var thumbPlaceholder: some View {
        Color.gray.opacity(0.2)
            .overlay(Image(systemName: "photo").foregroundColor(.white.opacity(0.7)))
    }

    private func cityFromAddress(_ address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts.last
    }
}

// MARK: - Full-width banner row (optional)

fileprivate struct EventBannerRow: View {
    let e: ExternalEvent
    var onTap: () -> Void
    @State private var resolvedImage: String?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    if let hero = resolvedImage ?? e.heroImage, let url = URL(string: hero) {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                            switch phase {
                            case .empty:
                                Color.gray.opacity(0.2).overlay(ProgressView())
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .transition(.opacity)
                            case .failure:
                                Color.gray.opacity(0.2)
                            @unknown default:
                                Color.gray.opacity(0.2)
                            }
                        }
                    } else {
                        Color.gray.opacity(0.2)
                    }

                    LinearGradient(
                        colors: [.black.opacity(0.0), .black.opacity(0.65)],
                        startPoint: .center, endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.title)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 2)

                        Text("\(e.venueName)\(e.venueName.isEmpty ? "" : " • ")\(cityFromAddress(e.address) ?? "")")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)

                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(12)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 8) {
                    if let p = e.price {
                        Text(String(format: "$%.0f", p))
                            .font(.subheadline).bold()
                    }
                    Spacer()
                    if let s = e.source {
                        Text(s.capitalized)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            guard resolvedImage == nil else { return }
            fetchOGImageIfNeeded(for: e) { img in
                if let img { DispatchQueue.main.async { resolvedImage = img } }
            }
        }
    }

    private func cityFromAddress(_ address: String?) -> String? {
        guard let address = address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2 { return parts[parts.count - 2] }
        return parts.last
    }
}
