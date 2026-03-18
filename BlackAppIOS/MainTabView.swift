import SwiftUI
import Firebase
import Combine
import FirebaseMessaging
import FirebaseAuth
import FirebaseDatabase
import FirebaseFirestore

struct MainTabView: View {
    @ObservedObject var router = NotificationRouter.shared

    // 🔒 User Agreement gate
    @AppStorage("acceptedEULA_v1") private var acceptedEULA = false

    // Existing event deep-link state
    @State private var showEventDetailFromLink = false
    @State private var selectedEvent: EventModel?

    // Nightlife deep-link state
    @State private var showNightlifeVenue = false
    @State private var deepLinkedVenue: VenueModel?
    @State private var deepLinkedNightId: String?
    @State private var deepLinkedTableId: String?
    @State private var showGuestlistSheet = false

    // Admin-only dashboard
    @State private var showAdminDashboard = false
    @State private var isAdminUser = false

    // Addressable TabView so we can jump between tabs programmatically
    private enum Tab: Int { case gossip = 0, events, explore, communities, profile, passport }
    @State private var selectedTab: Tab = .gossip

    // SETTINGS STATE
    @State private var showSettings = false
    @State private var showBlockedUsers = false
    @State private var deletingAccount = false
    @State private var deleteError: String?

    // BLACKAPPMONEY STATE
    @State private var showBlackAppMoney = false

    // Global search sheet
    @State private var showGlobalSearch = false

