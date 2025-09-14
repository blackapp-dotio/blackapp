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

// MARK: - Models

struct UserProfile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let username: String
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
        if uname.isEmpty { uname = deriveUsername(fromName: name, id: snapshot.key) }

        var cs: Int? = nil
        if let n = dict["circleSize"] as? NSNumber { cs = n.intValue }
        else if let n = dict["circleSize"] as? Int { cs = n }

        self.id = snapshot.key
        self.name = name
        self.username = uname.replacingOccurrences(of: " ", with: "")
        self.bio = bio
        self.profileImageURL = photo
        self.circleSize = cs
    }
}

struct BrandSummary: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let logoURL: String?
    let isApproved: Bool
}

// Hashtag summary (Firestore or RTDB)
struct HashtagSummary: Identifiable, Hashable, Codable {
    let id: String        // equals tagLower for stability
    let tagLower: String  // always lowercased
    let usageCount: Int
    let coverImageURL: String?

    init(tagLower: String, usageCount: Int = 0, coverImageURL: String? = nil) {
        self.id = tagLower
        self.tagLower = tagLower
        self.usageCount = usageCount
        self.coverImageURL = coverImageURL
    }
}

// MARK: - Debouncer

private final class Debouncer {
    private var work: DispatchWorkItem?
    func debounce(delay: TimeInterval, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

// MARK: - Scope

private enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case people = "People"
    case hashtags = "Hashtags"
    var id: String { rawValue }
}

// MARK: - Search Screen

struct SearchView: View {
    // Query & state
    @State private var searchText: String = ""
    @State private var scope: SearchScope = .all

    // Results
    @State private var userResults: [UserProfile] = []
    @State private var hashtagResults: [HashtagSummary] = []

    // UX
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var sourceNote: String = ""

    // Sheets
    @State private var selectedUser: UserProfile? = nil
    @State private var showUserPreview: Bool = false

    @State private var selectedTag: HashtagSummary? = nil
    @State private var showTagPreview: Bool = false

    // Chat
    @State private var chatTarget: UserProfile? = nil

    private let debouncer = Debouncer()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search + scope
                UserSearchBar(
                    text: $searchText,
                    placeholder: "Search users or #hashtags…",
                    onClear: {
                        searchText = ""
                        userResults.removeAll()
                        hashtagResults.removeAll()
                        isLoading = false
                        loadError = nil
                        sourceNote = ""
                    }
                )
                .onChange(of: searchText) { _ in
                    debouncer.debounce(delay: 0.20) {
                        Task { await runSuggestiveSearch() }
                    }
                }

