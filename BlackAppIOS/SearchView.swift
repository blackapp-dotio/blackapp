//
//  SearchView.swift
//  BlackAppIOS
//

import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore
import AVKit

// MARK: - User Model (robust to missing username)
struct UserProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let username: String       // derived if missing
    let bio: String
    let profileImageURL: String?
    let circleSize: Int?

    init(id: String, name: String, username: String, bio: String = "", profileImageURL: String? = nil, circleSize: Int? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.bio = bio
        self.profileImageURL = profileImageURL
        self.circleSize = circleSize
    }

    init?(snapshot: DataSnapshot) {
        guard let dict = snapshot.value as? [String: Any] else { return nil }

        func str(_ keys: [String]) -> String? {
            for k in keys {
                if let v = dict[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return v
                }
            }
            return nil
        }

        let name  = str(["name", "displayName", "fullName"]) ?? ""
        var uname = str(["username", "handle", "userName"]) ?? ""
        let bio   = str(["bio", "about"]) ?? ""
        let photo = str(["profileImageURL", "photoURL", "avatarUrl", "avatarURL"])

        guard !name.isEmpty else { return nil }

        if uname.isEmpty {
            uname = deriveUsername(fromName: name, id: snapshot.key)
            print("🔍 [Search] Derived username for \(snapshot.key): @\(uname)")
        }

        var cs: Int? = nil
        if let n = dict["circleSize"] as? NSNumber { cs = n.intValue }
        else if let n = dict["circleSize"] as? Int { cs = n }

        self.id = snapshot.key
        self.name = name
        self.username = uname
        self.bio = bio
        self.profileImageURL = photo
        self.circleSize = cs
    }
}
// Put this near the top of SearchView.swift, right after the model declarations.

// Makes UserProfile eligible for JSONCache read/write
extension UserProfile: Codable {}

// Makes BrandSummary eligible for JSONCache read/write
extension BrandSummary: Codable {}

// MARK: - Brand summary for preview
struct BrandSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let logoURL: String?
    let isApproved: Bool
}