    // Fix: explicit binding to avoid generic parameter inference issue in .alert
    private var hasDeleteError: Binding<Bool> {
        Binding<Bool>(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    var body: some View {
        Group {
            if acceptedEULA {
                mainAppContent
            } else {
                EULAGateView()
            }
        }
    }

    // MARK: - Main App Content
    private var mainAppContent: some View {
        ZStack {

            // Nightlife venue push (from deep-link)
            NavigationLink(
                destination: deepLinkedVenue.map {
                    NightlifeVenueWrapper(
                        venue: $0,
                        preselectNightId: deepLinkedNightId,
                        preselectTableId: deepLinkedTableId,
                        presentGuestlist: $showGuestlistSheet
                    )
                },
                isActive: $showNightlifeVenue
            ) { EmptyView() }
            .hidden()

            // Admin dashboard push – admins only
            NavigationLink(
                destination: AdminDashboardViewPlaceholder(),
                isActive: $showAdminDashboard
            ) { EmptyView() }
            .hidden()

            // ✅ Main tabs
            TabView(selection: $selectedTab) {
                GossipTabView()
                    .tabItem { Label("Feed", systemImage: "quote.bubble") }
                    .tag(Tab.gossip)

                EventTabView()
                    .tabItem { Label("Events", systemImage: "calendar") }
                    .tag(Tab.events)

                ExploreTabView()
                    .tabItem { Image(systemName: "globe"); Text("Explore") }
                    .tag(Tab.explore)

                // ✅ IMPORTANT: use your new NjangiGroupsTabView.swift
                NjangiGroupsTabView()
                    .tabItem { Label("Communities", systemImage: "person.3.sequence.fill") }
                    .tag(Tab.communities)

                ProfileTabView()
                    .tabItem { Image(systemName: "person.crop.circle"); Text("Profile") }
                    .tag(Tab.profile)

                PassportTabView()
                    .tabItem { Image(systemName: "person.text.rectangle"); Text("Passport") }
                    .tag(Tab.passport)
            }
            .accentColor(.blue)

            // ✅ UNIVERSAL TOP TOOLBAR
            .safeAreaInset(edge: .top, spacing: 0) {
                TopToolbarView(
                    onLogoTap: {
                        NotificationCenter.default.post(name: .globalLogoTapped, object: nil)
                    },
                    onSearchTap: {
                        showGlobalSearch = true
                        NotificationCenter.default.post(name: .globalSearchTapped, object: nil)
                    },
                    adminButton: isAdminUser
                        ? AnyView(
                            Button(action: { showAdminDashboard = true }) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        )
                        : nil,
                    onMoneyTap: {
                        showBlackAppMoney = true
                    }
                )
                .background(Color.black.ignoresSafeArea(edges: .top))
                .zIndex(999)
            }

            // MARK: Lifecycle / routing hooks
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("👀 MainTabView appeared. Delayed FCM sync triggered")
                    FCMTokenManager.syncFCMTokenToFirestore()
                    _ = TokenSyncMonitor.shared
                    TokenSyncMonitor.shared.startRecurringCheck(every: 3600)
                }
                refreshIsAdminFlag()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                print("🔄 App re-entered foreground. Syncing FCM token...")
                syncPushNotificationToken()
                _ = TokenSyncMonitor.shared
                refreshIsAdminFlag()
            }

            // ✅ KEEP: open event from deep link
            .onReceive(NotificationCenter.default.publisher(for: .openEventFromDeepLink)) { notif in
                if let eventId = notif.userInfo?["eventId"] as? String {
                    fetchEventModel(eventId: eventId) { model in
                        if let model = model {
                            selectedEvent = model
                            showEventDetailFromLink = true
                        }
                    }
                }
            }

            // MARK: Global sheets / modals
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                selectedTab = .profile
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openBlockedUsers)) { _ in
                selectedTab = .profile
                showBlockedUsers = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openBlackAppMoney)) { _ in
                showBlackAppMoney = true
            }

            .sheet(isPresented: $showEventDetailFromLink) {
                if let event = selectedEvent {
                    EventDetailView(event: event)
                }
            }
            .sheet(isPresented: $showGuestlistSheet) {
                if let nightId = deepLinkedNightId {
                    GuestListView(nightId: nightId)
                } else {
                    Text("Select a night to join the guest list")
                        .padding()
                }
            }

            // ✅ Settings Sheet
            .sheet(isPresented: $showSettings) {
                SettingsSheet(
                    close: { showSettings = false },
                    openBlockedUsers: {
                        showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showBlockedUsers = true
                        }
                    },
                    startDeletion: { confirmDeleteAccount() }
                )
            }

            // ✅ Manage Blocked Users
            .sheet(isPresented: $showBlockedUsers) {
                ManageBlockedUsersView(close: { showBlockedUsers = false })
            }

            // ✅ BlackAppMoney sheet
            .sheet(isPresented: $showBlackAppMoney) {
                BlackAppMoneyView()
            }

            // ✅ Global search
            .sheet(isPresented: $showGlobalSearch) {
                NavigationStack {
                    SearchView()
                        .navigationTitle("Search")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showGlobalSearch = false }
                            }
                        }
                }
            }

            // ✅ Deletion progress + errors
            .alert("Deleting Account…", isPresented: $deletingAccount) {
                Button("OK") { }
            } message: {
                Text("Please wait while we securely delete your account.")
            }
            .alert("Delete Account Failed", isPresented: hasDeleteError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    // MARK: - Token Sync
    private func syncPushNotificationToken() {
        print("🟡 syncPushNotificationToken() triggered")
        guard let userId = Auth.auth().currentUser?.uid else { return }

        Messaging.messaging().token { token, error in
            if let error = error {
                print("❌ Failed to retrieve FCM token: \(error.localizedDescription)")
                return
            }
            guard let token = token else {
                print("❌ Retrieved FCM token is nil")
                return
            }
            let ref = Firestore.firestore().collection("users").document(userId)
            ref.setData([
                "fcmToken": token,
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true) { error in
                if let error = error {
                    print("❌ Error saving FCM token: \(error.localizedDescription)")
                } else {
                    print("✅ FCM token saved to Firestore")
                }
            }
        }
    }

    // MARK: - Fetch Event Model (RTDB)
    private func fetchEventModel(eventId: String, completion: @escaping (EventModel?) -> Void) {
        let ref = Database.database().reference().child("events").child(eventId)
        ref.observeSingleEvent(of: .value, with: { snapshot in
            completion(EventModel.from(snapshot: snapshot))
        })
    }

    // MARK: - Admin flag (RTDB: /admins and /superadmin)
    private func refreshIsAdminFlag() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isAdminUser = false
            return
        }

        let db = Database.database().reference()
        let adminsRef = db.child("admins").child(uid)
        let superRef = db.child("superadmin").child(uid)

        adminsRef.observeSingleEvent(of: .value) { aSnap in
            superRef.observeSingleEvent(of: .value) { sSnap in
                let isAdmin = (aSnap.value as? Bool) == true || (sSnap.value as? Bool) == true
                self.isAdminUser = isAdmin
            }
        }
    }

    // MARK: - Deep-link handling
    private func handleIncomingURL(_ url: URL) {
        let absolute = url.absoluteString
        print("🔗 OpenURL: \(absolute)")

        // Admin dashboard route (admins only)
        if absolute.contains("/admin/dashboard") {
            if isAdminUser {
                showAdminDashboard = true
            } else {
                print("⛔️ Non-admin attempted to open admin dashboard; ignoring")
            }
            return
        }

        guard absolute.contains("/nightlife/venue/") || absolute.contains("://nightlife/venue/") else {
            return
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return }

        let venueId = parts[2]
        let nightId = comps?.queryItems?.first(where: { $0.name == "nightId" })?.value
        let tableId = comps?.queryItems?.first(where: { $0.name == "tableId" })?.value
        let guestlistFlag = (comps?.queryItems?.first(where: { $0.name == "guestlist" })?.value?.lowercased() == "true")

        fetchVenue(venueId: venueId) { venue in
            guard let venue = venue else {
                print("❌ Deep-link venue not found: \(venueId)")
                return
            }
            self.deepLinkedVenue = venue
            self.deepLinkedNightId = nightId
            self.deepLinkedTableId = tableId
            self.showNightlifeVenue = true

            if guestlistFlag {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.showGuestlistSheet = true
                }
            }
        }
    }

    // MARK: - Minimal venue fetch (Nightlife)
    private func fetchVenue(venueId: String, completion: @escaping (VenueModel?) -> Void) {
        let ref = Database.database().reference().child("venues").child(venueId)
        ref.observeSingleEvent(of: .value) { snap in
            completion(VenueModel.from(snap))
        }
    }

    // MARK: - Settings helpers
    private func confirmDeleteAccount() {
        let alert = UIAlertController(
            title: "Delete Account?",
            message: "This will permanently delete your BlackApp account and related data. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
            Task { await deleteAccountCascade() }
        }))
        UIApplication.shared.topMostController?.present(alert, animated: true)
    }

    @MainActor
    private func deleteAccountCascade() async {
        guard let user = Auth.auth().currentUser else { return }
        deletingAccount = true
        defer { deletingAccount = false }

        let uid = user.uid
        do {
            try await clearPushToken(uid: uid)
            try await deleteUserDocuments(uid: uid)
            try await user.delete()
            try? Auth.auth().signOut()
        } catch {
            let nsErr = error as NSError
            if nsErr.code == AuthErrorCode.requiresRecentLogin.rawValue {
                deleteError = "For your security, please re-authenticate (log out and back in) and try deleting again."
            } else {
                deleteError = "Could not delete account: \(nsErr.localizedDescription)"
            }
        }
    }

    private func clearPushToken(uid: String) async throws {
        let ref = Firestore.firestore().collection("users").document(uid)
        try await ref.setData([
            "fcmToken": FieldValue.delete(),
            "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    private func deleteUserDocuments(uid: String) async throws {
        let fs = Firestore.firestore()
        try await fs.collection("users").document(uid).delete()

        let rtdb = Database.database().reference()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            rtdb.child("users").child(uid).removeValue { err, _ in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    // MARK: - NightlifeVenueWrapper
    private struct NightlifeVenueWrapper: View {
        let venue: VenueModel
        let preselectNightId: String?
        let preselectTableId: String?
        @Binding var presentGuestlist: Bool

        @State private var nights: [NightModel] = []
        @State private var selectedNight: NightModel?

        var body: some View {
            VenueDetailView(venue: venue)
                .onAppear {
                    NightlifeService.shared.fetchNights(for: venue.id) { list in
                        self.nights = list
                        if let target = preselectNightId,
                           let n = list.first(where: { $0.id == target }) {
                            self.selectedNight = n
                        }
                    }
                }
        }
    }

    // MARK: - Settings Sheet UI
    private struct SettingsSheet: View {
        var close: () -> Void
        var openBlockedUsers: () -> Void
        var startDeletion: () -> Void

        @State private var pushEnabled = true
        @State private var loading = false
        @State private var errorText: String?

        var body: some View {
            NavigationView {
                List {
                    Section(header: Text("Account")) {
                        Button { openBlockedUsers() } label: {
                            Label("Manage Blocked Users", systemImage: "eye.slash")
                        }

                        Button(role: .destructive) { startDeletion() } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }

                    Section(header: Text("Notifications")) {
                        Toggle(isOn: $pushEnabled) {
                            Label("Enable Push Notifications", systemImage: "bell.badge")
                        }
                        .onChange(of: pushEnabled) { newValue in
                            Task { await savePushPreference(enabled: newValue) }
                        }
                    }

                    Section(header: Text("Legal")) {
                        Link(destination: URL(string: "https://blackapp.io/privacy.html")!) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                        Link(destination: URL(string: "https://blackapp.io/terms.html")!) {
                            Label("Terms of Service", systemImage: "doc.plaintext")
                        }
                    }

                    Section {
                        Button { Task { await signOut() } } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { close() }
                    }
                }
                .overlay {
                    if loading { ProgressView().controlSize(.large) }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorText ?? "")
                }
                .task { await loadPushPreference() }
            }
        }

        private func loadPushPreference() async {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            loading = true
            defer { loading = false }
            do {
                let doc = try await Firestore.firestore().collection("users").document(uid).getDocument()
                if let enabled = doc.data()?["pushEnabled"] as? Bool {
                    pushEnabled = enabled
                }
            } catch {
                errorText = "Failed to load settings: \(error.localizedDescription)"
            }
        }

        private func savePushPreference(enabled: Bool) async {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            do {
                try await Firestore.firestore().collection("users").document(uid).setData([
                    "pushEnabled": enabled,
                    "settingsUpdatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } catch {
                errorText = "Failed to save: \(error.localizedDescription)"
            }
        }

        private func signOut() async {
            do {
                try Auth.auth().signOut()
                close()
            } catch {
                errorText = "Failed to sign out: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Simple Blocked Users Manager
    private struct ManageBlockedUsersView: View {
        var close: () -> Void
        @State private var blocked: [String] = []
        @State private var loading = true
        @State private var errorText: String?

        var body: some View {
            NavigationView {
                Group {
                    if loading {
                        ProgressView()
                    } else if blocked.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.exclam")
                                .font(.system(size: 40))
                            Text("No blocked users")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        List {
                            ForEach(blocked, id: \.self) { uid in
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 24))
                                    Text(uid).lineLimit(1)
                                    Spacer()
                                    Button(role: .destructive) {
                                        Task { await unblock(uid) }
                                    } label: { Text("Unblock") }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Blocked Users")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { close() }
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: { Text(errorText ?? "") }
                .task { await loadBlocked() }
            }
        }

        private func loadBlocked() async {
            guard let me = Auth.auth().currentUser?.uid else { return }
            loading = true
            defer { loading = false }
            let ref = Database.database().reference().child("blockedUsers").child(me)
            await withCheckedContinuation { cont in
                ref.observeSingleEvent(of: .value) { snap in
                    if let dict = snap.value as? [String: Any] {
                        self.blocked = dict.keys.sorted()
                    } else {
                        self.blocked = []
                    }
                    cont.resume()
                }
            }
        }

        private func unblock(_ other: String) async {
            guard let me = Auth.auth().currentUser?.uid else { return }
            let ref = Database.database().reference().child("blockedUsers").child(me).child(other)
            await withCheckedContinuation { cont in
                ref.removeValue { error, _ in
                    if let error = error {
                        self.errorText = "Failed to unblock: \(error.localizedDescription)"
                    } else {
                        self.blocked.removeAll(where: { $0 == other })
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - AdminDashboard placeholder
    private struct AdminDashboardViewPlaceholder: View {
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40, weight: .semibold))
                Text("Admin Dashboard")
                    .font(.title3).bold()
                Text("Admins only. Promoters cannot access this area.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
    }

    // MARK: - Promoter helper
    private func isPromoter(_ completion: @escaping (Bool) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(false); return }
        let db = Database.database().reference()
        db.child("promoters").child(uid).observeSingleEvent(of: .value) { snap in
            completion(snap.exists())
        }
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openBlockedUsers = Notification.Name("openBlockedUsers")
    static let openBlackAppMoney = Notification.Name("openBlackAppMoney")
    static let globalSearchTapped = Notification.Name("globalSearchTapped")
    static let globalLogoTapped = Notification.Name("globalLogoTapped")
}

// MARK: - UIKit helper
extension UIApplication {
    var topMostController: UIViewController? {
        guard let scene = connectedScenes.first as? UIWindowScene else { return nil }
        guard let key = scene.windows.first(where: { $0.isKeyWindow }) else { return nil }
        var top = key.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
