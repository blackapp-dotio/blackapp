import SwiftUI
import UIKit
import LinkPresentation
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import MobileCoreServices   // If you prefer UTType, see note at bottom.

// MARK: - Gossip DB model
struct GossipPost: Identifiable, Codable {
    var id: String = UUID().uuidString
    var authorId: String
    var createdAt: TimeInterval
    var text: String
    var linkURL: String?
    var previewTitle: String?
    var previewSubtitle: String?
    var previewImageURL: String?
    var previewResolvedURL: String?
    var eventId: String?
    var nightId: String?
    var venueId: String?
    var flyerURL: String?
    var status: String = "active"
}

// MARK: - NightlifeService minimal shim (reuse your existing singleton if file is separate)
final class NightlifeServiceBridge {
    static let shared = NightlifeServiceBridge()
    private init() {}
    var db: DatabaseReference { Database.database().reference() }

    func postToGossip(_ post: GossipPost, completion: @escaping (Error?) -> Void) {
        let ref = db.child("gossipPosts").childByAutoId()
        var enc: [String: Any] = [
            "authorId": post.authorId,
            "createdAt": post.createdAt,
            "text": post.text,
            "status": post.status
        ]
        if let s = post.linkURL { enc["linkURL"] = s }
        if let s = post.previewTitle { enc["previewTitle"] = s }
        if let s = post.previewSubtitle { enc["previewSubtitle"] = s }
        if let s = post.previewImageURL { enc["previewImageURL"] = s }
        if let s = post.previewResolvedURL { enc["previewResolvedURL"] = s }
        if let s = post.eventId { enc["eventId"] = s }
        if let s = post.nightId { enc["nightId"] = s }
        if let s = post.venueId { enc["venueId"] = s }
        if let s = post.flyerURL { enc["flyerURL"] = s }

        ref.setValue(enc) { err, _ in completion(err) }
    }
}

// MARK: - Link preview result + resolver
struct ResolvedLink {
    var url: URL
    var title: String?
    var subtitle: String?     // host (fallback)
    var imageURL: URL?
    var canonicalURL: URL?
}

final class LinkPreviewResolver {
    static let shared = LinkPreviewResolver()
    private let provider = LPMetadataProvider()

    func resolve(_ url: URL, completion: @escaping (ResolvedLink?) -> Void) {
        provider.startFetchingMetadata(for: url) { metadata, err in
            if let err = err { print("LP resolve error:", err.localizedDescription); return completion(nil) }
            guard let md = metadata else { return completion(nil) }

            // iOS does not expose `siteName`; fallback to host from md.url/originalURL
            let host = (md.url ?? md.originalURL)?.host

            func finish(imageURL: URL?) {
                DispatchQueue.main.async {
                    completion(
                        ResolvedLink(
                            url: url,
                            title: md.title,
                            subtitle: host,
                            imageURL: imageURL,
                            canonicalURL: md.url ?? md.originalURL
                        )
                    )
                }
            }

            if let provider = md.imageProvider {
                provider.loadItem(forTypeIdentifier: kUTTypeURL as String, options: nil) { item, _ in
                    if let u = item as? URL { finish(imageURL: u); return }
                    provider.loadItem(forTypeIdentifier: kUTTypeData as String, options: nil) { data, _ in
                        if let d = data as? Data, let ui = UIImage(data: d),
                           let jpg = ui.jpegData(compressionQuality: 0.9) {
                            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("lp_\(UUID().uuidString).jpg")
                            try? jpg.write(to: tmp)
                            finish(imageURL: tmp)
                        } else {
                            finish(imageURL: nil)
                        }
                    }
                }
            } else {
                finish(imageURL: nil)
            }
        }
    }
}

// MARK: - Generic share payload you can use app-wide
enum GossipSharePayload {
    case event(night: NightModel, flyerURL: URL? = nil, deepLink: URL? = nil)
    case link(url: URL, text: String? = nil)
    case text(String)
    case media(image: UIImage, text: String? = nil)

    var defaultText: String {
        switch self {
        case .event(let night, _, _):
            return "\(night.title) • \(DateFormatter.shortDate.string(from: night.date))"
        case .link(_, let text): return text ?? ""
        case .text(let t): return t
        case .media(_, let text): return text ?? ""
        }
    }
}

// MARK: - Pretty preview card (used by composer)
struct GossipLinkPreviewCard: View {
    let resolved: ResolvedLink
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let u = resolved.imageURL {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() }
                placeholder: { Color.gray.opacity(0.12) }
                .frame(height: 150).clipped().cornerRadius(10)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let title = resolved.title, !title.isEmpty { Text(title).font(.headline) }
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.caption).foregroundColor(.secondary)
                    Text((resolved.canonicalURL ?? resolved.url).host ?? resolved.url.absoluteString)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Composer used by the manager (posts to /gossipPosts)
