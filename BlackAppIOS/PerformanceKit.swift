//
//  PerformanceKit.swift
//  BlackAppIOS
//
//  Phase 1: Pagination + Caching + StorageURL resolver
//

import Foundation
import SwiftUI
import FirebaseDatabase
import FirebaseStorage
import UIKit

// MARK: - 0) App-wide URLCache boost (call once at app start)
public enum PerfBootstrap {
    public static func installURLCache(
        memMB: Int = 64,
        diskMB: Int = 256
    ) {
        let cache = URLCache(
            memoryCapacity: memMB * 1024 * 1024,
            diskCapacity: diskMB * 1024 * 1024,
            diskPath: "net-cache"
        )
        URLCache.shared = cache
    }
}

// MARK: - 1) In-flight de-dupe for concurrent requests
final class InflightMap<Key: Hashable, Value> {
    private var store: [Key: [(Value) -> Void]] = [:]
    private let lock = NSLock()
    func enqueue(_ key: Key, complete: @escaping (Value) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let existed = store[key] != nil
        store[key, default: []].append(complete)
        return existed
    }
    func resolve(_ key: Key, with value: Value) {
        lock.lock(); let cbs = store.removeValue(forKey: key); lock.unlock()
        cbs?.forEach { $0(value) }
    }
}

// MARK: - 2) Tiny JSON cache with TTL (disk + mem)
final class JSONCache {
    static let shared = JSONCache()
    private let mem = NSCache<NSString, NSData>()
    private let fm = FileManager.default
    private let ioQ = DispatchQueue(label: "json.cache.io")

    private func fileURL(for key: String) -> URL {
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("json-\(key.hashValue).bin")
    }

    // Make T: Codable for both read and write to satisfy Box<T: Codable>
    func read<T: Codable>(_ key: String, type: T.Type, maxAge: TimeInterval) -> T? {
        if let d = mem.object(forKey: key as NSString) as Data?,
           let box = try? JSONDecoder().decode(Box<T>.self, from: d),
           Date().timeIntervalSince1970 - box.storedAt < maxAge {
            return box.value
        }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Box<T>.self, from: data),
              Date().timeIntervalSince1970 - box.storedAt < maxAge else { return nil }
        mem.setObject(data as NSData, forKey: key as NSString)
        return box.value
    }

    func write<T: Codable>(_ key: String, value: T) {
        ioQ.async {
            let box = Box(value: value, storedAt: Date().timeIntervalSince1970)
            guard let data = try? JSONEncoder().encode(box) else { return }
            self.mem.setObject(data as NSData, forKey: key as NSString)
            try? data.write(to: self.fileURL(for: key), options: .atomic)
        }
    }

    private struct Box<T: Codable>: Codable {
        let value: T
        let storedAt: TimeInterval
    }
}


// MARK: - 3) Firebase Storage downloadURL resolver with caching
final class StorageURLResolver {
    static let shared = StorageURLResolver()
    private let mem = NSCache<NSString, NSString>()
    private let inflight = InflightMap<String, URL?>()
    private let disk = JSONCache.shared

    func url(forPath path: String, completion: @escaping (URL?) -> Void) {
        // 1) memory
        if let s = mem.object(forKey: path as NSString) as String? {
            completion(URL(string: s)); return
        }
        // 2) disk
        if let s: String = disk.read("dl-\(path)", type: String.self, maxAge: 24*3600) {
            mem.setObject(s as NSString, forKey: path as NSString)
            completion(URL(string: s)); return
        }
        // 3) coalesce inflight
        if inflight.enqueue(path, complete: completion) { return }
        // 4) fetch
        let ref = Storage.storage().reference(withPath: path)
        ref.downloadURL { [weak self] url, _ in
            guard let self else { self?.inflight.resolve(path, with: nil); return }
            if let u = url?.absoluteString {
                self.mem.setObject(u as NSString, forKey: path as NSString)
                self.disk.write("dl-\(path)", value: u)
            }
            self.inflight.resolve(path, with: url)
        }
    }
}

