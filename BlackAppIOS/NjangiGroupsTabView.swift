import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// MARK: - Model

struct NjangiGroupSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let contributionAmount: Double?
    let crestPath: String?
    let createdAt: Date?
}

// MARK: - Communities Tab

struct NjangiGroupsTabView: View {
    private let DEBUG_COMMUNITIES = true

    @State private var groups: [NjangiGroupSummary] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selectedGroup: NjangiGroupSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading your communities…")
                        .foregroundColor(.white)

                } else if let errorText {
                    ErrorStateView(
                        title: "Couldn’t load communities",
                        message: errorText,
                        retry: { Task { await loadMyGroups() } }
                    )

                } else if groups.isEmpty {
                    EmptyStateView()

                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("My Communities")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal)

                            VStack(spacing: 12) {
                                ForEach(groups) { group in
                                    Button {
                                        selectedGroup = group
                                    } label: {
                                        GroupCardView(group: group)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 22)
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .navigationTitle("Communities")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(item: $selectedGroup) { group in
            NjangiCommunityTerminalView(groupId: group.id, groupTitle: group.title)
        }
        .task {
            await loadMyGroups()
        }
    }

    // MARK: - Data loading

    @MainActor
    private func loadMyGroups() async {
        isLoading = true
        errorText = nil
        groups.removeAll()

        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            isLoading = false
            errorText = "You’re not signed in."
            return
        }

        let db = Firestore.firestore()

        func dlog(_ msg: String) {
            if DEBUG_COMMUNITIES { print(msg) }
        }

        do {
            dlog("🧩 [Communities] START loadMyGroups uid=\(uid)")

            var groupIds: [String] = []
            var ownerGroupIds: [String] = []
            var adminGroupIds: [String] = []
            
            // ----------------------------------------------------------
            // 1) Membership docs in njangiMemberships where userId == uid
            // ----------------------------------------------------------
            do {
                let membershipQueryA = try await db.collection("njangiMemberships")
                    .whereField("userId", isEqualTo: uid)
                    .getDocuments()

                dlog("🧩 [Communities] njangiMemberships where userId==uid -> \(membershipQueryA.documents.count) docs")

                for doc in membershipQueryA.documents {
                    let d = doc.data()
                    let gid =
                        (d["groupId"] as? String)
                        ?? (d["njangiGroupId"] as? String)
                        ?? (d["clubId"] as? String)
                        ?? (d["communityId"] as? String)

                    if let gid, !gid.isEmpty {
                        groupIds.append(gid)
                    } else {
                        dlog("⚠️ [Communities] membership doc \(doc.documentID) missing groupId-like field. keys=\(Array(d.keys).sorted())")
                    }
                }
            } catch {
                dlog("⚠️ [Communities] njangiMemberships userId query failed: \(error.localizedDescription)")
            }

            // ----------------------------------------------------------
            // 2) Membership docs in njangiMemberships where uid == uid
            // ----------------------------------------------------------
            do {
                let membershipQueryB = try await db.collection("njangiMemberships")
                    .whereField("uid", isEqualTo: uid)
                    .getDocuments()

                dlog("🧩 [Communities] njangiMemberships where uid==uid -> \(membershipQueryB.documents.count) docs")

                for doc in membershipQueryB.documents {
                    let d = doc.data()
                    let gid =
                        (d["groupId"] as? String)
                        ?? (d["njangiGroupId"] as? String)
                        ?? (d["clubId"] as? String)
                        ?? (d["communityId"] as? String)

                    if let gid, !gid.isEmpty {
                        groupIds.append(gid)
                    } else {
                        dlog("⚠️ [Communities] membership doc \(doc.documentID) missing groupId-like field. keys=\(Array(d.keys).sorted())")
                    }
                }
            } catch {
                dlog("⚠️ [Communities] njangiMemberships uid query failed: \(error.localizedDescription)")
            }

            
            // ----------------------------------------------------------
            // Admin groups: njangiGroups where adminIds contains uid
            // ----------------------------------------------------------
            do {
                let adminSnap = try await db.collection("njangiGroups")
                    .whereField("adminIds", arrayContains: uid)
                    .getDocuments()

                dlog("🧩 [Communities] njangiGroups where adminIds contains uid -> \(adminSnap.documents.count) docs")

                for doc in adminSnap.documents {
                    adminGroupIds.append(doc.documentID)
                }
            } catch {
                dlog("⚠️ [Communities] admin groups query failed: \(error.localizedDescription)")
            }
            
            // ----------------------------------------------------------
            // 3) Membership index doc njangiMemberships/{uid}
            // ----------------------------------------------------------
            do {
                let membershipIndexSnap = try await db.collection("njangiMemberships").document(uid).getDocument()
                dlog("🧩 [Communities] membership index doc njangiMemberships/\(uid) exists=\(membershipIndexSnap.exists)")

                if membershipIndexSnap.exists {
                    let data = membershipIndexSnap.data() ?? [:]
                    if let ids = data["groupIds"] as? [String] {
                        groupIds.append(contentsOf: ids)
                    } else if let ids = data["groups"] as? [String] {
                        groupIds.append(contentsOf: ids)
                    } else if let ids = data["njangiGroups"] as? [String] {
                        groupIds.append(contentsOf: ids)
                    } else if let ids = data["clubIds"] as? [String] {
                        groupIds.append(contentsOf: ids)
                    } else {
                        dlog("⚠️ [Communities] membership index doc exists but no known array key found. keys=\(Array(data.keys).sorted())")
                    }
                }
            } catch {
                dlog("⚠️ [Communities] membership index doc query failed: \(error.localizedDescription)")
            }

            // ----------------------------------------------------------
            // 4) Owned groups
            // ----------------------------------------------------------
            do {
                let ownerSnap = try await db.collection("njangiGroups")
                    .whereField("ownerId", isEqualTo: uid)
                    .getDocuments()

                dlog("🧩 [Communities] njangiGroups where ownerId==uid -> \(ownerSnap.documents.count) docs")

                for doc in ownerSnap.documents {
                    ownerGroupIds.append(doc.documentID)
                }
            } catch {
                dlog("⚠️ [Communities] owner groups query failed: \(error.localizedDescription)")
            }

            // ----------------------------------------------------------
            // 5) collectionGroup("members") union pass
            // ----------------------------------------------------------
            dlog("🧩 [Communities] collectionGroup(members) union pass")

            do {
                let snapA = try await db.collectionGroup("members")
                    .whereField("userId", isEqualTo: uid)
                    .getDocuments()

                dlog("🧩 [Communities] members where userId==uid -> \(snapA.documents.count) docs")

                for doc in snapA.documents {
                    if let groupId = doc.reference.parent.parent?.documentID {
                        groupIds.append(groupId)
                    }
                }
            } catch {
                dlog("⚠️ [Communities] members userId query failed: \(error.localizedDescription)")
            }

            do {
                let snapB = try await db.collectionGroup("members")
                    .whereField("uid", isEqualTo: uid)
                    .getDocuments()

                dlog("🧩 [Communities] members where uid==uid -> \(snapB.documents.count) docs")

                for doc in snapB.documents {
                    if let groupId = doc.reference.parent.parent?.documentID {
                        groupIds.append(groupId)
                    }
                }
            } catch {
                dlog("⚠️ [Communities] members uid query failed: \(error.localizedDescription)")
            }

            // ----------------------------------------------------------
            // 6) Web-like direct probe:
            //    For every group doc, check if members/{uid} exists
            // ----------------------------------------------------------
            do {
                let allGroupsSnap = try await db.collection("njangiGroups").getDocuments()
                dlog("🧩 [Communities] probing members/\(uid) across \(allGroupsSnap.documents.count) groups")

                for doc in allGroupsSnap.documents {
                    let gid = doc.documentID

                    // already owned? still fine, but probing is cheap enough
                    let memberDoc = try await db.collection("njangiGroups")
                        .document(gid)
                        .collection("members")
                        .document(uid)
                        .getDocument()

                    if memberDoc.exists {
                        groupIds.append(gid)
                    }
                }
            } catch {
                dlog("⚠️ [Communities] members/{uid} probe failed: \(error.localizedDescription)")
            }

            // ----------------------------------------------------------
            // 7) Merge + dedupe
            // ----------------------------------------------------------
            groupIds.append(contentsOf: ownerGroupIds)
            groupIds.append(contentsOf: adminGroupIds)

            groupIds = Array(Set(groupIds))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            dlog("🧩 [Communities] final merged groupIds count=\(groupIds.count) ids=\(groupIds)")

            if groupIds.isEmpty {
                dlog("🧩 [Communities] DONE -> no memberships found (show empty state)")
                isLoading = false
                return
            }

            // ----------------------------------------------------------
            // 8) Fetch group docs
            // ----------------------------------------------------------
            dlog("🧩 [Communities] fetching \(groupIds.count) docs from njangiGroups…")

            var loaded: [NjangiGroupSummary] = []

            for gid in groupIds {
                dlog("🧩 [Communities] fetch njangiGroups/\(gid)")
                let gSnap = try await db.collection("njangiGroups").document(gid).getDocument()

                guard gSnap.exists else {
                    dlog("⚠️ [Communities] missing doc: njangiGroups/\(gid)")
                    continue
                }

                let d = gSnap.data() ?? [:]

                let title =
                    (d["name"] as? String)
                    ?? (d["clubTitle"] as? String)
                    ?? (d["title"] as? String)
                    ?? "Community"

                let crestPath = d["crestPath"] as? String

                let contributionAmount: Double? = {
                    if let n = d["contributionPerRound"] as? Double { return n }
                    if let n = d["contributionPerRound"] as? Int { return Double(n) }
                    if let n = d["contributionPerRound"] as? NSNumber { return n.doubleValue }
                    if let s = d["contributionPerRound"] as? String, let v = Double(s) { return v }

                    if let n = d["contributionAmount"] as? Double { return n }
                    if let n = d["contributionAmount"] as? Int { return Double(n) }
                    if let n = d["contributionAmount"] as? NSNumber { return n.doubleValue }
                    if let s = d["contributionAmount"] as? String, let v = Double(s) { return v }

                    return nil
                }()

                let createdAt: Date? = {
                    if let ts = d["createdAt"] as? Timestamp { return ts.dateValue() }
                    if let ts = d["updatedAt"] as? Timestamp { return ts.dateValue() }
                    return nil
                }()

                loaded.append(
                    NjangiGroupSummary(
                        id: gid,
                        title: title,
                        contributionAmount: contributionAmount,
                        crestPath: crestPath,
                        createdAt: createdAt
                    )
                )
            }

            loaded.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            groups = loaded
            isLoading = false

            dlog("🧩 [Communities] DONE -> loaded groups=\(groups.count)")

        } catch {
            isLoading = false
            errorText = error.localizedDescription
            dlog("❌ [Communities] loadMyGroups error: \(error.localizedDescription)")
        }
    }
}

