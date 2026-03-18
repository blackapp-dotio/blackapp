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
    let inviteCount: Int?

    init(id: String, name: String, username: String, bio: String = "", profileImageURL: String? = nil, inviteCount: Int? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.bio = bio
        self.profileImageURL = profileImageURL
        self.inviteCount = inviteCount
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

        var invites: Int? = nil
        if let n = dict["inviteCount"] as? NSNumber { invites = n.intValue }
        else if let n = dict["inviteCount"] as? Int { invites = n }
        else if let s = dict["inviteCount"] as? String, let n = Int(s) { invites = n }

        self.id = snapshot.key
        self.name = name
        self.username = uname.replacingOccurrences(of: " ", with: "")
        self.bio = bio
        self.profileImageURL = photo
        self.inviteCount = invites
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

enum SearchScope: String, CaseIterable, Identifiable {

    case all = "All"
    case people = "People"
    case hashtags = "Hashtags"
    var id: String { rawValue }
}

// MARK: - Search Screen

struct SearchView: View {

    // Query & state
    @State private var searchText: String
    @State private var scope: SearchScope

    init(initialQuery: String = "", initialScope: SearchScope = .all) {
        _searchText = State(initialValue: initialQuery)
        _scope = State(initialValue: initialScope)
    }

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
                                                print("🔍 [Search] Preview user tapped: \(user.id) @\(user.username)")
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
    private func searchUsersPrefix(q: String, limit: Int) async -> [UserProfile] {
        if let fs = try? await searchFirestorePrefix(q: q, limit: limit), !fs.isEmpty {
            return fs
        }
        let rtdb = await searchRTDBPrefix(q: q, limit: UInt(limit))
        return rtdb
    }

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
                let inviteCount = (d["inviteCount"] as? Int) ?? (d["inviteCount"] as? NSNumber)?.intValue
                    ?? Int((d["inviteCount"] as? String) ?? "")

                out[doc.documentID] = UserProfile(
                    id: doc.documentID,
                    name: name,
                    username: username.replacingOccurrences(of: " ", with: ""),
                    bio: bio,
                    profileImageURL: photo,
                    inviteCount: inviteCount
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
            if let connected = snap.value as? Bool { print("🔍 [Search] RTDB connected=\(connected)") }
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
            print("❌ ensurePendingContactsInFirestore error: \(error.localizedDescription)")
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
            print("❌ ensureDirectChatDoc error: \(error.localizedDescription)")
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
        } catch { print("❌ dmRequests write failed: \(error)") }
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
                    InviteCountStarBadgeInline(userId: user.id, initial: user.inviteCount ?? 0)
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

// =====================================================
// User preview + moderation + recent + brands + star power
// =====================================================

private struct UserPreviewSheet: View {
    let user: UserProfile
    var onMessage: () -> Void

    @State private var isReporting = false
    @State private var isBlocking  = false

    // Five recent media
    @State private var recentThumbs: [URL] = []
    @State private var loadingRecent = true
    @State private var recentError: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Header: avatar + identity + quick actions
            HStack(alignment: .center, spacing: 12) {
                CachedAvatar(urlString: user.profileImageURL)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(user.name)
                            .font(.title3).bold()
                            .foregroundColor(.white)
                        // Live badge near the name
                        LivePreviewStarBadgeArea(userId: user.id, initial: user.inviteCount ?? 0)

                    }
                    Text("@\(user.username)")
                        .foregroundColor(.gray)
                        .font(.subheadline)
                }

                Spacer()

                // Moderation + Message icons
                HStack(spacing: 12) {
                    Button { isReporting = true } label: {
                        Image(systemName: "flag.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .accessibilityLabel("Report user")
                    }
                    Button { isBlocking = true } label: {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3)
                            .foregroundColor(.red)
                            .accessibilityLabel("Block user")
                    }
                    Button(action: onMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .accessibilityLabel("Message user")
                    }
                }
            }
            .padding(.horizontal)

            // Bio (optional)
            if !user.bio.trimmedLower().isEmpty {
                Text(user.bio)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Star Power: level 0 = white, then rainbow with current highlighted
            StarPowerBarView(inviteCount: max(0, user.inviteCount ?? 0))

                .padding(.horizontal)

            // Brands (auto-fetch)
            UserBrandsStrip(userId: user.id)

            // Recent media strip (up to 5)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal)

                if loadingRecent {
                    ProgressView().padding(.horizontal)
                } else if let err = recentError {
                    Text(err).foregroundColor(.gray).font(.caption).padding(.horizontal)
                } else if recentThumbs.isEmpty {
                    Text("No recent posts").foregroundColor(.gray).font(.caption).padding(.horizontal)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recentThumbs, id: \.absoluteString) { url in
                                CachedSquare(url: url)
                                    .frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 20)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { Task { await loadRecentFiveNoIndex() } }

        // Moderation flows
        .confirmationDialog("Report \(user.name)?", isPresented: $isReporting, titleVisibility: .visible) {
            Button("Report for inappropriate content", role: .destructive) {
                Task { await reportUserProfile(userId: user.id, reason: "inappropriate") }
            }
            Button("Report for spam", role: .destructive) {
                Task { await reportUserProfile(userId: user.id, reason: "spam") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Block \(user.name)?", isPresented: $isBlocking) {
            Button("Block", role: .destructive) { Task { await blockUser(userId: user.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won’t be able to contact you or see your content.")
        }
    }

    // MARK: - Recent (5) with NO composite index
    private func loadRecentFiveNoIndex() async {
        loadingRecent = true
        recentError = nil
        do {
            if let urls = try await fetchRecentFSNoIndex(userId: user.id, need: 5), !urls.isEmpty {
                await MainActor.run {
                    self.recentThumbs = urls
                    self.loadingRecent = false
                }
                return
            }
            let urls = await fetchRecentRTDBNoIndex(userId: user.id, need: 5)
            await MainActor.run {
                self.recentThumbs = urls
                self.loadingRecent = false
            }
        } catch {
            await MainActor.run {
                self.recentError = error.localizedDescription
                self.loadingRecent = false
            }
        }
    }

    /// Firestore: order-only (no composite index), then filter by userId on client.
    private func fetchRecentFSNoIndex(userId: String, need: Int) async throws -> [URL]? {
        let db = Firestore.firestore()
        var found: [URL] = []
        for size in [30, 60, 120, 240] {
            let snap = try await db.collection("posts")
                .order(by: "createdAt", descending: true)
                .limit(to: size)
                .getDocuments()

            for doc in snap.documents {
                guard let dUserId = doc.data()["userId"] as? String, dUserId == userId else { continue }
                if let s = (doc.data()["thumbURL"] as? String)
                    ?? (doc.data()["imageURL"] as? String)
                    ?? (doc.data()["mediaURL"] as? String),
                   let u = URL(string: s) {
                    found.append(u)
                    if found.count >= need { return Array(found.prefix(need)) }
                }
            }
            if found.count >= need { break }
        }
        return found.isEmpty ? nil : Array(found.prefix(need))
    }

    /// RTDB fallback: read recent window and filter by userId locally.
    private func fetchRecentRTDBNoIndex(userId: String, need: Int) async -> [URL] {
        let ref = Database.database().reference(withPath: "posts")
        let lastN: UInt = 300
        return await withCheckedContinuation { cont in
            ref.queryOrdered(byChild: "timestamp")
                .queryLimited(toLast: lastN)
                .observeSingleEvent(of: .value) { snap in
                    var candidates: [(ts: TimeInterval, url: URL)] = []
                    for case let cs as DataSnapshot in snap.children {
                        guard let d = cs.value as? [String: Any] else { continue }
                        guard (d["userId"] as? String) == userId else { continue }
                        let ts = (d["timestamp"] as? TimeInterval) ?? 0
                        if let s = (d["thumbURL"] as? String)
                            ?? (d["imageURL"] as? String)
                            ?? (d["mediaURL"] as? String),
                           let u = URL(string: s) {
                            candidates.append((ts, u))
                        }
                    }
                    let top = candidates.sorted { $0.ts > $1.ts }.prefix(need).map { $0.url }
                    cont.resume(returning: top)
                }
        }
    }

    // MARK: - Moderation actions

    private func reportUserProfile(userId: String, reason: String) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        let doc = db.collection("reports").document()
        let payload: [String: Any] = [
            "type": "profile",
            "reportedUserId": userId,
            "reason": reason,
            "byUserId": me,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "open"
        ]
        do { try await doc.setData(payload) } catch {
            print("❌ reportUserProfile failed: \(error.localizedDescription)")
        }
    }

    // Firestore + RTDB mirror for block / unblock
    private func blockUser(userId: String) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()

        // 1) Firestore
        do {
            try await db.collection("blocks")
                .document(me)
                .collection("blocked")
                .document(userId)
                .setData([
                    "blockedAt": FieldValue.serverTimestamp(),
                    "userId": userId
                ], merge: true)
        } catch {
            print("❌ blockUser (Firestore) failed: \(error.localizedDescription)")
        }

        // 2) RTDB mirror
        let r = Database.database().reference()
            .child("blocks").child(me).child("blocked").child(userId)

        await withCheckedContinuation { cont in
            r.setValue([
                "userId": userId,
                "blockedAt": ServerValue.timestamp()
            ]) { error, _ in
                if let error = error {
                    print("⚠️ RTDB block mirror failed: \(error.localizedDescription)")
                }
                cont.resume()
            }
        }
    }
}

// MARK: - UserBrandsStrip (auto-fetches; FS first, RTDB fallback)

private struct UserBrandsStrip: View {
    let userId: String

    // Optional injected (kept for compatibility)
    var brands: [BrandSummary] = []
    var loading: Bool = false

    @State private var liveBrands: [BrandSummary] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String? = nil

    init(userId: String, brands: [BrandSummary]? = nil, loading: Bool? = nil) {
        self.userId = userId
        if let b = brands { self.brands = b }
        if let l = loading { self.loading = l }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Brands").font(.headline).foregroundColor(.white)
                Spacer()
            }

            let useInjected = !brands.isEmpty || loading
            let effectiveLoading = useInjected ? loading : isLoading
            let effectiveBrands  = useInjected ? brands  : liveBrands

            if effectiveLoading {
                ProgressView().tint(.white.opacity(0.8))
            } else if let err = loadError {
                Text(err).foregroundColor(.gray).font(.caption)
            } else if effectiveBrands.isEmpty {
                Text("No brands yet").foregroundColor(.gray).font(.caption)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(effectiveBrands, id: \.id) { brand in
                            HStack(spacing: 8) {
                                if let s = brand.logoURL, let url = URL(string: s) {
                                    CachedSquare(url: url)
                                        .frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 40, height: 40)
                                        .overlay(Image(systemName: "briefcase.fill").foregroundColor(.gray))
                                }
                                Text(brand.name)
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .onAppear {
            if brands.isEmpty && !loading {
                Task { await fetchBrandsForUser() }
            }
        }
    }

    private func fetchBrandsForUser() async {
        await MainActor.run { isLoading = true; loadError = nil; liveBrands = [] }
        do {
            if let fs = try await fetchBrandsFS(userId: userId), !fs.isEmpty {
                await MainActor.run { liveBrands = fs; isLoading = false }
                return
            }
            let rtdb = await fetchBrandsRTDB(userId: userId)
            await MainActor.run { liveBrands = rtdb; isLoading = false }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func fetchBrandsFS(userId: String) async throws -> [BrandSummary]? {
        let db = Firestore.firestore()
        var out: [BrandSummary] = []

        // A) Subcollection under user
        do {
            let snap = try await db.collection("users").document(userId).collection("brands").getDocuments()
            for doc in snap.documents {
                let d = doc.data()
                let name = (d["name"] as? String) ?? ""
                guard !name.isEmpty else { continue }
                let logo = d["logoURL"] as? String
                let approved = (d["isApproved"] as? Bool) ?? false
                out.append(.init(id: doc.documentID, name: name, logoURL: logo, isApproved: approved))
            }
        } catch { /* ignore */ }

        // B) Top-level with ownerId filter
        if out.isEmpty {
            do {
                let snap = try await db.collection("brands").whereField("ownerId", isEqualTo: userId).getDocuments()
                for doc in snap.documents {
                    let d = doc.data()
                    let name = (d["name"] as? String) ?? ""
                    guard !name.isEmpty else { continue }
                    let logo = d["logoURL"] as? String
                    let approved = (d["isApproved"] as? Bool) ?? false
                    out.append(.init(id: doc.documentID, name: name, logoURL: logo, isApproved: approved))
                }
            } catch { /* ignore */ }
        }

        return out.isEmpty ? nil : out
    }

    private func fetchBrandsRTDB(userId: String) async -> [BrandSummary] {
        let ref = Database.database().reference(withPath: "users/\(userId)/brands")
        return await withCheckedContinuation { cont in
            ref.observeSingleEvent(of: .value) { snap in
                var out: [BrandSummary] = []
                for case let cs as DataSnapshot in snap.children {
                    if let d = cs.value as? [String: Any] {
                        let name = (d["name"] as? String) ?? ""
                        if name.isEmpty { continue }
                        let logo = d["logoURL"] as? String
                        let approved = (d["isApproved"] as? Bool) ?? false
                        out.append(.init(id: cs.key, name: name, logoURL: logo, isApproved: approved))
                    }
                }
                cont.resume(returning: out)
            }
        }
    }
}

// MARK: - Cached images (AsyncImage – no custom cache dependency)
/*
private struct CachedAvatar: View {
    let urlString: String?
    var body: some View {
        ZStack {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView()
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure: Circle().fill(Color(.systemGray5)).overlay(Image(systemName: "person.crop.circle.fill").font(.title).foregroundColor(.gray))
                    @unknown default: ProgressView()
                    }
                }
            } else {
                Circle().fill(Color(.systemGray5))
                    .overlay(Image(systemName: "person.crop.circle.fill").font(.title).foregroundColor(.gray))
            }
        }
    }
} */

private struct CachedSquare: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty: RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).overlay(ProgressView())
            case .success(let img): img.resizable().scaledToFill()
            case .failure: RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).overlay(Image(systemName: "photo").foregroundColor(.gray))
            @unknown default: RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5))
            }
        }
    }
}