// MARK: - Debouncer (for suggestive search)
private final class Debouncer {
    private var work: DispatchWorkItem?
    func debounce(delay: TimeInterval, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

// MARK: - Search Screen (suggestive, fast)
struct SearchView: View {
    // Query & results
    @State private var searchText: String = ""
    @State private var results: [UserProfile] = []

    // UX state
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var selectedUser: UserProfile? = nil
    @State private var showPreview: Bool = false

    // Chat state
    @State private var chatTarget: UserProfile? = nil

    // Debug
    @State private var sourceNote: String = ""

    private let debouncer = Debouncer()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                UserSearchBar(text: $searchText, onClear: {
                    searchText = ""
                    results.removeAll()
                    isLoading = false
                    loadError = nil
                    sourceNote = ""
                })
                .onChange(of: searchText) { newValue in
                    debouncer.debounce(delay: 0.30) {
                        Task { await runSuggestiveSearch() }
                    }
                }

                if !sourceNote.isEmpty {
                    Text(sourceNote)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                }

                Group {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                        EmptyStateView(message: "Start typing a name or @username")
                    } else if isLoading {
                        ProgressView("Searching…").padding()
                    } else if let err = loadError {
                        SearchErrorView(message: err, onRetry: { Task { await runSuggestiveSearch(force: true) } })
                    } else if results.isEmpty {
                        EmptyStateView(message: "No users match “\(searchText)”")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(results, id: \.id) { user in
                                    Button {
                                        selectedUser = user
                                        showPreview = true
                                        log("Preview user tapped: id=\(user.id), @\(user.username)")
                                    } label: {
                                        UserRow(user: user)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    Divider().background(Color(.separator))
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle("Search")
            .onAppear { observeRTDBConnectivity() } // lightweight connectivity note only

            // Profile preview sheet
            .sheet(isPresented: $showPreview) {
                if let u = selectedUser {
                    UserPreviewSheet(
                        user: u,
                        onMessage: {
                            Task { await prepareDMAndOpen(for: u) }
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(false)
                }
            }

            // Chat sheet
            .sheet(item: $chatTarget, onDismiss: {
                log("Chat dismissed"); chatTarget = nil
            }) { target in
                ChatLaunchContainer(target: target)
                    .interactiveDismissDisabled(false)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Suggestive search pipeline
    private func cacheKey(for q: String) -> String { "user-suggest-\(q.lowercased())" }

    private func normalizedQuery() -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func runSuggestiveSearch(force: Bool = false) async {
        let q = normalizedQuery()
        guard q.count >= 2 else {
            results.removeAll()
            isLoading = false
            loadError = nil
            sourceNote = ""
            return
        }

        // Serve cached result instantly (10 min TTL), then refresh in background.
        if !force, let cached: [UserProfile] = JSONCache.shared.read(cacheKey(for: q), type: [UserProfile].self, maxAge: 10*60) {
            results = cached
            sourceNote = "Cached • \(cached.count) users"
        } else {
            sourceNote = ""
        }

        isLoading = true; loadError = nil
        do {
            // 1) Firestore prefix search (usernameLower & nameLower)
            if let fs = try await searchFirestorePrefix(q: q, limit: 20), !fs.isEmpty {
                await MainActor.run {
                    results = fs
                    isLoading = false
                    sourceNote = "Firestore • \(fs.count) users"
                }
                JSONCache.shared.write(cacheKey(for: q), value: fs)
                return
            }

            // 2) RTDB fallback (usernameLower or nameLower if present)
            if let r = await searchRTDBPrefix(q: q, limit: 20), !r.isEmpty {
                await MainActor.run {
                    results = r
                    isLoading = false
                    sourceNote = "Realtime DB • \(r.count) users"
                }
                JSONCache.shared.write(cacheKey(for: q), value: r)
                return
            }

            // 3) Nothing found
            await MainActor.run {
                results = []
                isLoading = false
                loadError = nil
                sourceNote = "No matches"
            }
        } catch {
            await MainActor.run {
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    // Firestore: prefix query on `users`
    // Requires documents to include `usernameLower` / `nameLower` fields and to be indexed.
    private func searchFirestorePrefix(q: String, limit: Int) async throws -> [UserProfile]? {
        let db = Firestore.firestore()
        var out: [String: UserProfile] = [:]

        func fetch(field: String) async throws {
            // orderBy(field) + range
            var query = db.collection("users")
                .order(by: field)
                .whereField(field, isGreaterThanOrEqualTo: q)
                .whereField(field, isLessThan: q + "\u{f8ff}")
                .limit(to: limit)

            let snap = try await query.getDocuments()
            for doc in snap.documents {
                let d = doc.data()
                let name = (d["name"] as? String) ?? (d["displayName"] as? String) ?? ""
                guard !name.isEmpty else { continue }
                let username = (d["username"] as? String) ?? (d["handle"] as? String) ?? deriveUsername(fromName: name, id: doc.documentID)
                let bio = (d["bio"] as? String) ?? (d["about"] as? String) ?? ""
                let photo = (d["profileImageURL"] as? String) ?? (d["photoURL"] as? String) ?? (d["avatarUrl"] as? String)
                let circleSize = (d["circleSize"] as? Int) ?? (d["circleSize"] as? NSNumber)?.intValue

                out[doc.documentID] = UserProfile(
                    id: doc.documentID,
                    name: name,
                    username: username.replacingOccurrences(of: " ", with: ""),
                    bio: bio,
                    profileImageURL: photo,
                    circleSize: circleSize
                )
            }
        }

        do {
            try await fetch(field: "usernameLower")
        } catch {
            // Index may be missing; ignore and try nameLower
        }
        if out.count < limit {
            do { try await fetch(field: "nameLower") } catch { /* ignore */ }
        }

        let arr = Array(out.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return arr
    }

    // RTDB: prefix query on /users by child key (if fields exist)
    private func searchRTDBPrefix(q: String, limit: UInt) async -> [UserProfile]? {
        let ref = Database.database().reference(withPath: "users")
        var hits: [String: UserProfile] = [:]

        func fetch(childKey: String) async {
            await withCheckedContinuation { cont in
                let qRef = ref
                    .queryOrdered(byChild: childKey)
                    .queryStarting(atValue: q)
                    .queryEnding(atValue: q + "\u{f8ff}")
                    .queryLimited(toFirst: limit)

                qRef.observeSingleEvent(of: .value) { snap in
                    for case let cs as DataSnapshot in snap.children {
                        if let u = UserProfile(snapshot: cs) {
                            hits[u.id] = u
                        }
                    }
                    cont.resume()
                }
            }
        }

        await fetch(childKey: "usernameLower")
        if hits.count < Int(limit) { await fetch(childKey: "nameLower") }

        let arr = Array(hits.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return arr
    }

    // MARK: - Connectivity note (lightweight)
    private func observeRTDBConnectivity() {
        let infoRef = Database.database().reference(withPath: ".info/connected")
        infoRef.observe(.value) { snap in
            if let connected = snap.value as? Bool { log("RTDB connected=\(connected)") }
        }
    }

    // MARK: - Request + thread prep, then open chat
    private func chatId(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "_") }
    private func rtdbContactsPath(_ uid: String) -> DatabaseReference {
        Database.database().reference(withPath: "contacts/\(uid)")
    }

    private func fsContactRef(_ uid: String, other: String) -> DocumentReference {
        Firestore.firestore()
            .collection("users").document(uid)
            .collection("contacts").document(other)
    }

    private func areContactsCombined(me: String, other: String) async -> Bool {
        if await areContactsFirestore(me: me, other: other) { return true }
        return await areContactsRTDB(me: me, other: other)
    }

    private func areContactsFirestore(me: String, other: String) async -> Bool {
        await withCheckedContinuation { cont in
            fsContactRef(me, other: other).getDocument { snap, _ in
                let data = snap?.data()
                let status = (data?["status"] as? String) ?? ""
                let accepted = (data?["accepted"] as? Bool) ?? false
                cont.resume(returning: status == "active" && accepted)
            }
        }
    }

    private func areContactsRTDB(me: String, other: String) async -> Bool {
        await withCheckedContinuation { cont in
            rtdbContactsPath(me).child(other).observeSingleEvent(of: .value) { snap in
                cont.resume(returning: snap.exists())
            }
        }
    }

    private func ensurePendingContactsInFirestore(me: String, other: String) async {
        let aRef = fsContactRef(me, other: other)
        let bRef = fsContactRef(other, other: me)
        do {
            let a = try await aRef.getDocument()
            let b = try await bRef.getDocument()

            let aIsActive = ((a.data()?["status"] as? String) == "active") && ((a.data()?["accepted"] as? Bool) == true)
            let bIsActive = ((b.data()?["status"] as? String) == "active") && ((b.data()?["accepted"] as? Bool) == true)

            if aIsActive && bIsActive { return }

            let batch = Firestore.firestore().batch()
            let stamp: [String: Any] = [
                "status": "pending",
                "accepted": false,
                "source": "search",
                "createdAt": FieldValue.serverTimestamp()
            ]
            batch.setData(stamp, forDocument: aRef, merge: true)
            batch.setData(stamp, forDocument: bRef, merge: true)
            try await batch.commit()
        } catch {
            log("❌ ensurePendingContactsInFirestore error: \(error.localizedDescription)")
        }
    }

    private func ensureDirectChatDoc(me: String, other: String, isContacts: Bool) async {
        let id = chatId(me, other)
        let doc = Firestore.firestore().collection("directChats").document(id)

        do {
            let snap = try await doc.getDocument()
            if snap.exists {
                if isContacts, (snap.data()?["pending"] as? Bool) == true {
                    try await doc.updateData(["pending": false, "updatedAt": FieldValue.serverTimestamp()])
                }
                return
            }
            var data: [String: Any] = [
                "participants": [me, other],
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
                "pending": !isContacts,
                "userA": me, "userB": other
            ]
            try await doc.setData(data)
        } catch {
            log("❌ ensureDirectChatDoc error: \(error.localizedDescription)")
        }
    }

    private func fetchMyPublicProfileRTDB(_ uid: String) async -> [String: Any] {
        await withCheckedContinuation { cont in
            Database.database().reference(withPath: "users/\(uid)")
                .observeSingleEvent(of: .value) { snap in
                    cont.resume(returning: (snap.value as? [String: Any]) ?? [:])
                }
        }
    }

    private func prepareDMAndOpen(for user: UserProfile) async {
        guard let me = Auth.auth().currentUser?.uid else {
            log("❌ prepareDMAndOpen: no current user")
            return
        }
        showPreview = false
        guard me != user.id else { return }

        async let contactsCombined = areContactsCombined(me: me, other: user.id)
        async let myProfile = fetchMyPublicProfileRTDB(me)

        let isContacts = await contactsCombined
        let profile = await myProfile

        if !isContacts {
            await ensurePendingContactsInFirestore(me: me, other: user.id)
            await writeDMRequests(me: me, other: user.id, myProfile: profile, lastText: "")
        }
        await ensureDirectChatDoc(me: me, other: user.id, isContacts: isContacts)

        chatTarget = user
    }

    private func writeDMRequests(me: String, other: String, myProfile: [String: Any], lastText: String = "") async {
        let db = Firestore.firestore()
        let now = Date().timeIntervalSince1970

        let incomingRef = db.collection("dmRequests").document(other).collection("incoming").document(me)
        let outgoingRef = db.collection("dmRequests").document(me).collection("outgoing").document(other)

        let payloadIncoming: [String: Any] = [
            "fromName": (myProfile["name"] as? String) ?? "",
            "fromUsername": (myProfile["username"] as? String) ?? "",
            "fromAvatarUrl": (myProfile["profileImageURL"] as? String) ?? (myProfile["photoURL"] as? String) ?? "",
            "lastText": lastText,
            "lastAt": now,
            "count": FieldValue.increment(Int64(1))
        ]
        let payloadOutgoing: [String: Any] = [
            "toName": (myProfile["name"] as? String) ?? "",
            "toUsername": (myProfile["username"] as? String) ?? "",
            "toAvatarUrl": (myProfile["profileImageURL"] as? String) ?? (myProfile["photoURL"] as? String) ?? "",
            "lastText": lastText,
            "lastAt": now
        ]
        do {
            try await incomingRef.setData(payloadIncoming, merge: true)
            try await outgoingRef.setData(payloadOutgoing, merge: true)
        } catch {
            log("❌ dmRequests write failed: \(error)")
        }
    }
}

// MARK: - Chat launcher (uses your real ChatUserProfile + DirectChatRoomView)
private struct ChatLaunchContainer: View {
    let target: UserProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let recipient = makeRecipient(from: target) {
                    DirectChatRoomView(recipient: recipient)
                } else {
                    VStack(spacing: 12) {
                        Text("Couldn’t prepare chat").foregroundColor(.white).font(.headline)
                        Text("Failed to build ChatUserProfile – check console for decode errors.")
                            .foregroundColor(.gray).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Close") { dismiss() }
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
        }
        .background(Color.black)
    }
}

// MARK: - Components

private struct UserSearchBar: View {
    @Binding var text: String
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search users…", text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .foregroundColor(.white)
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding([.horizontal, .top])
    }
}

private struct UserRow: View {
    let user: UserProfile
    var body: some View {
        HStack(spacing: 12) {
            CachedAvatar(urlString: user.profileImageURL)
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.name).font(.headline).foregroundColor(.white)
                    CircleSizeBadgeInline(userId: user.id, initial: user.circleSize ?? 0)
                }
                Text("@\(user.username)").font(.subheadline).foregroundColor(.gray)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.gray)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Cached avatar & brand logo (ImageStore-backed)
private struct CachedAvatar: View {
    let urlString: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Circle().fill(Color(.systemGray5)).overlay(ProgressView())
            }
        }
        .task(id: urlString ?? "") {
            guard let s = urlString, let url = URL(string: s) else { image = nil; return }
            ImageStore.shared.load(from: url, key: s) { img in
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
        }
    }
}

private struct CachedBrandLogo: View {
    let urlString: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(.systemGray5)).overlay(Image(systemName: "photo"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: urlString ?? "") {
            guard let s = urlString, let url = URL(string: s) else { image = nil; return }
            ImageStore.shared.load(from: url, key: s) { img in
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
        }
    }
}

private struct UserPreviewSheet: View {
    let user: UserProfile
    var onMessage: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            CachedAvatar(urlString: user.profileImageURL)
                .frame(width: 100, height: 100)
                .clipShape(Circle())

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(user.name).font(.title2).bold().foregroundColor(.white)
                    LivePreviewStarBadgeArea(userId: user.id, initial: user.circleSize ?? 0)
                }
                Text("@\(user.username)").foregroundColor(.gray)
            }

            if !user.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(user.bio)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(.horizontal)
            }

            UserBrandsStrip(userId: user.id)

            Button {
                onMessage()
            } label: {
                HStack { Image(systemName: "paperplane.fill"); Text("Message") }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.blue).cornerRadius(12).foregroundColor(.white)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.top, 24)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

// Horizontal brand chips (auto-loads brands for the given user)
private struct UserBrandsStrip: View {
    let userId: String

    @State private var isLoading = true
    @State private var brands: [BrandSummary] = []
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Brands").font(.headline).foregroundColor(.white)
                Spacer()
            }

            if isLoading {
                ProgressView().padding(.vertical, 6)
            } else if let error {
                Text(error).foregroundColor(.gray).font(.caption)
            } else if brands.isEmpty {
                Text("No brands yet").foregroundColor(.gray).font(.caption)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(brands) { brand in
                            BrandChip(brand: brand)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal)
        .onAppear(perform: loadBrands)
    }

    private func loadBrands() {
        // cache brands per user for 12h
        let cacheKey = "brands-\(userId)"
        if let cached: [BrandSummary] = JSONCache.shared.read(cacheKey, type: [BrandSummary].self, maxAge: 12*3600) {
            brands = cached; isLoading = false; return
        }

        isLoading = true
        error = nil
        brands.removeAll()

        // Prefer a user-scoped path if you ever add one, else scan /brands (kept tolerant)
        let ref = Database.database().reference(withPath: "brands")
        ref.observeSingleEvent(of: .value) { snap in
            guard snap.exists() else {
                isLoading = false
                error = "No brands."
                log("Brands: no data at /brands")
                return
            }

            var found: [BrandSummary] = []
            var total = 0

            for case let child as DataSnapshot in snap.children {
                total += 1
                guard let dict = child.value as? [String: Any] else { continue }

                // Owner/user id match
                let owner = (dict["ownerId"] as? String)
                    ?? (dict["userId"] as? String)
                    ?? (dict["uid"] as? String)
                    ?? (dict["createdBy"] as? String)

                guard owner == userId else { continue }

                // Approval status (tolerant)
                let approvedBool = (dict["approved"] as? Bool)
                    ?? (dict["isApproved"] as? Bool)
                let status = (dict["status"] as? String)?.lowercased()
                let isApproved = approvedBool ?? (status == "approved" || status == "active" || status == "public")

                let name = (dict["name"] as? String)
                    ?? (dict["title"] as? String)
                    ?? "Untitled"

                let logo = (dict["logoURL"] as? String)
                    ?? (dict["logoUrl"] as? String)
                    ?? (dict["imageURL"] as? String)
                    ?? (dict["imageUrl"] as? String)

                let b = BrandSummary(id: child.key, name: name, logoURL: logo, isApproved: isApproved)
                found.append(b)
            }

            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.brands = found
            self.isLoading = false
            JSONCache.shared.write(cacheKey, value: found)
            log("Brands: scanned \(total) children, found \(found.count) for user \(userId).")
        } withCancel: { err in
            isLoading = false
            error = err.localizedDescription
            log("❌ Brands error: \(err.localizedDescription)")
        }
    }
}

private struct BrandChip: View {
    let brand: BrandSummary
    var body: some View {
        HStack(spacing: 8) {
            CachedBrandLogo(urlString: brand.logoURL)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !brand.isApproved {
                    Text("Pending").font(.caption2).foregroundColor(.yellow)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - ⭐️ Live circle-size badge that renders StarBadgeInline
private struct CircleSizeBadgeInline: View {
    let userId: String
    let initial: Int

    @State private var size: Int
    @State private var ref: DatabaseReference?
    @State private var handle: DatabaseHandle?

    init(userId: String, initial: Int) {
        self.userId = userId
        self.initial = initial
        _size = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if size > 0 {
                StarBadgeInline(circleSize: size)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        let r = Database.database().reference().child("users").child(userId).child("circleSize")
        ref = r
        handle = r.observe(.value) { snap in
            if let n = snap.value as? NSNumber {
                size = n.intValue
            } else if let n = snap.value as? Int {
                size = n
            }
        }
    }

    private func stop() {
        if let r = ref, let h = handle {
            r.removeObserver(withHandle: h)
        }
        ref = nil
        handle = nil
    }
}

// MARK: - Helpers

fileprivate func deriveUsername(fromName name: String, id: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let base = name
        .lowercased()
        .components(separatedBy: allowed.inverted)
        .filter { !$0.isEmpty }
        .joined()
    if base.count >= 3 { return base }
    let suffix = String(id.suffix(6)).lowercased()
    return (base.isEmpty ? "user" : base) + suffix
}

fileprivate func makeRecipient(from u: UserProfile) -> ChatUserProfile? {
    let obj: [String: Any?] = [
        "id": u.id,
        "name": u.name,
        "displayName": u.name,
        "username": u.username,
        "handle": u.username,
        "avatarUrl": u.profileImageURL,
        "photoURL": u.profileImageURL,
        "profileImageURL": u.profileImageURL,
        "bio": u.bio
    ]
    let compact = obj.compactMapValues { $0 }
    do {
        let data = try JSONSerialization.data(withJSONObject: compact, options: [])
        let decoded = try JSONDecoder().decode(ChatUserProfile.self, from: data)
        log("Built ChatUserProfile via JSON bridge for \(u.id)")
        return decoded
    } catch {
        log("❌ JSON bridge decode failed: \(error)")
        log("Payload was: \(compact)")
        return nil
    }
}

@inline(__always) private func log(_ message: String) {
    print("🔍 [Search] \(message)")
}

// MARK: - Small helpers

private struct EmptyStateView: View {
    let message: String
    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .background(Color.black)
    }
}

private struct SearchErrorView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text("Couldn’t load users")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: onRetry) {
                Text("Retry")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }
            .padding(.top, 6)
        }
        .padding()
        .background(Color.black)
    }
}

// LivePreviewStarBadgeArea & helpers (unchanged from your file) -------------
private struct LivePreviewStarBadgeArea: View {
    let userId: String
    let initial: Int

    @State private var size: Int
    @State private var showAllBadges = false
    @State private var ref: DatabaseReference?
    @State private var handle: DatabaseHandle?

    init(userId: String, initial: Int) {
        self.userId = userId
        self.initial = initial
        _size = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 4) {
            PreviewStarBadgeInline(circleSize: size)
                .onTapGesture { withAnimation(.easeInOut) { showAllBadges.toggle() } }

            if showAllBadges {
                PreviewStarBadgeProgressRow(circleSize: size)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        let r = Database.database().reference().child("users").child(userId).child("circleSize")
        ref = r
        handle = r.observe(.value) { snap in
            if let n = snap.value as? NSNumber { size = n.intValue }
            else if let n = snap.value as? Int { size = n }
        }
    }
    private func stop() {
        if let r = ref, let h = handle { r.removeObserver(withHandle: h) }
        ref = nil; handle = nil
    }
}

private struct PreviewStarBadgeInline: View {
    let circleSize: Int
    @State private var pulse = false

    private var tier: String { previewDeriveTier(from: circleSize) }
    private var level: Int { previewTierOrder(tier) }

    private var scaleRange: ClosedRange<CGFloat> {
        let base: CGFloat = 0.06
        let step: CGFloat = 0.02
        let amp = min(base + step * CGFloat(max(0, level)), 0.22)
        return (1.0 - amp)...(1.0 + amp)
    }
    private var ringOpacity: Double { level == 0 ? 0.18 : 0.35 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(previewColorForTier(tier).opacity(ringOpacity), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.6 : 1.0)
                .opacity(pulse ? 0.0 : 1.0)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)

            Image(systemName: "star.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(previewColorForTier(tier))
                .shadow(color: .white.opacity(0.25), radius: 3)
                .scaleEffect(pulse ? scaleRange.upperBound : scaleRange.lowerBound)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                .accessibilityLabel(Text("\(tier.capitalized) popularity star, circle size \(circleSize)"))
        }
        .onAppear { pulse = true }
    }
}

private struct PreviewStarBadgeProgressRow: View {
    let circleSize: Int
    private var tiers: [(String, Int)] {
        [("white",0),("red",5),("orange",10),("yellow",20),("green",40),("blue",80),("indigo",160),("violet",320),("black",640)]
    }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(tiers, id: \.0) { (name, threshold) in
                let achieved = circleSize >= threshold
                Image(systemName: achieved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(previewColorForTier(name).opacity(achieved ? 1 : 0.35))
            }
        }
    }
}

// --- tiny local helpers (scoped to SearchView file) ---
fileprivate func previewDeriveTier(from circleSize: Int) -> String {
    if circleSize >= 640 { return "black" }
    if circleSize >= 320 { return "violet" }
    if circleSize >= 160 { return "indigo" }
    if circleSize >= 80  { return "blue" }
    if circleSize >= 40  { return "green" }
    if circleSize >= 20  { return "yellow" }
    if circleSize >= 10  { return "orange" }
    if circleSize >= 5   { return "red" }
    return "white"
}
fileprivate func previewTierOrder(_ tier: String) -> Int {
    switch tier.lowercased() {
    case "white":  return 0
    case "red":    return 1
    case "orange": return 2
    case "yellow": return 3
    case "green":  return 4
    case "blue":   return 5
    case "indigo": return 6
    case "violet": return 7
    case "black":  return 8
    default:       return -1
    }
}

fileprivate func previewColorForTier(_ tier: String) -> Color {
    switch tier.lowercased() {
    case "white":  return .white
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green":  return .green
    case "blue":   return .blue
    case "indigo": return .indigo
    case "violet": return .purple
    case "black":  return .black
    default:       return .gray
    }
}
