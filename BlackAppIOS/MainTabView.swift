import SwiftUI
import Firebase
import Combine
import FirebaseMessaging
import FirebaseAuth
import FirebaseDatabase

struct MainTabView: View {
    @ObservedObject var router = NotificationRouter.shared

    // Existing event deep-link state
    @State private var showEventDetailFromLink = false
    @State private var selectedEvent: EventModel?

    // Nightlife deep-link state
    @State private var showNightlifeVenue = false
    @State private var deepLinkedVenue: VenueModel?
    @State private var deepLinkedNightId: String?
    @State private var deepLinkedTableId: String?
    @State private var showGuestlistSheet = false

    // Admin-only dashboard (reserved)
    @State private var showAdminDashboard = false
    @State private var isAdminUser = false

    var body: some View {
        ZStack {
            // Navigate to direct chat if tapped (existing)
            NavigationLink(
                destination: router.selectedChatUser.map { DirectChatRoomView(recipient: $0) },
                isActive: Binding(
                    get: { router.selectedChatUser != nil },
                    set: { newValue in if !newValue { router.selectedChatUser = nil } }
                )
            ) { EmptyView() }.hidden()

            // Nightlife venue push (from deep-link)
            NavigationLink(
                destination: deepLinkedVenue.map { NightlifeVenueWrapper(venue: $0,
                                                                         preselectNightId: deepLinkedNightId,
                                                                         preselectTableId: deepLinkedTableId,
                                                                         presentGuestlist: $showGuestlistSheet) },
                isActive: $showNightlifeVenue
            ) { EmptyView() }.hidden()

            // (Reserved) Admin dashboard push – admins only
            NavigationLink(
                destination: AdminDashboardViewPlaceholder(), // Replace with your real AGDashboard entry view
                isActive: $showAdminDashboard
            ) { EmptyView() }.hidden()

            // Main tabs (existing)
            TabView {
                GossipTabView()
                    .tabItem { Label("Gossip", systemImage: "quote.bubble") }

                EventTabView()
                    .tabItem { Label("Events", systemImage: "calendar") }

                ExploreTabView()
                    .tabItem { Image(systemName: "globe"); Text("Explore") }

                ChatTabView()
                    .tabItem { Label("Chat", systemImage: "message") }

                ProfileTabView()
                    .tabItem { Image(systemName: "person.crop.circle"); Text("Profile") }
            }
            .accentColor(.blue)
            .onAppear {
                // Existing FCM sync / monitors
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("👀 MainTabView appeared. Delayed FCM sync triggered")
                    FCMTokenManager.syncFCMTokenToFirestore()
                    _ = TokenSyncMonitor.shared
                    TokenSyncMonitor.shared.startRecurringCheck(every: 3600)
                }
                // Cache admin bit for later
                refreshIsAdminFlag()
            }
            .onOpenURL { url in
                // Handle *both* your legacy event links (already wired via NotificationCenter)
                // and new Nightlife/Admin deep-links here
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                print("🔄 App re-entered foreground. Syncing FCM token...")
                syncPushNotificationToken()
                _ = TokenSyncMonitor.shared
                refreshIsAdminFlag()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NotificationTapped"))) { notif in
                if let userInfo = notif.userInfo,
                   let senderId = userInfo["senderId"] as? String {
                    print("📬 Notification tapped for senderId: \(senderId)")
                    fetchUserProfile(uid: senderId) { profile in
                        if let profile = profile { router.selectedChatUser = profile }
                        else { print("❌ No user found for senderId \(senderId)") }
                    }
                }
            }
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
        }
    }

    // MARK: - Token Sync (existing)

    func syncPushNotificationToken() {
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

    // MARK: - Fetch Chat User Profile (existing)

    func fetchUserProfile(uid: String, completion: @escaping (ChatUserProfile?) -> Void) {
        let ref = Firestore.firestore().collection("users").document(uid)
        ref.getDocument { doc, _ in
            if let data = doc?.data(),
               let name = data["name"] as? String {
                let username = data["username"] as? String ?? ""
                let image = data["profileImageURL"] as? String
                completion(ChatUserProfile(id: uid, name: name, username: username, profileImageURL: image))
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - Fetch Event Model (fixed: no nested function)

    func fetchEventModel(eventId: String, completion: @escaping (EventModel?) -> Void) {
        let ref = Database.database().reference().child("events").child(eventId)
        ref.observeSingleEvent(of: .value, with: { snapshot in
            completion(EventModel.from(snapshot: snapshot))
        })
    }

    // MARK: - Admin flag (RTDB: /admins and /superadmin)

    func refreshIsAdminFlag() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isAdminUser = false; return
        }
        let db = Database.database().reference()
        let adminsRef = db.child("admins").child(uid)
        let superRef = db.child("superadmin").child(uid)

        // Read both and set true if either exists == true
        adminsRef.observeSingleEvent(of: .value) { aSnap in
            superRef.observeSingleEvent(of: .value) { sSnap in
                let isAdmin = (aSnap.value as? Bool) == true || (sSnap.value as? Bool) == true
                self.isAdminUser = isAdmin
            }
        }
    }

    // MARK: - Deep-link handling

    func handleIncomingURL(_ url: URL) {
        // Support both custom scheme and universal links
        // Expected patterns:
        // - blackappios://nightlife/venue/<venueId>?nightId=&tableId=&guestlist=true
        // - https://blackapp.app/nightlife/venue/<venueId>?nightId=&tableId=&guestlist=true
        // - (reserved) https://blackapp.app/admin/dashboard  (admins only)

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
            // Not a nightlife deep-link; your existing handlers can manage it
            return
        }

        // Parse path & query
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path // e.g., /nightlife/venue/<venueId>
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return }

        // parts[0] = "nightlife", parts[1] = "venue", parts[2] = "<venueId>"
        let venueId = parts[2]

        let nightId = comps?.queryItems?.first(where: { $0.name == "nightId" })?.value
        let tableId = comps?.queryItems?.first(where: { $0.name == "tableId" })?.value
        let guestlistFlag = (comps?.queryItems?.first(where: { $0.name == "guestlist" })?.value?.lowercased() == "true")

        // Fetch venue then navigate
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
                // Present guestlist sheet after push
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.showGuestlistSheet = true
                }
            }
        }
    }

    // MARK: - Minimal venue fetch (Nightlife)

    func fetchVenue(venueId: String, completion: @escaping (VenueModel?) -> Void) {
        let ref = Database.database().reference().child("venues").child(venueId)
        ref.observeSingleEvent(of: .value) { snap in
            completion(VenueModel.from(snap))
        }
    }
}

// MARK: - NightlifeVenueWrapper
// Wraps VenueDetailView and optionally preselects night/table or opens guestlist
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
                // Preload nights to help user land closer to target (non-invasive)
                NightlifeService.shared.fetchNights(for: venue.id) { list in
                    self.nights = list
                    if let target = preselectNightId,
                       let n = list.first(where: { $0.id == target }) {
                        self.selectedNight = n
                        // At this point, VenueDetailView owns its selection UI.
                        // If you want hard preselection in the view itself, add a binding to VenueDetailView.
                    }
                }
            }
    }
}

// MARK: - AdminDashboard placeholder
// Replace with your real dashboard entry view. Protected by isAdminUser guard above.
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
func isPromoter(_ completion: @escaping (Bool) -> Void) {
    guard let uid = Auth.auth().currentUser?.uid else { completion(false); return }
    let db = Database.database().reference()
    db.child("promoters").child(uid).observeSingleEvent(of: .value) { snap in
        completion(snap.exists())
    }
}