// MARK: - 4) Image loader (disk+mem) using URLCache for network
final class ImageStore {
    static let shared = ImageStore()
    private let mem = NSCache<NSString, UIImage>()
    private let fm = FileManager.default
    private let ioQ = DispatchQueue(label: "img.disk.io")

    func image(forKey key: String) -> UIImage? { mem.object(forKey: key as NSString) }

    func load(from url: URL, key: String, completion: @escaping (UIImage?) -> Void) {
        if let img = mem.object(forKey: key as NSString) { completion(img); return }
        let path = cachePath(for: key)
        ioQ.async {
            if let data = try? Data(contentsOf: path), let img = UIImage(data: data) {
                self.mem.setObject(img, forKey: key as NSString)
                return DispatchQueue.main.async { completion(img) }
            }
            let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let img = UIImage(data: data) else {
                    return DispatchQueue.main.async { completion(nil) }
                }
                self.mem.setObject(img, forKey: key as NSString)
                self.ioQ.async { try? data.write(to: path, options: .atomic) }
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }
    }

    private func cachePath(for key: String) -> URL {
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("img-\(key.hashValue).bin")
    }
}

// MARK: - 5) SwiftUI view that resolves Storage path -> URL -> image (non-blocking)
public struct CachedStorageImage: View {
    let storagePath: String
    let contentMode: ContentMode

    @State private var uiImage: UIImage?
    @State private var resolvedURL: URL?

    public init(path: String, contentMode: ContentMode = .fill) {
        self.storagePath = path
        self.contentMode = contentMode
    }

    public var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay(ProgressView().progressViewStyle(.circular))
            }
        }
        .task(id: storagePath) {
            // resolve downloadURL once (mem/disk cache makes this cheap)
            StorageURLResolver.shared.url(forPath: storagePath) { url in
                guard let url else { return }
                resolvedURL = url
                ImageStore.shared.load(from: url, key: storagePath) { img in
                    withAnimation(.easeOut(duration: 0.15)) { uiImage = img }
                }
            }
        }
    }
}

// MARK: - 6) Generic RTDB paginator (order by child, descending or ascending)
public struct Page<T> { public let items: [T]; public let nextCursor: Double? }

public final class RTDBPaginator<T> {
    public typealias Mapper = (DataSnapshot) -> T?
    private let ref: DatabaseReference
    private let orderKey: String
    private let pageSize: UInt
    private let map: Mapper
    private let descending: Bool

    public init(path: String,
                orderBy orderKey: String = "timestamp",
                pageSize: UInt = 20,
                descending: Bool = true,
                mapper: @escaping Mapper) {
        self.ref = Database.database().reference(withPath: path)
        self.orderKey = orderKey
        self.pageSize = pageSize
        self.map = mapper
        self.descending = descending
    }

    // cursor = timestamp boundary; for descending, we use queryEnding(atValue: cursor - ε)
    public func fetchPage(after cursor: Double?, completion: @escaping (Page<T>) -> Void) {
        var q = ref.queryOrdered(byChild: orderKey)
        if descending {
            if let c = cursor {
                q = q.queryEnding(atValue: c - 0.000001)
            }
            q = q.queryLimited(toLast: pageSize)
        } else {
            if let c = cursor {
                q = q.queryStarting(atValue: c + 0.000001)
            }
            q = q.queryLimited(toFirst: pageSize)
        }
        q.observeSingleEvent(of: .value) { snap in
            var arr: [(Double, T)] = []
            for case let child as DataSnapshot in snap.children {
                guard let dict = child.value as? [String: Any],
                      let ts = dict[self.orderKey] as? Double,
                      let mapped = self.map(child) else { continue }
                arr.append((ts, mapped))
            }
            if self.descending { arr.sort { $0.0 > $1.0 } }
            let items = arr.map { $0.1 }
            let nextCur = arr.last?.0
            completion(Page(items: items, nextCursor: nextCur))
        }
    }
}