struct GossipComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: GossipSharePayload

    @State private var text: String
    @State private var resolving = false
    @State private var resolved: ResolvedLink?
    @State private var posting = false
    @State private var error: String?

    init(payload: GossipSharePayload) {
        self.payload = payload
        _text = State(initialValue: payload.defaultText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gossip") {
                    TextEditor(text: $text).frame(minHeight: 120)
                }

                Section("Preview") { previewSection }

                if let err = error { Section { Text(err).foregroundColor(.red) } }
            }
            .navigationTitle("Post to Gossip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: { posting ? AnyView(ProgressView()) : AnyView(Text("Post")) }
                        .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { kickOffResolveIfNeeded() }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if resolving { HStack { ProgressView(); Text("Resolving link…") } }
        else if let r = resolved { GossipLinkPreviewCard(resolved: r) }
        else if let u = firstURL(in: text) { HStack { Image(systemName: "link"); Text(u.absoluteString).foregroundColor(.secondary) } }
        else {
            switch payload {
            case .event(_, let flyer, _):
                if let fx = flyer {
                    AsyncImage(url: fx) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.12) }
                    .frame(height: 150).clipped().cornerRadius(10)
                } else { Text("Paste a link to generate a rich preview.").foregroundColor(.secondary) }
            case .media(let image, _):
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(height: 150).clipped().cornerRadius(10)
            default:
                Text("Paste a link to generate a rich preview.").foregroundColor(.secondary)
            }
        }
    }

    private func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) ?? []
        for m in matches { if let u = m.url { return u } }
        return nil
    }

    private func kickOffResolveIfNeeded() {
        switch payload {
        case .event(_, _, let deep):
            if let u = deep { resolving = true; LinkPreviewResolver.shared.resolve(u) { r in resolving = false; resolved = r } }
        case .link(let u, _):
            resolving = true; LinkPreviewResolver.shared.resolve(u) { r in resolving = false; resolved = r }
        case .text:
            if let u = firstURL(in: text) { resolving = true; LinkPreviewResolver.shared.resolve(u) { r in resolving = false; resolved = r } }
        case .media:
            break
        }
    }

    private func submit() {
        guard let uid = Auth.auth().currentUser?.uid else { error = "You must be signed in."; return }
        posting = true; error = nil

        let link: URL? = {
            switch payload {
            case .event(_, _, let deep): return deep ?? firstURL(in: text)
            case .link(let u, _): return u
            case .text: return firstURL(in: text)
            case .media: return firstURL(in: text)
            }
        }()

        let post = GossipPost(
            authorId: uid,
            createdAt: Date().timeIntervalSince1970,
            text: text,
            linkURL: link?.absoluteString,
            previewTitle: resolved?.title,
            previewSubtitle: resolved?.subtitle,
            previewImageURL: resolved?.imageURL?.absoluteString,
            previewResolvedURL: resolved?.canonicalURL?.absoluteString,
            eventId: {
                if case .event(let night, _, _) = payload { return night.id } else { return nil }
            }(),
            nightId: {
                if case .event(let night, _, _) = payload { return night.id } else { return nil }
            }(),
            venueId: {
                if case .event(let night, _, _) = payload { return night.venueId } else { return nil }
            }(),
            flyerURL: {
                if case .event(_, let flyer, _) = payload { return flyer?.absoluteString } else { return nil }
            }(),
            status: "active"
        )

        NightlifeServiceBridge.shared.postToGossip(post) { err in
            posting = false
            if let err = err { error = err.localizedDescription }
            else { dismiss() }
        }
    }
}

// MARK: - Manager: presents a unified share chooser with Gossip first
final class GossipShareManager {
    static let shared = GossipShareManager()
    private init() {}

    // Present the chooser from SwiftUI or UIKit
    func presentShare(from presenter: UIViewController, payload: GossipSharePayload) {
        // Per product requirement, open Gossip composer first
        let composer = UIHostingController(rootView: GossipComposerView(payload: payload))
        composer.modalPresentationStyle = .formSheet
        presenter.present(composer, animated: true)
    }

    // If you also want a fallback system share, call this after composer or from a secondary button
    func presentSystemShare(from presenter: UIViewController, payload: GossipSharePayload) {
        let items: [Any] = activityItems(for: payload)
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        presenter.present(vc, animated: true)
    }

    private func activityItems(for payload: GossipSharePayload) -> [Any] {
        switch payload {
        case .event(let night, _, let deep):
            let text = "\(night.title) • \(DateFormatter.shortDate.string(from: night.date))"
            if let deep { return [text, deep] } else { return [text] }
        case .link(let url, let text):
            if let t = text, !t.isEmpty { return [t, url] } else { return [url] }
        case .text(let t): return [t]
        case .media(let image, let text): return text == nil ? [image] : [text!, image]
        }
    }
}

// MARK: - UIApplication helpers
extension UIApplication {
    var keyWindowTopMostController: UIViewController? {
        connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .topMostViewController()
    }
}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        var top = rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

// MARK: - SwiftUI convenience: Button + Modifier
struct GossipShareButton: View {
    let payload: GossipSharePayload
    var title: String = "Share"
    var systemImage: String = "square.and.arrow.up"

    init(payload: GossipSharePayload, title: String = "Share", systemImage: String = "square.and.arrow.up") {
        self.payload = payload
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Button {
            if let presenter = UIApplication.shared.keyWindowTopMostController {
                GossipShareManager.shared.presentShare(from: presenter, payload: payload)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

extension View {
    func gossipShare(_ payload: GossipSharePayload) -> some View {
        self.onTapGesture {
            if let presenter = UIApplication.shared.keyWindowTopMostController {
                GossipShareManager.shared.presentShare(from: presenter, payload: payload)
            }
        }
    }
}

// MARK: - UIKit hook
extension UIViewController {
    func presentGossipShare(payload: GossipSharePayload) {
        GossipShareManager.shared.presentShare(from: self, payload: payload)
    }
}

/*
 NOTE: If you prefer modern UniformTypeIdentifiers instead of MobileCoreServices:
    1) Add `import UniformTypeIdentifiers`
    2) Replace:
        kUTTypeURL as String  -> UTType.url.identifier
        kUTTypeData as String -> UTType.data.identifier
*/