// MARK: - Live star badge (kept)

private struct InviteCountStarBadgeInline: View {
    let userId: String
    let initial: Int

    @State private var invites: Int
    @State private var ref: DatabaseReference?
    @State private var handle: DatabaseHandle?

    init(userId: String, initial: Int) {
        self.userId = userId
        self.initial = initial
        _invites = State(initialValue: initial)
    }

    var body: some View {
        let tier = deriveTier(fromInviteCount: invites)
        Group {
            Image(systemName: "star.fill")
                .foregroundColor(colorForTier(tier))
                .font(.caption2)
                .transition(.opacity.combined(with: .scale))
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        let r = Database.database().reference().child("users").child(userId).child("inviteCount")
        ref = r
        handle = r.observe(.value) { snap in
            if let n = snap.value as? NSNumber { invites = n.intValue }
            else if let n = snap.value as? Int { invites = n }
            else if let s = snap.value as? String, let n = Int(s) { invites = n }
        }
    }

    private func stop() {
        if let r = ref, let h = handle { r.removeObserver(withHandle: h) }
        ref = nil
        handle = nil
    }
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
        print("❌ JSON bridge decode failed: \(error) | payload=\(compact)")
        return nil
    }
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

// ---- Existing components kept ----

private struct ChatLaunchContainer: View, Identifiable {
    let id = UUID()
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

// Minimal Hashtag preview

private struct HashtagPreviewSheet: View {
    let tag: HashtagSummary

    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var mediaThumbs: [URL] = []

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

// MARK: - Empty / Error views

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
            Text("Couldn’t load results")
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

/// Minimal wrapper so your inline badge in the preview compiles.
private struct LivePreviewStarBadgeArea: View {
    let userId: String
    let initial: Int
    var body: some View {
        InviteCountStarBadgeInline(userId: userId, initial: initial)
    }
}


// =====================================================
// StarPowerBarView (level 0 = white, then rainbow; current highlighted)
// =====================================================

private struct StarPowerBarView: View {
    let inviteCount: Int