// MARK: - UI Components

private struct GroupCardView: View {
    let group: NjangiGroupSummary

    var body: some View {
        HStack(spacing: 12) {
            CrestBadgeView(crestPath: group.crestPath, title: group.title)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let amount = group.contributionAmount, amount > 0 {
                    Text("Contribution: $\(formatAmount(amount))")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                } else {
                    Text("Tap to open community")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func formatAmount(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct CrestBadgeView: View {
    let crestPath: String?
    let title: String

    @State private var crestURL: URL?
    @State private var loading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.gray.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let crestURL {
                AsyncImage(url: crestURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.white)
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(4)
                    case .failure:
                        initialsFallback
                    @unknown default:
                        initialsFallback
                    }
                }
            } else {
                initialsFallback
            }
        }
        .task {
            await resolveCrestURLIfNeeded()
        }
    }

    private var initialsFallback: some View {
        Text(initials(from: title))
            .font(.headline.bold())
            .foregroundColor(.white)
    }

    private func initials(from s: String) -> String {
        let parts = s.split(separator: " ").map(String.init)
        let a = parts.first?.first.map(String.init) ?? "N"
        let b = (parts.count > 1 ? parts[1].first.map(String.init) : nil) ?? ""
        return (a + b).uppercased()
    }

    private func resolveCrestURLIfNeeded() async {
        guard crestURL == nil, !loading else { return }
        guard let crestPath, !crestPath.isEmpty else { return }

        loading = true
        defer { loading = false }

        do {
            let ref = Storage.storage().reference(withPath: crestPath)
            let url = try await ref.downloadURL()
            await MainActor.run {
                crestURL = url
            }
        } catch {
            // silent fallback to initials
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.gray)

            Text("No communities yet")
                .font(.headline)
                .foregroundColor(.white)

            Text("Join or create a Njangi community from the Njangi mini-app, and it will show up here.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

private struct ErrorStateView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.yellow)

            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button(action: retry) {
                Text("Retry")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.12))
                    )
                    .foregroundColor(.white)
            }
            .padding(.top, 6)
        }
    }
}