                Picker("", selection: $scope) {
                    ForEach(SearchScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)
                .onChange(of: scope) { _ in
                    Task { await runSuggestiveSearch(force: true) }
                }

                if !sourceNote.isEmpty {
                    Text(sourceNote)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                }

                // Results
                Group {
                    if searchText.trimmedLower().count < 2 {
                        EmptyStateView(message: "Start typing a name, @username, or #hashtag")
                    } else if isLoading {
                        ProgressView("Searching…").padding()
                    } else if let err = loadError {
                        SearchErrorView(message: err, onRetry: { Task { await runSuggestiveSearch(force: true) } })
                    } else if userResults.isEmpty && hashtagResults.isEmpty {
                        EmptyStateView(message: "No results for “\(searchText)”")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                switch scope {
                                case .all:
                                    if !userResults.isEmpty {
                                        SearchSectionHeader("People")
                                        ForEach(userResults.prefix(6), id: \.id) { user in
                                            Button {
                                                selectedUser = user
                                                showUserPreview = true
                                                log("Preview user tapped: \(user.id) @\(user.username)")
                                            } label: { UserRow(user: user) }
                                            .buttonStyle(.plain)
                                            Divider().background(Color(.separator))
                                        }
                                    }
                                    if !hashtagResults.isEmpty {
                                        SearchSectionHeader("Hashtags")
                                        ForEach(hashtagResults.prefix(8), id: \.id) { tag in
                                            Button {
                                                selectedTag = tag
                                                showTagPreview = true
                                            } label: { HashtagRow(tag: tag) }
                                            .buttonStyle(.plain)
                                            Divider().background(Color(.separator))
                                        }
                                    }

                                case .people:
                                    ForEach(userResults, id: \.id) { user in
                                        Button {
                                            selectedUser = user
                                            showUserPreview = true
                                        } label: { UserRow(user: user) }
                                        .buttonStyle(.plain)
                                        Divider().background(Color(.separator))
                                    }

                                case .hashtags:
                                    ForEach(hashtagResults, id: \.id) { tag in
                                        Button {
                                            selectedTag = tag
                                            showTagPreview = true
                                        } label: { HashtagRow(tag: tag) }
                                        .buttonStyle(.plain)
                                        Divider().background(Color(.separator))
                                    }
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
            .onAppear { observeRTDBConnectivity() }

            // User preview
            .sheet(isPresented: $showUserPreview) {
                if let u = selectedUser {
                    UserPreviewSheet(
                        user: u,
                        onMessage: { Task { await prepareDMAndOpen(for: u) } }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }

            // Hashtag preview
            .sheet(isPresented: $showTagPreview) {
                if let t = selectedTag {
                    HashtagPreviewSheet(tag: t)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }

            // Chat sheet
            .sheet(item: $chatTarget, onDismiss: { chatTarget = nil }) { target in
                ChatLaunchContainer(target: target)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Search

    private func cacheKeyUsers(_ q: String) -> String { "user-suggest-\(q.trimmedLower())" }
    private func cacheKeyTags(_ q: String)  -> String { "tag-suggest-\(q.trimmedLower())" }

    private func runSuggestiveSearch(force: Bool = false) async {
        let q = searchText.trimmedLower()
        guard q.count >= 2 else {
            userResults.removeAll()
            hashtagResults.removeAll()
            isLoading = false
            loadError = nil
            sourceNote = ""
            return
        }
        
        // Instant cache hit
        var usedCache = false
        if !force {
            if let cachedU: [UserProfile] = JSONCache.shared.read(cacheKeyUsers(q), type: [UserProfile].self, maxAge: 10*60) {
                userResults = cachedU; usedCache = true
            }
            if let cachedT: [HashtagSummary] = JSONCache.shared.read(cacheKeyTags(q), type: [HashtagSummary].self, maxAge: 10*60) {
                hashtagResults = cachedT; usedCache = true
            }
            if usedCache { sourceNote = "Cached"; isLoading = false }
        }
        
        // inside runSuggestiveSearch(force:)
        isLoading = true; loadError = nil
        
        do {
            // Users & tags in parallel (non-optional now)
            async let usersTask: [UserProfile] = searchUsersPrefix(q: q, limit: 20)
            async let tagsTask:  [HashtagSummary] = searchHashtagsPrefix(q: q, limit: 20)
            
            let (users, tags) = await (usersTask, tagsTask)
            
            await MainActor.run {
                self.userResults = users
                self.hashtagResults = tags
                self.isLoading = false
                self.sourceNote = sourceLabel(users: users, tags: tags)
            }
            JSONCache.shared.write(cacheKeyUsers(q), value: users)
            JSONCache.shared.write(cacheKeyTags(q), value: tags)
        } catch {
            await MainActor.run {
                isLoading = false
                if !(usedCache && (!userResults.isEmpty || !hashtagResults.isEmpty)) {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func sourceLabel(users: [UserProfile], tags: [HashtagSummary]) -> String {
        var parts: [String] = []
        parts.append("Users: \(users.count)")
        parts.append("Tags: \(tags.count)")
        return parts.joined(separator: " • ")
    }

    // ---- Users: wrapper that tries Firestore then RTDB (case-insensitive)
    // Try Firestore then RTDB; return [] if nothing
    private func searchUsersPrefix(q: String, limit: Int) async -> [UserProfile] {
        if let fs = try? await searchFirestorePrefix(q: q, limit: limit), !fs.isEmpty {
            return fs
        }
        let rtdb = await searchRTDBPrefix(q: q, limit: UInt(limit))
        return rtdb
    }

    // Firestore: now returns [UserProfile] (possibly empty)
    private func searchFirestorePrefix(q: String, limit: Int) async throws -> [UserProfile] {
        let db = Firestore.firestore()
        let needle = q.lowercased()
        var out: [String: UserProfile] = [:]

        func collect(_ docs: [QueryDocumentSnapshot]) {
            for doc in docs {
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

        // A) Fast path on *Lower
        do {
            let snap1 = try await db.collection("users")
                .order(by: "usernameLower")
                .whereField("usernameLower", isGreaterThanOrEqualTo: needle)
                .whereField("usernameLower", isLessThan: needle + "\u{f8ff}")
                .limit(to: limit)
                .getDocuments()
            collect(snap1.documents)
        } catch { /* ignore */ }

        if out.count < limit {
            do {
                let snap2 = try await db.collection("users")
                    .order(by: "nameLower")
                    .whereField("nameLower", isGreaterThanOrEqualTo: needle)
                    .whereField("nameLower", isLessThan: needle + "\u{f8ff}")
                    .limit(to: limit)
                    .getDocuments()
                collect(snap2.documents)
            } catch { /* ignore */ }
        }

        if !out.isEmpty {
            return Array(out.values).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        // B) Fallback: original fields with case variants
        let variants: [String] = {
            let cap = needle.prefix(1).uppercased() + needle.dropFirst()
            return Array(Set([needle, cap, needle.uppercased()]))
        }()

        func tryField(_ field: String) async {
            for v in variants {
                do {
                    let snap = try await db.collection("users")
                        .order(by: field)
                        .whereField(field, isGreaterThanOrEqualTo: v)
                        .whereField(field, isLessThan: v + "\u{f8ff}")
                        .limit(to: limit)
                        .getDocuments()
                    collect(snap.documents)
                    if out.count >= limit { return }
                } catch { /* ignore */ }
            }
        }

        if out.count < limit { await try? await tryField("username") }
        if out.count < limit { await try? await tryField("name") }

        return Array(out.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    // RTDB: now returns [UserProfile] (possibly empty)
    private func searchRTDBPrefix(q: String, limit: UInt) async -> [UserProfile] {
        let ref = Database.database().reference(withPath: "users")
        let needle = q.lowercased()
        var hits: [String: UserProfile] = [:]

        func collect(_ snap: DataSnapshot) {
            for case let cs as DataSnapshot in snap.children {
                if let u = UserProfile(snapshot: cs) { hits[u.id] = u }
            }
        }

        // A) *Lower fields
        func fetch(lowerField: String) async {
            await withCheckedContinuation { cont in
                ref.queryOrdered(byChild: lowerField)
                    .queryStarting(atValue: needle)
                    .queryEnding(atValue: needle + "\u{f8ff}")
                    .queryLimited(toFirst: limit)
                    .observeSingleEvent(of: .value) { snap in
                        collect(snap); cont.resume()
                    }
            }
        }
        await fetch(lowerField: "usernameLower")
        if hits.count < Int(limit) { await fetch(lowerField: "nameLower") }
        if hits.count >= Int(limit) {
            return Array(hits.values)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(Int(limit)).map { $0 }
        }

        // B) Original fields with variants
        let variants: [String] = {
            let cap = needle.prefix(1).uppercased() + needle.dropFirst()
            return Array(Set([needle, cap, needle.uppercased()]))
        }()

        func fetch(field: String) async {
            for v in variants {
                await withCheckedContinuation { cont in
                    ref.queryOrdered(byChild: field)
                        .queryStarting(atValue: v)
                        .queryEnding(atValue: v + "\u{f8ff}")
                        .queryLimited(toFirst: limit)
                        .observeSingleEvent(of: .value) { snap in
                            collect(snap); cont.resume()
                        }
                }
                if hits.count >= Int(limit) { return }
            }
        }

        if hits.count < Int(limit) { await fetch(field: "username") }
        if hits.count < Int(limit) { await fetch(field: "name") }

        return Array(hits.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(Int(limit)).map { $0 }
    }


    // HASHTAGS: Firestore first, RTDB fallback
    private func searchHashtagsPrefix(q: String, limit: Int) async -> [HashtagSummary] {
        let db = Firestore.firestore()
        var tags: [HashtagSummary] = []

        do {
            let snap = try await db.collection("hashtags")
                .order(by: "tagLower")
                .whereField("tagLower", isGreaterThanOrEqualTo: q.hashtagStripped())
                .whereField("tagLower", isLessThan: q.hashtagStripped() + "\u{f8ff}")
                .limit(to: limit)
                .getDocuments()

            for doc in snap.documents {
                let d = doc.data()
                let tag = (d["tagLower"] as? String) ?? doc.documentID.lowercased()
                let count = (d["usageCount"] as? Int) ?? (d["usageCount"] as? NSNumber)?.intValue ?? 0
                let cover = (d["coverImageURL"] as? String)
                tags.append(.init(tagLower: tag, usageCount: count, coverImageURL: cover))
            }
        } catch {
            // ignore; try RTDB below
        }

        if !tags.isEmpty { return tags.sorted { $0.usageCount > $1.usageCount } }

        // RTDB fallback
        let ref = Database.database().reference(withPath: "hashtags")
        return await withCheckedContinuation { cont in
            ref.queryOrdered(byChild: "tagLower")
                .queryStarting(atValue: q.hashtagStripped())
                .queryEnding(atValue: q.hashtagStripped() + "\u{f8ff}")
                .queryLimited(toFirst: UInt(limit))
                .observeSingleEvent(of: .value) { snap in
                    var out: [HashtagSummary] = []
                    for case let cs as DataSnapshot in snap.children {
                        if let d = cs.value as? [String: Any] {
                            let tag = (d["tagLower"] as? String) ?? cs.key.lowercased()
                            let count = (d["usageCount"] as? Int) ?? (d["usageCount"] as? NSNumber)?.intValue ?? 0
                            let cover = (d["coverImageURL"] as? String)
                            out.append(.init(tagLower: tag, usageCount: count, coverImageURL: cover))
                        }
                    }
                    cont.resume(returning: out.sorted { $0.usageCount > $1.usageCount })
                }
        }
    }

    // MARK: - Connectivity

    private func observeRTDBConnectivity() {
        let infoRef = Database.database().reference(withPath: ".info/connected")
        infoRef.observe(.value) { snap in
            if let connected = snap.value as? Bool { log("RTDB connected=\(connected)") }
        }
    }

    // MARK: - Chat/DM flow (unchanged)

    private func chatId(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "_") }
    private func rtdbContactsPath(_ uid: String) -> DatabaseReference { Database.database().reference(withPath: "contacts/\(uid)") }
    private func fsContactRef(_ uid: String, other: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid).collection("contacts").document(other)
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
            try await doc.setData([
                "participants": [me, other],
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
                "pending": !isContacts,
                "userA": me, "userB": other
            ])
        } catch {
            log("❌ ensureDirectChatDoc error: \(error.localizedDescription)")
        }
    }

    private func fetchMyPublicProfileRTDB(_ uid: String) async -> [String: Any] {
        await withCheckedContinuation { cont in
            Database.database().reference(withPath: "users/\(uid)").observeSingleEvent(of: .value) { snap in
                cont.resume(returning: (snap.value as? [String: Any]) ?? [:])
            }
        }
    }

    private func prepareDMAndOpen(for user: UserProfile) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        showUserPreview = false
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
            "lastText": lastText, "lastAt": now, "count": FieldValue.increment(Int64(1))
        ]
        let payloadOutgoing: [String: Any] = [
            "toName": (myProfile["name"] as? String) ?? "",
            "toUsername": (myProfile["username"] as? String) ?? "",
            "toAvatarUrl": (myProfile["profileImageURL"] as? String) ?? (myProfile["photoURL"] as? String) ?? "",
            "lastText": lastText, "lastAt": now
        ]
        do {
            try await incomingRef.setData(payloadIncoming, merge: true)
            try await outgoingRef.setData(payloadOutgoing, merge: true)
        } catch { log("❌ dmRequests write failed: \(error)") }
    }
}

// MARK: - Views & components

private struct SearchSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title).font(.subheadline).foregroundColor(.gray)
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

private struct UserSearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search users…"
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(placeholder, text: $text)
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

private struct HashtagRow: View {
    let tag: HashtagSummary
    var body: some View {
        HStack(spacing: 12) {
            if let s = tag.coverImageURL, let url = URL(string: s) {
                CachedSquare(url: url).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "number").foregroundColor(.gray))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(tag.tagLower)").font(.headline).foregroundColor(.white)
                Text("\(tag.usageCount.formattedWithSeparator()) uses").font(.subheadline).foregroundColor(.gray)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.gray)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// Verbose, fast user preview
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
            if !user.bio.trimmedLower().isEmpty {
                Text(user.bio).multilineTextAlignment(.center).foregroundColor(.white).padding(.horizontal)
            }
            UserBrandsStrip(userId: user.id)
            Button(action: onMessage) {
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

// Hashtag preview
private struct HashtagPreviewSheet: View {
    let tag: HashtagSummary

    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var mediaThumbs: [URL] = [] // small grid from recent posts

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("#\(tag.tagLower)").font(.title2).bold().foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal)

            Text("\(tag.usageCount.formattedWithSeparator()) uses")
                .foregroundColor(.gray)
                .padding(.horizontal)

            if isLoading {
                ProgressView().padding(.top, 8)
            } else if let error {
                Text(error).foregroundColor(.gray).padding(.horizontal)
            } else if mediaThumbs.isEmpty {
                Text("No recent media for this hashtag").foregroundColor(.gray).padding(.horizontal)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(mediaThumbs, id: \.absoluteString) { url in
                            CachedSquare(url: url)
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }
            }
            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: loadPreview)
    }

    private func loadPreview() {
        Task {
            do {
                if let urls = try await fetchFS(tagLower: tag.tagLower) {
                    await MainActor.run { mediaThumbs = urls; isLoading = false }
                    return
                }
                let urls = await fetchRTDB(tagLower: tag.tagLower)
                await MainActor.run { mediaThumbs = urls; isLoading = false }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // Firestore attempt
    private func fetchFS(tagLower: String) async throws -> [URL]? {
        let db = Firestore.firestore()
        let snap = try await db.collection("posts")
            .whereField("hashtagsLower", arrayContains: tagLower)
            .order(by: "createdAt", descending: true)
            .limit(to: 30)
            .getDocuments()

        var urls: [URL] = []
        for doc in snap.documents {
            let d = doc.data()
            if let s = (d["thumbURL"] as? String) ?? (d["imageURL"] as? String) ?? (d["mediaURL"] as? String),
               let u = URL(string: s) {
                urls.append(u)
            }
        }
        return urls.isEmpty ? nil : urls
    }

    // RTDB fallback: scan latest N posts (light cap), filter locally
    private func fetchRTDB(tagLower: String) async -> [URL] {
        let ref = Database.database().reference(withPath: "posts")
        let limit: UInt = 120
        return await withCheckedContinuation { cont in
            ref.queryOrdered(byChild: "timestamp")
                .queryLimited(toLast: limit)
                .observeSingleEvent(of: .value) { snap in
                    var out: [URL] = []
                    for case let cs as DataSnapshot in snap.children {
                        guard let d = cs.value as? [String: Any] else { continue }
                        let text = (d["text"] as? String)?.lowercased() ?? ""
                        guard text.contains("#\(tagLower)") else { continue }
                        if let s = (d["thumbURL"] as? String) ?? (d["imageURL"] as? String) ?? (d["mediaURL"] as? String),
                           let u = URL(string: s) {
                            out.append(u)
                        }
                    }
                    cont.resume(returning: Array(out.prefix(30)))
                }
        }
    }
}

// MARK: - Cached images

private struct CachedAvatar: View {
    let urlString: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let img = image { Image(uiImage: img).resizable().scaledToFill() }
            else { Circle().fill(Color(.systemGray5)).overlay(ProgressView()) }
        }
        .task(id: urlString ?? "") {
            guard let s = urlString, let url = URL(string: s) else { image = nil; return }
            ImageStore.shared.load(from: url, key: s) { img in
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
        }
    }
}

private struct CachedSquare: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let img = image { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).overlay(ProgressView()) }
        }
        .task(id: url.absoluteString) {
            ImageStore.shared.load(from: url, key: url.absoluteString) { img in
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
        }
    }
}

// MARK: - Live star badge (unchanged from your file)

private struct CircleSizeBadgeInline: View {
    let userId: String
    let initial: Int
    @State private var size: Int
    @State private var ref: DatabaseReference?
    @State private var handle: DatabaseHandle?
    init(userId: String, initial: Int) { self.userId = userId; self.initial = initial; _size = State(initialValue: initial) }
    var body: some View {
        Group {
            if size > 0 { StarBadgeInline(circleSize: size).transition(.opacity.combined(with: .scale)) }
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
    private func stop() { if let r = ref, let h = handle { r.removeObserver(withHandle: h) }; ref = nil; handle = nil }
}

// MARK: - Helpers

fileprivate func deriveUsername(fromName name: String, id: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let base = name.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined()
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
        return decoded
    } catch {
        log("❌ JSON bridge decode failed: \(error) | payload=\(compact)")
        return nil
    }
}

@inline(__always) private func log(_ message: String) {
    print("🔍 [Search] \(message)")
}

private extension String {
    func trimmedLower() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func hashtagStripped() -> String {
        trimmedLower().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
    var isBlank: Bool { trimmedLower().isEmpty }
}

private extension Int {
    func formattedWithSeparator() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// ---- Existing components kept from your file ----

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
                        Button("Close") { dismiss() }.padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundColor(.secondary)
                    .padding(.top, 10).padding(.trailing, 12)
            }
        }
        .background(Color.black)
    }
}

private struct EmptyStateView: View {
    let message: String
    var body: some View {
        VStack {
            Spacer()
            Text(message).foregroundColor(.gray).multilineTextAlignment(.center).padding()
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
            Text("Couldn’t load results").font(.headline).foregroundColor(.white)
            Text(message).foregroundColor(.gray).multilineTextAlignment(.center).padding(.horizontal)
            Button(action: onRetry) {
                Text("Retry").padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.blue).cornerRadius(10).foregroundColor(.white)
            }.padding(.top, 6)
        }
        .padding()
        .background(Color.black)
    }
}

// Minimal versions so the preview compiles even if you haven’t wired these yet.
// (You can swap these with your richer implementations later.)
private struct LivePreviewStarBadgeArea: View {
    let userId: String
    let initial: Int
    var body: some View {
        CircleSizeBadgeInline(userId: userId, initial: initial)
    }
}

private struct UserBrandsStrip: View {
    let userId: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Brands").font(.headline).foregroundColor(.white)
                Spacer()
            }
            Text("No brands yet").foregroundColor(.gray).font(.caption)
        }
        .padding(.horizontal)
    }
}