    // Same thresholds as Profile: 0,5,10,20,40,80,160,320,640
    private let tiers: [(name: String, threshold: Int)] = [
        ("white", 0),
        ("red", 5),
        ("orange", 10),
        ("yellow", 20),
        ("green", 40),
        ("blue", 80),
        ("indigo", 160),
        ("violet", 320),
        ("black", 640)
    ]

    private var currentTier: String {
        deriveTier(fromInviteCount: inviteCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Star Power")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 10) {
                ForEach(tiers, id: \.name) { t in
                    let achieved = inviteCount >= t.threshold
                    let isCurrent = (t.name == currentTier)

                    Image(systemName: achieved ? "star.fill" : "star")
                        .font(.system(size: isCurrent ? 20 : 18, weight: isCurrent ? .bold : .regular))
                        .foregroundColor(colorForTier(t.name))
                        .opacity(achieved ? 1.0 : 0.30)
                        .scaleEffect(isCurrent ? 1.05 : 1.0)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
    }
}


fileprivate func deriveTier(fromInviteCount inviteCount: Int) -> String {
    if inviteCount >= 640 { return "black" }
    if inviteCount >= 320 { return "violet" }
    if inviteCount >= 160 { return "indigo" }
    if inviteCount >= 80  { return "blue" }
    if inviteCount >= 40  { return "green" }
    if inviteCount >= 20  { return "yellow" }
    if inviteCount >= 10  { return "orange" }
    if inviteCount >= 5   { return "red" }
    return "white"
}

fileprivate func colorForTier(_ tier: String) -> Color {
    switch tier.lowercased() {
    case "white": return .white
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "indigo": return .indigo
    case "violet": return .purple
    case "black": return .black
    default: return .gray
    }
}

