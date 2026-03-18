//
//  EventModule.swift
//  BlackAppIOS
//
//  Single-file Events module (RTDB + Stripe payments)
//
//  Key goals:
//  - MyEvents shows ONLY events created by user (purchases live in Passport/Wallet elsewhere)
//  - Event creation/editing uses Stripe payout destination (acct_...) (PayPal removed)
//  - Stripe card payment flow supports requires_action (3DS/SCA) via backend createTransaction/finalizeTransaction
//

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import WebKit
import UIKit
import Foundation
import Stripe

// MARK: - File-scope helpers

fileprivate func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

fileprivate func formattedDate(_ date: Date) -> String {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    return df.string(from: date)
}

// MARK: - topMostController helper (FILE SCOPE)

private func topMostController(base: UIViewController? = {
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .sorted { ($0.activationState == .foregroundActive) && ($1.activationState != .foregroundActive) }
    let keyWin = scenes.first?.windows.first(where: { $0.isKeyWindow })
    return keyWin?.rootViewController
}()) -> UIViewController? {
    if let nav = base as? UINavigationController { return topMostController(base: nav.visibleViewController) }
    if let tab = base as? UITabBarController { return topMostController(base: tab.selectedViewController) }
    if let presented = base?.presentedViewController { return topMostController(base: presented) }
    return base
}

private func presentSystemShare(_ items: [Any]) {
    DispatchQueue.main.async {
        guard let top = topMostController() else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }
}

// MARK: - Stripe 3DS Authentication Context (FILE SCOPE)

fileprivate final class StripeAuthContext: NSObject, ObservableObject, STPAuthenticationContext {
    private weak var presenter: UIViewController?

    func refreshPresenterIfNeeded() {
        DispatchQueue.main.async {
            self.presenter = topMostController()
        }
    }

    func authenticationPresentingViewController() -> UIViewController {
        if let p = presenter { return p }
        let top = topMostController()
        presenter = top
        return top ?? UIViewController()
    }
}

// MARK: - Stripe destination validation (FILE SCOPE)

fileprivate func validateStripeDestinationAccount(
    _ acctRaw: String,
    platformStripeAccountId: String,
    errs: inout [String]
) {
    let cleaned = acctRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    if cleaned.isEmpty {
        errs.append("Please enter a Stripe Account ID for payouts.")
        return
    }
    if !cleaned.hasPrefix("acct_") {
        errs.append("That doesn’t look like a Stripe account id. It should start with acct_.")
        return
    }

    let platform = platformStripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !platform.isEmpty, cleaned == platform {
        errs.append("You can’t use BlackApp’s platform Stripe account for payouts. Connect your own Stripe account in BlackAppMoney.")
    }
}

// MARK: - EventModel (RTDB) — Stripe-only forward, legacy-safe decode + multi-image support

struct EventModel: Identifiable, Equatable {
    var id: String
    var title: String
    var description: String

    // Legacy cover image (kept for backward compatibility)
    var imagePath: String

    // NEW: swipe gallery support (cover + additional images)
    var imagePaths: [String]

    var date: Date
    var userId: String
    var location: String

    // Canonical Stripe payout destination (Connected Account)
    var stripeAccountId: String

    // Legacy-safe fields (keep for old nodes / older code paths)
    var payoutMethod: String
    var payoutDetails: String

    // Commerce
    var ticketPrice: Double
    var ticketQuantity: Int
    var tablePrice: Double
    var tableQuantity: Int

    // Stats
    var ticketsSold: Int
    var tablesSold: Int
    var isFree: Bool

    static func from(snapshot: DataSnapshot) -> EventModel? {
        guard let value = snapshot.value as? [String: Any] else { return nil }

        let title = (value["title"] as? String) ?? (value["name"] as? String) ?? ""
        let description = (value["description"] as? String) ?? ""

        // Legacy single path
        let legacyImagePath = (value["imagePath"] as? String) ?? ""

        // NEW: decode multi-image gallery (supports multiple possible RTDB shapes)
        let decodedImagePaths: [String] = decodeImagePaths(value["imagePaths"])  // returns [] if not present/invalid

        // Choose effective cover + effective paths (legacy-safe)
        let effectivePaths: [String] = {
            // Prefer explicit imagePaths if present
            if !decodedImagePaths.isEmpty {
                return decodedImagePaths
            }
            // Fall back to legacy single imagePath
            let p = legacyImagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? [] : [p]
        }()

        let coverImagePath: String = {
            // Prefer first gallery image as cover if available
            if let first = effectivePaths.first {
                return first
            }
            // Otherwise legacy value (could be empty)
            return legacyImagePath
        }()

        let userId = (value["userId"] as? String) ?? ""
        let location = (value["location"] as? String) ?? ""

        let ts = toTimeInterval(value["date"]) ?? toTimeInterval(value["timestamp"]) ?? 0

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // IMPORTANT:
        // Previously you required imagePath to exist, which blocks any future “text-only” events.
        // For events, you still want at least ONE image — now we validate against effectivePaths.
        guard !effectivePaths.isEmpty else { return nil }

        let payoutMethod = ((value["payoutMethod"] as? String) ?? "").lowercased()
        let payoutDetails = (value["payoutDetails"] as? String) ?? ""

        let stripeAccountId =
            (value["stripeAccountId"] as? String)
            ?? ((payoutMethod == "stripe") ? payoutDetails : "")
            ?? ""

        let ticketPrice = toDouble(value["ticketPrice"])
        let ticketQuantity = toInt(value["ticketQuantity"])
        let tablePrice = toDouble(value["tablePrice"])
        let tableQuantity = toInt(value["tableQuantity"])

        let ticketsSold = toInt(value["ticketsSold"])
        let tablesSold = toInt(value["tablesSold"])

        let isFreeStored = (value["isFree"] as? Bool)
        let derivedFree = (ticketPrice <= 0 && tablePrice <= 0)
        let isFree = isFreeStored ?? derivedFree

        return EventModel(
            id: snapshot.key,
            title: title,
            description: description,
            imagePath: coverImagePath,
            imagePaths: effectivePaths,
            date: Date(timeIntervalSince1970: ts),
            userId: userId,
            location: location,
            stripeAccountId: stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines),
            payoutMethod: payoutMethod,
            payoutDetails: payoutDetails,
            ticketPrice: ticketPrice,
            ticketQuantity: ticketQuantity,
            tablePrice: tablePrice,
            tableQuantity: tableQuantity,
            ticketsSold: ticketsSold,
            tablesSold: tablesSold,
            isFree: isFree
        )
    }

    func rtdbPayloadForSave() -> [String: Any] {
        let acct = stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize: ensure cover imagePath matches first imagePaths element if available.
        let normalizedPaths: [String] = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cover: String = {
            if let first = normalizedPaths.first { return first }
            let legacy = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            return legacy
        }()

        var payload: [String: Any] = [
            "id": id,
            "title": title,
            "description": description,
            "date": date.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,

            "payoutMethod": "stripe",
            "stripeAccountId": acct,
            "payoutDetails": acct, // legacy-safe

            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,

            // Always keep legacy cover field
            "imagePath": cover,

            "userId": userId,
            "location": location,

            "isFree": (ticketPrice <= 0 && tablePrice <= 0)
        ]

        // Only write imagePaths if we actually have them (prevents noisy schema writes).
        // If you want to ALWAYS write it, remove the if-check and set it to [cover] when empty.
        if !normalizedPaths.isEmpty {
            payload["imagePaths"] = normalizedPaths
        }

        return payload
    }

    // MARK: - Helpers

    /// Supports RTDB imagePaths stored as:
    /// - [String]
    /// - NSDictionary of { "0": "...", "1": "..." } (common when arrays saved via RTDB)
    /// - [Any] where elements are String
    private static func decodeImagePaths(_ raw: Any?) -> [String] {
        if let arr = raw as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arrAny = raw as? [Any] {
            let out = arrAny.compactMap { $0 as? String }
            return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let dict = raw as? [String: Any] {
            // Sort numeric keys if possible: "0","1","2"... else fallback lexical.
            let keys = dict.keys.sorted { a, b in
                let ia = Int(a) ?? Int.max
                let ib = Int(b) ?? Int.max
                if ia != ib { return ia < ib }
                return a < b
            }
            let out: [String] = keys.compactMap { k in dict[k] as? String }
            return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return []
    }

    private static func toDouble(_ val: Any?) -> Double {
        switch val {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(cleaned) ?? 0.0
        default:
            return 0.0
        }
    }

    private static func toInt(_ val: Any?) -> Int {
        switch val {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String:
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(cleaned) ?? Int(Double(cleaned) ?? 0)
        default:
            return 0
        }
    }

    private static func toTimeInterval(_ val: Any?) -> TimeInterval? {
        switch val {
        case let t as TimeInterval: return t
        case let d as Double: return d
        case let i as Int: return TimeInterval(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return TimeInterval(cleaned) ?? Double(cleaned)
        default:
            return nil
        }
    }
}

// MARK: - PurchaseModel (minimal, for stats/check-in lists)
/*
struct PurchaseModel: Identifiable, Equatable {
    let id: String
    let userId: String
    let eventId: String
    let eventTitle: String
    let eventImagePath: String
    let quantity: Int
    let type: String
    let totalAmount: Double
    let timestamp: TimeInterval
}

// MARK: - ImagePicker (UIKit bridge)

struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) private var presentationMode
    @Binding var selectedImage: UIImage?

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImage = image
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
*/
// MARK: - EventImageView (Firebase Storage path -> downloadURL -> Data)

struct EventImageView: View {
    let imagePath: String
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var fetchAttempted = false

    var body: some View {
        ZStack {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if isLoading {
                ProgressView("Loading…")
            } else {
                Rectangle()
                    .foregroundColor(.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.white)
                            .font(.title)
                    )
            }
        }
        .frame(height: 200)
        .clipped()
        .cornerRadius(10)
        .onAppear {
            guard !fetchAttempted else { return }
            fetchAttempted = true
            fetchImage()
        }
    }

    private func fetchImage() {
        guard !imagePath.isEmpty else { isLoading = false; return }
        let storageRef = Storage.storage().reference(withPath: imagePath)
        storageRef.downloadURL { url, error in
            if let url = url {
                loadImageData(from: url)
            } else {
                print("❌ EventImageView downloadURL error:", error?.localizedDescription ?? "unknown")
                DispatchQueue.main.async { isLoading = false }
            }
        }
    }

    private func loadImageData(from url: URL, retries: Int = 3) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data = data, error == nil {
                DispatchQueue.main.async {
                    self.imageData = data
                    self.isLoading = false
                }
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadImageData(from: url, retries: retries - 1)
                }
            } else {
                print("❌ EventImageView dataTask error:", error?.localizedDescription ?? "unknown")
                DispatchQueue.main.async { self.isLoading = false }
            }
        }.resume()
    }
}

// MARK: - UserAvatarView + UserNameView (fix missing symbols)

struct UserAvatarView: View {
    let userId: String
    @State private var imageURL: String? = nil
    @State private var initials: String = "?"

    var body: some View {
        Group {
            if let url = imageURL, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .onAppear { loadProfile() }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Text(initials)
                    .foregroundColor(.black)
                    .font(.caption.weight(.semibold))
            )
    }

    private func loadProfile() {
        let ref = Database.database().reference().child("users").child(userId)
        ref.observeSingleEvent(of: .value) { snap in
            if let dict = snap.value as? [String: Any] {
                DispatchQueue.main.async {
                    self.imageURL = dict["profileImageURL"] as? String
                    if let name = dict["name"] as? String, !name.isEmpty {
                        self.initials = name.split(separator: " ")
                            .compactMap { $0.first }
                            .prefix(2)
                            .map { String($0).uppercased() }
                            .joined()
                    }
                }
            }
        }
    }
}

struct UserNameView: View {
    let userId: String
    @State private var name: String = "User"

    var body: some View {
        Text(name)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .onAppear { loadName() }
    }

    private func loadName() {
        let ref = Database.database().reference().child("users").child(userId).child("name")
        ref.observeSingleEvent(of: .value) { snap in
            let s = (snap.value as? String) ?? "User"
            DispatchQueue.main.async { self.name = s.isEmpty ? "User" : s }
        }
    }
}

// MARK: - EventCardView (minimal, consistent + uses EventImageView)
/*
struct EventCardView: View {
    let event: EventModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EventImageView(imagePath: event.imagePath)
                .frame(height: 180)
                .cornerRadius(12)

            Text(event.title)
                .font(.headline)
                .foregroundColor(.white)

            Text("\(event.location) • \(formattedDate(event.date))")
                .font(.caption)
                .foregroundColor(.gray)

            if !event.description.isEmpty {
                Text(event.description)
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
*/
// MARK: - EventTabView (segmented All / My Events)

struct EventTabView: View {
    @State private var selectedTab = 0
    @State private var showCreate = false

    @State private var isPromoterUser = false
    @State private var showPromoterSheet = false
    @State private var showNightlife = false

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 8) {
                    Picker("View", selection: $selectedTab) {
                        Text("All Events").tag(0)
                        Text("My Events").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if selectedTab == 0 {
                        EventFeedView()
                    } else {
                        MyEventsView()
                    }
                }

                // Floating create button
                VStack {
                    Spacer()
                    HStack {
                        Button(action: { showCreate = true }) {
                            Image(systemName: "plus")
                                .font(.title2)
                                .padding()
                                .background(Circle().fill(Color.blue))
                                .foregroundColor(.white)
                                .shadow(radius: 6)
                        }
                        .padding(.leading, 16)
                        Spacer()
                    }
                    .padding(.bottom, 10)
                }
            }
            .navigationBarTitle("Events", displayMode: .inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showNightlife = true }) { Image(systemName: "sparkles") }
                    if isPromoterUser {
                        Button(action: { showPromoterSheet = true }) { Image(systemName: "star.fill") }
                    }
                }
            }
            .sheet(isPresented: $showCreate) { CreateEventView() }
            .sheet(isPresented: $showPromoterSheet) { PromoterDashboardView() }
            .sheet(isPresented: $showNightlife) { NightlifeHomeView() }
        }
        .onAppear { refreshPromoterFlag() }
    }

    private func refreshPromoterFlag() {
        guard let uid = Auth.auth().currentUser?.uid else {
            isPromoterUser = false
            return
        }
        Database.database().reference().child("promoters").child(uid)
            .observeSingleEvent(of: .value) { snap in
                DispatchQueue.main.async { self.isPromoterUser = snap.exists() }
            }
    }
}

// MARK: - EventFeedView (simple RTDB feed -> EventDetail)
/*
struct EventFeedView: View {
    @State private var events: [EventModel] = []
    @State private var isLoading = false
    @State private var err: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    ProgressView("Loading events…").padding()
                } else if let err = err {
                    Text(err).foregroundColor(.red).padding()
                } else if events.isEmpty {
                    Text("No events yet.").foregroundColor(.gray).padding()
                } else {
                    ForEach(events) { event in
                        NavigationLink(destination: EventDetailView(event: event)) {
                            EventCardView(event: event)
                                .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { fetchEvents() }
    }

    private func fetchEvents() {
        isLoading = true
        err = nil
        Database.database().reference().child("events")
            .observeSingleEvent(of: .value) { snapshot in
                var list: [EventModel] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let e = EventModel.from(snapshot: child) {
                        // hide past events
                        if e.date.timeIntervalSinceNow >= -3600 { list.append(e) }
                    }
                }
                list.sort { $0.date > $1.date }
                DispatchQueue.main.async {
                    self.events = list
                    self.isLoading = false
                }
            } withCancel: { error in
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.err = error.localizedDescription
                }
            }
    }
} */
// MARK: - MyEventsView (Creator-only) — purchased events live elsewhere (Passport)

struct MyEventsView: View {
    @State private var myCreatedEvents: [EventModel] = []
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var selectedEventToEdit: EventModel?
    @State private var selectedEventForStats: EventModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if isLoading {
                    loadingCard
                } else if let err = loadError {
                    errorCard(err)
                } else if myCreatedEvents.isEmpty {
                    emptyState
                } else {
                    ForEach(myCreatedEvents) { event in
                        creatorEventCard(event)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { fetchMyEvents() }

        .sheet(item: $selectedEventToEdit) { event in
            EditEventView(event: event)
        }
        .sheet(item: $selectedEventForStats) { event in
            EventStatsView(event: event)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Events I’ve Created")
                .font(.title2).bold()
                .foregroundColor(.white)

            Text("Purchases and tickets live in Passport/Wallet. This tab only shows events you created.")
                .font(.footnote)
                .foregroundColor(.gray)

            HStack(spacing: 10) {
                Button { fetchMyEvents() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()

                Text(isLoading ? "Loading" : "\(myCreatedEvents.count)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading your events…")
                .font(.footnote)
                .foregroundColor(.gray)
            Spacer()
        }
        .padding()
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t load your events")
                .font(.headline)
                .foregroundColor(.white)

            Text(message)
                .font(.footnote)
                .foregroundColor(.red.opacity(0.95))

            Button { fetchMyEvents() } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.25), in: Capsule())
                    .foregroundColor(.white)
            }
            .padding(.top, 6)
        }
        .padding()
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No created events yet")
                .font(.headline)
                .foregroundColor(.white)

            Text("Create your first event from the Events feed. You can edit/delete/view stats here.")
                .font(.footnote)
                .foregroundColor(.gray)

            Button { fetchMyEvents() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding()
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func creatorEventCard(_ event: EventModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EventCardView(event: event)

            HStack(spacing: 10) {
                actionChip(title: "Edit", systemImage: "pencil", bg: Color.orange.opacity(0.85)) {
                    selectedEventToEdit = event
                }
                actionChip(title: "Stats", systemImage: "chart.bar.fill", bg: Color.blue.opacity(0.85)) {
                    selectedEventForStats = event
                }
                Spacer()
                actionChip(title: "Delete", systemImage: "trash", bg: Color.red.opacity(0.85)) {
                    deleteEvent(event)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func actionChip(title: String, systemImage: String, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bg, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fetchMyEvents() {
        guard let userId = Auth.auth().currentUser?.uid else {
            self.loadError = "You must be signed in."
            return
        }

        isLoading = true
        loadError = nil

        Database.database().reference().child("events")
            .observeSingleEvent(of: .value) { snapshot in
                var created: [EventModel] = []
                for case let child as DataSnapshot in snapshot.children {
                    if let event = EventModel.from(snapshot: child), event.userId == userId {
                        // hide past events
                        if event.date.timeIntervalSinceNow >= -3600 { created.append(event) }
                    }
                }
                created.sort { $0.date > $1.date }

                DispatchQueue.main.async {
                    self.myCreatedEvents = created
                    self.isLoading = false
                }
            } withCancel: { error in
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadError = error.localizedDescription
                }
            }
    }

    private func deleteEvent(_ event: EventModel) {
        Database.database().reference().child("events").child(event.id)
            .removeValue { error, _ in
                DispatchQueue.main.async {
                    if let error = error {
                        self.loadError = "Failed to delete. \(error.localizedDescription)"
                    } else {
                        self.myCreatedEvents.removeAll { $0.id == event.id }
                    }
                }
            }
    }
}

import SwiftUI
import UIKit
import PhotosUI
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase

// =====================================================================
// MARK: - MultiImagePicker (real multi-select) — iOS 14+ (PhotosUI)
// =====================================================================
struct MultiImagePicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    var selectionLimit: Int = 0 // 0 = unlimited

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = selectionLimit
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MultiImagePicker
        init(_ parent: MultiImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else { return }

            var out: [UIImage] = []
            let group = DispatchGroup()

            for r in results {
                if r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                        defer { group.leave() }
                        if let img = obj as? UIImage {
                            out.append(img)
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                // Append new images (cover is always first overall)
                self.parent.images.append(contentsOf: out)
            }
        }
    }
}

// Small helper for thumbnails
fileprivate struct _Thumb: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 72)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// =====================================================================
// MARK: - CreateEventView (Stripe payout; REAL multi-image upload)
// IMPORTANT: EventModel should include `imagePaths: [String]` and decode it.
// Schema written:
// - imagePath: String (legacy cover path, always first)
// - imagePaths: [String] (gallery, first = cover)
// =====================================================================
struct CreateEventView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var title = ""
    @State private var description = ""
    @State private var selectedDate = Date()
    @State private var location = ""

    @State private var profileStripeAccountId: String = ""
    @State private var platformStripeAccountId: String = ""
    @State private var stripeAccountId: String = ""

    @State private var ticketPrice: Double = 0
    @State private var ticketQuantity: Int = 0
    @State private var tablePrice: Double = 0
    @State private var tableQuantity: Int = 0

    // ✅ Multi-image selection (cover is images[0])
    @State private var selectedImages: [UIImage] = []
    @State private var isUploading = false
    @State private var showMultiPicker = false

    @State private var formErrors: [String] = []
    @State private var showErrorAlert = false

    var body: some View {
        NavigationView {
            Form {
                if !formErrors.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Please fix the following:")
                                .font(.subheadline).bold()
                            ForEach(formErrors, id: \.self) { msg in
                                Text("• \(msg)").font(.footnote)
                            }
                        }
                        .foregroundColor(.red)
                    }
                }

                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Location", text: $location)
                    TextField("Event Description", text: $description)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }

                Section(header: Text("Event Images")) {
                    if selectedImages.isEmpty {
                        Text("Add at least 1 image. The first image will be the cover.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Cover: first image • Swipe gallery in feed")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { idx, img in
                                        ZStack(alignment: .topTrailing) {
                                            _Thumb(image: img)

                                            // index badge
                                            Text(idx == 0 ? "Cover" : "\(idx+1)")
                                                .font(.caption2)
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.black.opacity(0.6), in: Capsule())
                                                .padding(6)

                                            // remove button
                                            Button {
                                                selectedImages.remove(at: idx)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.white)
                                                    .shadow(radius: 2)
                                            }
                                            .padding(6)
                                            .offset(x: 6, y: -6)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            if selectedImages.count > 1 {
                                Text("Tip: Add menus / sections / extra details as additional images.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Button(selectedImages.isEmpty ? "Select Event Images" : "Add More Images") {
                        showMultiPicker = true
                    }
                }

                Section(header: Text("Payout (Stripe)")) {
                    TextField("Stripe Account ID (acct_...)", text: $stripeAccountId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if !profileStripeAccountId.isEmpty {
                        Text("Detected on profile: \(profileStripeAccountId)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        Button("Use my connected Stripe account") {
                            stripeAccountId = profileStripeAccountId
                        }
                        .font(.caption)
                    }

                    if !platformStripeAccountId.isEmpty {
                        Text("Note: platform Stripe account cannot be used as payout destination.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Ticket Sales")) {
                    TextField("Ticket Price (USD)", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Ticket Quantity", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    TextField("Table Price (USD)", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Table Quantity", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                if isUploading {
                    ProgressView("Uploading…")
                } else {
                    Button("Create Event") { createEvent() }
                }
            }
            .navigationTitle("Create New Event")
            .sheet(isPresented: $showMultiPicker) {
                MultiImagePicker(images: $selectedImages, selectionLimit: 0)
            }
            .disabled(isUploading)
            .overlay {
                if isUploading {
                    ZStack {
                        Color.black.opacity(0.05).ignoresSafeArea()
                        ProgressView("Uploading…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
            }
            .alert("Can’t Create Event", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(formErrors.map { "• \($0)" }.joined(separator: "\n"))
            }
            .onAppear { loadStripeDefaults() }
        }
    }

    private func loadStripeDefaults() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Database.database().reference()
        let group = DispatchGroup()

        var profile = ""
        var platform = ""

        group.enter()
        db.child("users").child(uid).child("stripeAccountId")
            .observeSingleEvent(of: .value) { snap in
                profile = (snap.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                group.leave()
            }

        group.enter()
        db.child("config").child("stripePlatformAccountId")
            .observeSingleEvent(of: .value) { snap in
                platform = (snap.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                group.leave()
            }

        group.notify(queue: .main) {
            self.profileStripeAccountId = profile
            self.platformStripeAccountId = platform

            if self.stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               profile.hasPrefix("acct_") {
                self.stripeAccountId = profile
            }
        }
    }

    private func validateForm() -> [String] {
        var errs: [String] = []

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please enter an event title.") }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please enter a location.") }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please add a short description.") }

        // ✅ Multi-image requirement: at least 1
        if selectedImages.isEmpty { errs.append("Please select at least 1 image (cover).") }

        validateStripeDestinationAccount(
            stripeAccountId,
            platformStripeAccountId: platformStripeAccountId,
            errs: &errs
        )

        if ticketPrice < 0 || tablePrice < 0 { errs.append("Prices can’t be negative.") }
        if ticketQuantity < 0 || tableQuantity < 0 { errs.append("Quantities can’t be negative.") }
        if ticketPrice > 0 && ticketQuantity == 0 { errs.append("Set ticket quantity for paid tickets.") }
        if tablePrice > 0 && tableQuantity == 0 { errs.append("Set table quantity for paid tables.") }

        return errs
    }

    private func createEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let errs = validateForm()
        guard errs.isEmpty else {
            formErrors = errs
            showErrorAlert = true
            return
        }

        isUploading = true

        uploadEventImages(selectedImages) { uploadedPaths in
            guard let uploadedPaths = uploadedPaths, !uploadedPaths.isEmpty else {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.formErrors = ["We couldn’t upload your images. Check your connection and try again."]
                    self.showErrorAlert = true
                }
                return
            }

            // Legacy cover + gallery
            let coverPath = uploadedPaths[0]
            saveEventData(coverImagePath: coverPath, imagePaths: uploadedPaths, userId: userId)
        }
    }

    // ✅ Upload multiple images and return Storage paths in the same order as selectedImages
    private func uploadEventImages(_ images: [UIImage], completion: @escaping ([String]?) -> Void) {
        // Defensive trim (should already be validated)
        let imgs = images
        guard !imgs.isEmpty else { completion(nil); return }

        var uploaded: [String?] = Array(repeating: nil, count: imgs.count)
        var firstError: String? = nil
        let group = DispatchGroup()

        for (idx, img) in imgs.enumerated() {
            group.enter()

            guard let data = img.jpegData(compressionQuality: 0.82) else {
                firstError = firstError ?? "We couldn’t read one of the selected images. Try another."
                group.leave()
                continue
            }

            let imageID = UUID().uuidString
            let path = "eventImages/\(imageID).jpg"
            let storageRef = Storage.storage().reference().child(path)
            let meta = StorageMetadata()
            meta.contentType = "image/jpeg"

            storageRef.putData(data, metadata: meta) { _, error in
                defer { group.leave() }
                if let error = error {
                    firstError = firstError ?? "Image upload failed. (\(error.localizedDescription))"
                    return
                }
                uploaded[idx] = path
            }
        }

        group.notify(queue: .main) {
            if let msg = firstError {
                self.formErrors = [msg]
                self.showErrorAlert = true
            }
            let final = uploaded.compactMap { $0 }
            completion(final.isEmpty ? nil : final)
        }
    }

    private func saveEventData(coverImagePath: String, imagePaths: [String], userId: String) {
        let ref = Database.database().reference().child("events").childByAutoId()
        let eventId = ref.key ?? UUID().uuidString
        let acct = stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedPaths = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "id": eventId,
            "title": title,
            "description": description,
            "date": selectedDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,

            "payoutMethod": "stripe",
            "stripeAccountId": acct,
            "payoutDetails": acct, // legacy-safe

            "location": location,
            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,

            // ✅ Legacy + Gallery
            "imagePath": coverImagePath,
            "imagePaths": cleanedPaths,

            "userId": userId,
            "isFree": (ticketPrice <= 0 && tablePrice <= 0)
        ]

        ref.setValue(payload) { error, _ in
            DispatchQueue.main.async {
                self.isUploading = false
                if let error = error {
                    self.formErrors = ["We couldn’t save your event. (\(error.localizedDescription))"]
                    self.showErrorAlert = true
                } else {
                    self.presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }
}

// =====================================================================
// MARK: - EditEventView (Stripe payout; REAL gallery edit)
// Behavior:
// - Shows existing images (from event.imagePaths fallback to [event.imagePath])
// - Allows removing existing images (does NOT delete Storage objects; it just stops referencing them)
// - Allows adding new images (uploads + appends)
// - Ensures there is always at least 1 image (cover = first in final list)
// - Writes: imagePath (cover) + imagePaths (gallery)
// =====================================================================
struct EditEventView: View {
    @Environment(\.presentationMode) private var presentationMode
    let event: EventModel

    @State private var title: String
    @State private var description: String
    @State private var selectedDate: Date
    @State private var location: String

    @State private var profileStripeAccountId: String = ""
    @State private var platformStripeAccountId: String = ""
    @State private var stripeAccountId: String

    @State private var ticketPrice: Double
    @State private var ticketQuantity: Int
    @State private var tablePrice: Double
    @State private var tableQuantity: Int

    // Existing gallery paths (user can remove/reorder later if you choose)
    @State private var keptImagePaths: [String]

    // New images to add
    @State private var newImages: [UIImage] = []
    @State private var showMultiPicker = false

    @State private var isUploading = false
    @State private var formErrors: [String] = []
    @State private var showErrorAlert = false

    init(event: EventModel) {
        self.event = event
        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description)
        _location = State(initialValue: event.location)
        _selectedDate = State(initialValue: event.date)
        _stripeAccountId = State(initialValue: event.stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines))
        _ticketPrice = State(initialValue: event.ticketPrice)
        _ticketQuantity = State(initialValue: event.ticketQuantity)
        _tablePrice = State(initialValue: event.tablePrice)
        _tableQuantity = State(initialValue: event.tableQuantity)

        // ✅ Needs EventModel.imagePaths. If you haven’t added it yet, add it now.
        // Backward compatible fallback is handled by the model decode.
        let base = event.imagePaths.isEmpty ? [event.imagePath] : event.imagePaths
        _keptImagePaths = State(initialValue: base
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                if !formErrors.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Please fix the following:")
                                .font(.subheadline).bold()
                            ForEach(formErrors, id: \.self) { msg in
                                Text("• \(msg)").font(.footnote)
                            }
                        }
                        .foregroundColor(.red)
                    }
                }

                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Description", text: $description)
                    TextField("Event Location", text: $location)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }

                Section(header: Text("Event Images")) {
                    if keptImagePaths.isEmpty && newImages.isEmpty {
                        Text("You must have at least 1 image.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        // Existing paths (from Storage)
                        if !keptImagePaths.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Current images (tap X to remove). First = cover.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(keptImagePaths.enumerated()), id: \.offset) { idx, path in
                                            ZStack(alignment: .topTrailing) {
                                                EventImageView(imagePath: path)
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 72, height: 72)
                                                    .clipped()
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                                Text(idx == 0 ? "Cover" : "\(idx+1)")
                                                    .font(.caption2)
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.black.opacity(0.6), in: Capsule())
                                                    .padding(6)

                                                Button {
                                                    keptImagePaths.remove(at: idx)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.white)
                                                        .shadow(radius: 2)
                                                }
                                                .padding(6)
                                                .offset(x: 6, y: -6)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        // New images to be uploaded
                        if !newImages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("New images to add (will be uploaded).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(newImages.enumerated()), id: \.offset) { idx, img in
                                            ZStack(alignment: .topTrailing) {
                                                _Thumb(image: img)
                                                Button {
                                                    newImages.remove(at: idx)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.white)
                                                        .shadow(radius: 2)
                                                }
                                                .padding(6)
                                                .offset(x: 6, y: -6)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }

                    Button("Add Images") { showMultiPicker = true }
                }

                Section(header: Text("Payout (Stripe)")) {
                    TextField("Stripe Account ID (acct_...)", text: $stripeAccountId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if !profileStripeAccountId.isEmpty {
                        Text("Profile Stripe: \(profileStripeAccountId)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        Button("Use my connected Stripe account") {
                            stripeAccountId = profileStripeAccountId
                        }
                        .font(.caption)
                    }

                    if !platformStripeAccountId.isEmpty {
                        Text("Platform Stripe cannot be used as payout destination.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Ticket Sales")) {
                    TextField("Ticket Price (USD)", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Ticket Quantity", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    TextField("Table Price (USD)", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Table Quantity", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                if isUploading {
                    ProgressView("Updating…")
                } else {
                    Button("Save Changes") { updateEvent() }
                }
            }
            .navigationTitle("Edit Event")
            .sheet(isPresented: $showMultiPicker) {
                MultiImagePicker(images: $newImages, selectionLimit: 0)
            }
            .disabled(isUploading)
            .overlay {
                if isUploading {
                    ZStack {
                        Color.black.opacity(0.05).ignoresSafeArea()
                        ProgressView("Updating…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }
                }
            }
            .alert("Can’t Save Changes", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(formErrors.map { "• \($0)" }.joined(separator: "\n"))
            }
            .onAppear { loadStripeDefaultsAndAutofillIfNeeded() }
        }
    }

    private func loadStripeDefaultsAndAutofillIfNeeded() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Database.database().reference()
        let group = DispatchGroup()

        var profile = ""
        var platform = ""

        group.enter()
        db.child("users").child(uid).child("stripeAccountId")
            .observeSingleEvent(of: .value) { snap in
                profile = (snap.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                group.leave()
            }

        group.enter()
        db.child("config").child("stripePlatformAccountId")
            .observeSingleEvent(of: .value) { snap in
                platform = (snap.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                group.leave()
            }

        group.notify(queue: .main) {
            self.profileStripeAccountId = profile
            self.platformStripeAccountId = platform

            let current = self.stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty, profile.hasPrefix("acct_") {
                self.stripeAccountId = profile
            }
        }
    }

    private func validateEditForm() -> [String] {
        var errs: [String] = []

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please enter an event title.") }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please enter a location.") }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errs.append("Please add a short description.") }

        validateStripeDestinationAccount(
            stripeAccountId,
            platformStripeAccountId: platformStripeAccountId,
            errs: &errs
        )

        if ticketPrice < 0 || tablePrice < 0 { errs.append("Prices can’t be negative.") }
        if ticketQuantity < 0 || tableQuantity < 0 { errs.append("Quantities can’t be negative.") }
        if ticketPrice > 0 && ticketQuantity == 0 { errs.append("Set ticket quantity for paid tickets.") }
        if tablePrice > 0 && tableQuantity == 0 { errs.append("Set table quantity for paid tables.") }

        // ✅ Must have at least 1 final image
        let finalCount = keptImagePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count + newImages.count
        if finalCount == 0 { errs.append("Please keep or add at least 1 event image.") }

        return errs
    }

    private func updateEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let errs = validateEditForm()
        guard errs.isEmpty else {
            formErrors = errs
            showErrorAlert = true
            return
        }

        isUploading = true

        // If no new images, just save existing kept paths
        if newImages.isEmpty {
            let cleaned = keptImagePaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let cover = cleaned.first else {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.formErrors = ["Please keep at least 1 image as the cover."]
                    self.showErrorAlert = true
                }
                return
            }

            saveChanges(coverImagePath: cover, imagePaths: cleaned, userId: userId)
            return
        }

        // Upload new images and append
        uploadEventImages(newImages) { uploaded in
            guard let uploaded = uploaded, !uploaded.isEmpty else {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.formErrors = ["We couldn’t upload your new images. Check your connection and try again."]
                    self.showErrorAlert = true
                }
                return
            }

            let cleanedKept = self.keptImagePaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Combine (kept first preserves existing cover unless it was removed)
            let finalPaths = cleanedKept + uploaded
            guard let cover = finalPaths.first else {
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.formErrors = ["Please keep or add at least 1 image."]
                    self.showErrorAlert = true
                }
                return
            }

            self.newImages.removeAll()
            saveChanges(coverImagePath: cover, imagePaths: finalPaths, userId: userId)
        }
    }

    private func uploadEventImages(_ images: [UIImage], completion: @escaping ([String]?) -> Void) {
        guard !images.isEmpty else { completion([]); return }

        var uploaded: [String?] = Array(repeating: nil, count: images.count)
        var firstError: String? = nil
        let group = DispatchGroup()

        for (idx, img) in images.enumerated() {
            group.enter()

            guard let data = img.jpegData(compressionQuality: 0.82) else {
                firstError = firstError ?? "We couldn’t read one of the selected images. Try another."
                group.leave()
                continue
            }

            let imageID = UUID().uuidString
            let path = "eventImages/\(imageID).jpg"
            let storageRef = Storage.storage().reference().child(path)
            let meta = StorageMetadata()
            meta.contentType = "image/jpeg"

            storageRef.putData(data, metadata: meta) { _, error in
                defer { group.leave() }
                if let error = error {
                    firstError = firstError ?? "Image upload failed. (\(error.localizedDescription))"
                    return
                }
                uploaded[idx] = path
            }
        }

        group.notify(queue: .main) {
            if let msg = firstError {
                self.formErrors = [msg]
                self.showErrorAlert = true
            }
            let final = uploaded.compactMap { $0 }
            completion(final.isEmpty ? nil : final)
        }
    }

    private func saveChanges(coverImagePath: String, imagePaths: [String], userId: String) {
        let ref = Database.database().reference().child("events").child(event.id)
        let acct = stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedPaths = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "title": title,
            "description": description,
            "location": location,
            "date": selectedDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,

            "payoutMethod": "stripe",
            "stripeAccountId": acct,
            "payoutDetails": acct, // legacy-safe

            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,

            // ✅ Legacy + Gallery
            "imagePath": coverImagePath,
            "imagePaths": cleanedPaths,

            "userId": userId,
            "isFree": (ticketPrice <= 0 && tablePrice <= 0)
        ]

        ref.updateChildValues(payload) { error, _ in
            DispatchQueue.main.async {
                self.isUploading = false
                if let error = error {
                    self.formErrors = ["We couldn’t save your changes. (\(error.localizedDescription))"]
                    self.showErrorAlert = true
                } else {
                    self.presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }
}

    // MARK: - CheckoutConfirmationView (quantity picker before payment)
    /*
     struct CheckoutConfirmationView: View {
     let event: EventModel
     let onConfirm: (Int, Int) -> Void
     
     @Environment(\.dismiss) private var dismiss
     @State private var ticketQty: Int = 0
     @State private var tableQty: Int = 0
     
     var body: some View {
     NavigationView {
     Form {
     Section(header: Text("Tickets")) {
     Stepper("Tickets: \(ticketQty)", value: $ticketQty, in: 0...max(0, event.ticketQuantity))
     if event.ticketPrice > 0 {
     Text("Price: $\(event.ticketPrice, specifier: "%.2f")")
     .foregroundColor(.secondary)
     }
     }
     
     Section(header: Text("Tables")) {
     Stepper("Tables: \(tableQty)", value: $tableQty, in: 0...max(0, event.tableQuantity))
     if event.tablePrice > 0 {
     Text("Price: $\(event.tablePrice, specifier: "%.2f")")
     .foregroundColor(.secondary)
     }
     }
     
     Section {
     let base = Double(ticketQty) * event.ticketPrice + Double(tableQty) * event.tablePrice
     Text("Subtotal: $\(base, specifier: "%.2f")")
     }
     
     Button {
     onConfirm(ticketQty, tableQty)
     dismiss()
     } label: {
     Text("Continue to Payment")
     .frame(maxWidth: .infinity)
     }
     }
     .navigationTitle("Confirm Order")
     .toolbar {
     ToolbarItem(placement: .cancellationAction) {
     Button("Cancel") { dismiss() }
     }
     }
     }
     }
     }
     */

import FirebaseStorage

private struct EventFlyerGalleryView: View {
    let event: EventModel

    @State private var urls: [URL] = []
    @State private var loading = false
    @State private var loadToken: Int = 0

    private var effectivePaths: [String] {
        let normalized = event.imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalized.isEmpty { return normalized }

        let legacy = event.imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy.isEmpty ? [] : [legacy]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))

            if loading && urls.isEmpty {
                ProgressView()
            } else if urls.isEmpty {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            } else if urls.count == 1 {
                flyerImage(url: urls[0])
                    .padding(6)
            } else {
                TabView {
                    ForEach(urls, id: \.absoluteString) { url in
                        flyerImage(url: url)
                            .padding(6)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
            }
        }
        .clipped()
        .onAppear { resolveURLs() }
        .onChange(of: event.id) { _ in resolveURLs() }
    }

    private func flyerImage(url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                    ProgressView()
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()   // ✅ no crop — matches flyer behavior
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .failure:
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.white.opacity(0.7))
                        Text("Image failed to load")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            @unknown default:
                EmptyView()
            }
        }
    }

    private func resolveURLs() {
        let paths = effectivePaths
        guard !paths.isEmpty else {
            urls = []
            loading = false
            return
        }

        loadToken &+= 1
        let myToken = loadToken

        loading = true
        urls = []

        let storage = Storage.storage()
        let group = DispatchGroup()
        var results = Array<URL?>(repeating: nil, count: paths.count)

        for (idx, raw) in paths.enumerated() {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            group.enter()
            storage.reference(withPath: p).downloadURL { url, err in
                if let err = err {
                    print("[EventDetailView] downloadURL failed path=\(p): \(err.localizedDescription)")
                }
                results[idx] = url
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard myToken == self.loadToken else { return }
            self.urls = results.compactMap { $0 }
            self.loading = false
            print("[EventDetailView] paths=\(paths.count) urlsResolved=\(self.urls.count)")
        }
    }
}

    // MARK: - EventDetailView (Stripe card flow + requires_action)
    
    struct EventDetailView: View {
        let event: EventModel
        
        @State private var showCheckoutConfirmation = false
        @State private var showShareOptions = false
        @State private var isSaved = false
        
        @State private var isPaymentLoading = false
        @State private var paymentResultMessage: String?
        @State private var showCardEntrySheet = false
        
        @State private var stripePublishableKey: String?
        @State private var pendingTicketQty: Int = 0
        @State private var pendingTableQty: Int = 0
        @State private var pendingBaseTotal: Double = 0
        @State private var pendingTotalWithFee: Double = 0
        
        private let platformFeeRate: Double = 0.05
        
        @StateObject private var authContext = StripeAuthContext()
        
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        EventFlyerGalleryView(event: event)
                            .frame(height: 420) // flyer-friendly; adjust 380–520 as needed
                            .cornerRadius(12)

                        Text(formattedDate(event.date))
                            .font(.caption).bold()
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .padding()
                    }
                    
                    Text(event.title).font(.title).bold()
                    
                    Text(event.description)
                        .font(.body)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                    
                    if event.ticketPrice > 0 || event.tablePrice > 0 {
                        Button {
                            showCheckoutConfirmation = true
                        } label: {
                            HStack {
                                if isPaymentLoading { ProgressView() } else { Image(systemName: "cart.fill") }
                                Text(isPaymentLoading ? "Preparing Checkout…" : "Get Tickets / Tables")
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(isPaymentLoading)
                    }
                    
                    HStack {
                        Button(action: { showShareOptions = true }) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .padding(8)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .confirmationDialog("Share Event",
                                            isPresented: $showShareOptions,
                                            titleVisibility: .visible) {
                            Button("Share via…") { shareToSystem() }
                            Button("Cancel", role: .cancel) {}
                        }
                        
                        Button(action: { isSaved.toggle() }) {
                            Label(isSaved ? "Saved" : "Remind Me",
                                  systemImage: isSaved ? "bookmark.fill" : "bookmark")
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding()
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .preferredColorScheme(.dark)
            .onAppear {
                fetchStripePublishableKeyIfNeeded()
                authContext.refreshPresenterIfNeeded()
            }
            .sheet(isPresented: $showCheckoutConfirmation) {
                CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                    let baseTotal = Double(ticketQty) * event.ticketPrice
                    + Double(tableQty) * event.tablePrice
                    let totalWithFee = round2(baseTotal * (1.0 + platformFeeRate))
                    
                    pendingTicketQty = ticketQty
                    pendingTableQty = tableQty
                    pendingBaseTotal = round2(baseTotal)
                    pendingTotalWithFee = totalWithFee
                    
                    let destination = event.stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !destination.isEmpty else {
                        paymentResultMessage = "This event creator has not connected Stripe payouts yet."
                        return
                    }
                    guard (ticketQty > 0 || tableQty > 0), baseTotal > 0 else {
                        paymentResultMessage = "Select at least one ticket or table."
                        return
                    }
                    ensureStripeKeyThenOpenCardEntry()
                }
            }
            .alert("Payment", isPresented: Binding(
                get: { paymentResultMessage != nil },
                set: { if !$0 { paymentResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(paymentResultMessage ?? "")
            }
            .sheet(isPresented: $showCardEntrySheet) {
                CardEntrySheet(
                    eventTitle: event.title,
                    totalWithFee: pendingTotalWithFee,
                    onCancel: { showCardEntrySheet = false },
                    onPay: { cardParams in
                        Task { await handleCardPayment(cardParams: cardParams) }
                    }
                )
            }
        }
        
        // MARK: - Publishable key
        
        private struct PublishableKeyResponse: Decodable {
            let publishableKey: String?
        }
        
        private func fetchStripePublishableKeyIfNeeded() {
            if stripePublishableKey != nil { return }
            guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/generateClientToken") else { return }
            
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            
            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error = error {
                    print("❌ generateClientToken error:", error.localizedDescription)
                    return
                }
                guard let data = data else { return }
                do {
                    let decoded = try JSONDecoder().decode(PublishableKeyResponse.self, from: data)
                    let pk = (decoded.publishableKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pk.isEmpty else { return }
                    DispatchQueue.main.async {
                        self.stripePublishableKey = pk
                        STPAPIClient.shared.publishableKey = pk
                    }
                } catch {
                    print("❌ publishableKey decode error:", error.localizedDescription)
                }
            }.resume()
        }
        
        private func ensureStripeKeyThenOpenCardEntry() {
            if let pk = stripePublishableKey, !pk.isEmpty {
                STPAPIClient.shared.publishableKey = pk
                showCardEntrySheet = true
                return
            }
            
            isPaymentLoading = true
            guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/generateClientToken") else {
                isPaymentLoading = false
                paymentResultMessage = "Payment is not configured."
                return
            }
            
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            
            URLSession.shared.dataTask(with: req) { data, _, error in
                DispatchQueue.main.async { self.isPaymentLoading = false }
                
                if let error = error {
                    DispatchQueue.main.async { self.paymentResultMessage = "Couldn’t start checkout. \(error.localizedDescription)" }
                    return
                }
                guard let data = data else {
                    DispatchQueue.main.async { self.paymentResultMessage = "Couldn’t start checkout (empty response)." }
                    return
                }
                
                do {
                    let decoded = try JSONDecoder().decode(PublishableKeyResponse.self, from: data)
                    let pk = (decoded.publishableKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pk.isEmpty else {
                        DispatchQueue.main.async { self.paymentResultMessage = "Stripe publishable key is missing on the server." }
                        return
                    }
                    
                    DispatchQueue.main.async {
                        self.stripePublishableKey = pk
                        STPAPIClient.shared.publishableKey = pk
                        self.showCardEntrySheet = true
                    }
                } catch {
                    DispatchQueue.main.async { self.paymentResultMessage = "Couldn’t start checkout. \(error.localizedDescription)" }
                }
            }.resume()
        }
        
        private func callFinalizeTransaction(
            userId: String,
            purchaseId: String,
            paymentIntentId: String
        ) async throws -> FinalizeTransactionResponse {

            guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/finalizeTransaction") else {
                throw URLError(.badURL)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "userId": userId,
                "purchaseId": purchaseId,
                "paymentIntentId": paymentIntentId
            ]

            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, response) = try await URLSession.shared.data(for: req)

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"

            print("[iOS][finalizeTransaction] http=\(statusCode) purchaseId=\(purchaseId) pi=\(paymentIntentId) raw=\(raw)")

            guard (200...299).contains(statusCode) else {
                throw NSError(domain: "FinalizeTransaction", code: statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Server error (\(statusCode)). \(raw)"
                ])
            }

            do {
                return try JSONDecoder().decode(FinalizeTransactionResponse.self, from: data)
            } catch {
                print("[iOS][finalizeTransaction] decode failed: \(error.localizedDescription)")
                throw error
            }
        }

        // MARK: - Payment flow
        
        private struct CreateTransactionResponse: Decodable {
            let ok: Bool?
            let rid: String?
            let purchaseId: String?
            let error: String?
            let paymentIntent: PaymentIntentPayload?

            struct PaymentIntentPayload: Decodable {
                let id: String?
                let status: String?
                let clientSecret: String?
                let nextAction: NextActionPayload?

                struct NextActionPayload: Decodable {
                    let type: String?
                }
            }
        }

        
        private struct FinalizeTransactionResponse: Decodable {
            let ok: Bool?
            let success: Bool?
            let rid: String?
            let status: String?
            let paymentIntentId: String?
            let purchaseId: String?
            let error: String?

            var isOK: Bool { (ok ?? false) || (success ?? false) }
        }


        
        private func handleCardPayment(cardParams: STPPaymentMethodCardParams) async {

            // -----------------------------------------------------
            // MARK: - Local helpers (kept inside to avoid scope drift)
            // -----------------------------------------------------
            func toCents(_ amount: Double) -> Int {
                // Defensive rounding
                return Int((amount * 100.0).rounded())
            }

            func safeString(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

            func ensurePurchaseEvidence(
                buyerUid: String,
                purchaseId: String,
                eventId: String,
                eventName: String,
                eventImagePath: String,
                eventTimeUnix: Int,
                ticketQty: Int,
                ticketPrice: Double,
                tableQty: Int,
                tablePrice: Double,
                baseTotal: Double
            ) async {
                // Passport reads: RTDB purchases/{uid}/*
                // Your Passport model decodes: eventId, eventTitle/eventName, eventImagePath/imagePath,
                // type, quantity, totalAmount/totalWithFee, eventTime, purchasedAt/timestamp.
                let root = Database.database().reference().child("purchases").child(buyerUid)

                let now = Date().timeIntervalSince1970
                let common: [String: Any] = [
                    "eventId": eventId,
                    "eventTitle": eventName,
                    "eventImagePath": eventImagePath,
                    "eventTime": Double(eventTimeUnix),
                    "purchasedAt": now,
                    "timestamp": now
                ]

                // Write one receipt per type so Passport shows clean items.
                var updates: [String: Any] = [:]

                if ticketQty > 0 {
                    let key = "\(purchaseId)-ticket"
                    let total = Double(ticketQty) * ticketPrice
                    var dict = common
                    dict["type"] = "ticket"
                    dict["quantity"] = ticketQty
                    dict["unitPrice"] = ticketPrice
                    dict["totalAmount"] = total
                    dict["baseTotal"] = total
                    updates[key] = dict
                }

                if tableQty > 0 {
                    let key = "\(purchaseId)-table"
                    let total = Double(tableQty) * tablePrice
                    var dict = common
                    dict["type"] = "table"
                    dict["quantity"] = tableQty
                    dict["unitPrice"] = tablePrice
                    dict["totalAmount"] = total
                    dict["baseTotal"] = total
                    updates[key] = dict
                }

                // If somehow both are zero, still write a generic record (should not happen).
                if updates.isEmpty {
                    let key = "\(purchaseId)-generic"
                    var dict = common
                    dict["type"] = "ticket"
                    dict["quantity"] = 0
                    dict["totalAmount"] = baseTotal
                    dict["baseTotal"] = baseTotal
                    updates[key] = dict
                }

                // Upsert (idempotent) so retries do not duplicate records.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    root.updateChildValues(updates) { err, _ in
                        if let err = err {
                            print("[iOS][purchases] upsert failed: \(err.localizedDescription)")
                        } else {
                            print("[iOS][purchases] upsert ok keys=\(Array(updates.keys))")
                        }
                        cont.resume()
                    }
                }
            }

            func verifyEvidenceExists(buyerUid: String, purchaseId: String) async -> Bool {
                // Quick existence check for either ticket/table record.
                let ref = Database.database().reference().child("purchases").child(buyerUid)
                let keys = ["\(purchaseId)-ticket", "\(purchaseId)-table", "\(purchaseId)-generic"]

                for k in keys {
                    let ok: Bool = await withCheckedContinuation { cont in
                        ref.child(k).observeSingleEvent(of: .value) { snap in
                            cont.resume(returning: snap.exists())
                        }
                    }
                    if ok { return true }
                }
                return false
            }

            func finalizeIfNeeded(
                buyerUid: String,
                rid: String,
                purchaseId: String,
                paymentIntentId: String,
                clientSecret: String
            ) async throws -> Bool {
                let authOutcome = try await authenticatePaymentIntent(clientSecret: clientSecret)

                if authOutcome == .canceled {
                    await MainActor.run {
                        self.isPaymentLoading = false
                        self.paymentResultMessage = "Payment canceled."
                    }
                    return false
                }

                // NOTE: You must have callFinalizeTransaction implemented in this same type/module.
                // If your project uses a different name, rename it here (do NOT remove the finalize step).
                let finalResp = try await callFinalizeTransaction(
                    userId: buyerUid,
                    purchaseId: purchaseId,
                    paymentIntentId: paymentIntentId
                )

                let fOK = (finalResp.ok ?? false)
                let status = safeString(finalResp.status)

                print("[iOS][finalizeTransaction] ok=\(fOK) rid=\(rid) purchaseId=\(purchaseId) status=\(status.isEmpty ? "n/a" : status)")

                await MainActor.run {
                    self.isPaymentLoading = false
                    self.paymentResultMessage = fOK ? "Payment successful." : (finalResp.error ?? "Payment not completed. Status: \(status.isEmpty ? "unknown" : status)")
                }

                return fOK
            }

            // -----------------------------------------------------
            // MARK: - Guards
            // -----------------------------------------------------
            guard let buyerUid = Auth.auth().currentUser?.uid else {
                await MainActor.run { self.paymentResultMessage = "You must be signed in to purchase." }
                return
            }

            guard let pk = stripePublishableKey, !pk.isEmpty else {
                await MainActor.run { self.paymentResultMessage = "Stripe is not configured (missing publishable key)." }
                return
            }
            STPAPIClient.shared.publishableKey = pk

            let destination = event.stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                await MainActor.run { self.paymentResultMessage = "This event creator has not connected Stripe payouts yet." }
                return
            }

            // Prevent “successful $0” or empty purchases
            let tQty = max(0, pendingTicketQty)
            let tbQty = max(0, pendingTableQty)
            if (tQty + tbQty) <= 0 {
                await MainActor.run { self.paymentResultMessage = "Select at least 1 ticket or table to purchase." }
                return
            }

            let ticketPrice = Double(event.ticketPrice)
            let tablePrice  = Double(event.tablePrice)

            let baseTickets = Double(tQty)  * ticketPrice
            let baseTables  = Double(tbQty) * tablePrice
            let baseTotal   = baseTickets + baseTables

            if baseTotal <= 0 {
                await MainActor.run { self.paymentResultMessage = "Invalid order total. Please try again." }
                return
            }

            // -----------------------------------------------------
            // MARK: - Stripe payment method creation
            // -----------------------------------------------------
            let pmParams = STPPaymentMethodParams(card: cardParams, billingDetails: nil, metadata: nil)

            await MainActor.run { self.isPaymentLoading = true }

            do {
                let paymentMethod = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<STPPaymentMethod, Error>) in
                    STPAPIClient.shared.createPaymentMethod(with: pmParams) { pm, error in
                        if let error = error { cont.resume(throwing: error); return }
                        guard let pm = pm else {
                            cont.resume(throwing: NSError(
                                domain: "Stripe",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Payment method creation failed."]
                            ))
                            return
                        }
                        cont.resume(returning: pm)
                    }
                }

                // -----------------------------------------------------
                // MARK: - Create Transaction (server)
                // -----------------------------------------------------
                let resp = try await callCreateTransaction(
                    paymentMethodId: paymentMethod.stripeId,
                    userId: buyerUid,
                    eventId: event.id,
                    eventName: event.title,
                    eventImagePath: event.imagePath,
                    ticketQty: tQty,
                    ticketPrice: ticketPrice,
                    tableQty: tbQty,
                    tablePrice: tablePrice,
                    eventTime: Int(event.date.timeIntervalSince1970)
                )

                await MainActor.run { self.showCardEntrySheet = false }

                let ok = (resp.ok ?? false)
                let rid = resp.rid ?? "n/a"
                let piStatus = safeString(resp.paymentIntent?.status).lowercased()
                let piId = resp.paymentIntent?.id ?? "n/a"

                // Prefer server purchaseId; fall back deterministically to rid so evidence can still be written
                let serverPurchaseId = safeString(resp.purchaseId)
                let purchaseId = !serverPurchaseId.isEmpty ? serverPurchaseId : (!rid.isEmpty ? rid : UUID().uuidString)

                print("[iOS][createTransaction] ok=\(ok) rid=\(rid) pi=\(piId) status=\(piStatus) purchaseId=\(purchaseId) baseTotal=\(String(format: "%.2f", baseTotal))")

                guard ok else {
                    await MainActor.run {
                        self.isPaymentLoading = false
                        self.paymentResultMessage = resp.error ?? "Payment failed. (rid: \(rid))"
                    }
                    return
                }

                // -----------------------------------------------------
                // MARK: - Success path (no further action needed)
                // -----------------------------------------------------
                if piStatus == "succeeded" {
                    // Critical: ensure Passport evidence exists (RTDB purchases/{uid})
                    await ensurePurchaseEvidence(
                        buyerUid: buyerUid,
                        purchaseId: purchaseId,
                        eventId: event.id,
                        eventName: event.title,
                        eventImagePath: event.imagePath,
                        eventTimeUnix: Int(event.date.timeIntervalSince1970),
                        ticketQty: tQty,
                        ticketPrice: ticketPrice,
                        tableQty: tbQty,
                        tablePrice: tablePrice,
                        baseTotal: baseTotal
                    )

                    // Verify (helps catch rules/path mistakes immediately)
                    let exists = await verifyEvidenceExists(buyerUid: buyerUid, purchaseId: purchaseId)
                    print("[iOS][purchases] evidenceExists=\(exists) purchaseId=\(purchaseId) uid=\(buyerUid)")

                    await MainActor.run {
                        self.isPaymentLoading = false
                        self.paymentResultMessage = "Payment successful."
                    }
                    return
                }

                // -----------------------------------------------------
                // MARK: - 3DS / SCA path (requires_action)
                // -----------------------------------------------------
                if piStatus == "requires_action" {
                    guard
                        let clientSecret = resp.paymentIntent?.clientSecret,
                        !safeString(clientSecret).isEmpty,
                        let paymentIntentId = resp.paymentIntent?.id,
                        !safeString(paymentIntentId).isEmpty
                    else {
                        await MainActor.run {
                            self.isPaymentLoading = false
                            self.paymentResultMessage = "Payment requires verification but server did not return client secret. (rid: \(rid))"
                        }
                        return
                    }

                    let finalized = try await finalizeIfNeeded(
                        buyerUid: buyerUid,
                        rid: rid,
                        purchaseId: purchaseId,
                        paymentIntentId: paymentIntentId,
                        clientSecret: clientSecret
                    )

                    if finalized {
                        await ensurePurchaseEvidence(
                            buyerUid: buyerUid,
                            purchaseId: purchaseId,
                            eventId: event.id,
                            eventName: event.title,
                            eventImagePath: event.imagePath,
                            eventTimeUnix: Int(event.date.timeIntervalSince1970),
                            ticketQty: tQty,
                            ticketPrice: ticketPrice,
                            tableQty: tbQty,
                            tablePrice: tablePrice,
                            baseTotal: baseTotal
                        )

                        let exists = await verifyEvidenceExists(buyerUid: buyerUid, purchaseId: purchaseId)
                        print("[iOS][purchases] evidenceExists=\(exists) purchaseId=\(purchaseId) uid=\(buyerUid)")
                    }
                    return
                }

                // -----------------------------------------------------
                // MARK: - Anything else: bubble up status
                // -----------------------------------------------------
                await MainActor.run {
                    self.isPaymentLoading = false
                    self.paymentResultMessage = "Payment status: \(piStatus.isEmpty ? "unknown" : piStatus) (rid: \(rid))"
                }

            } catch {
                await MainActor.run {
                    self.isPaymentLoading = false
                    self.paymentResultMessage = "Payment failed. \(error.localizedDescription)"
                }
            }
        }

        
        private enum LocalAuthOutcome { case completed, canceled }
        
        private func authenticatePaymentIntent(clientSecret: String) async throws -> LocalAuthOutcome {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LocalAuthOutcome, Error>) in
                let piParams = STPPaymentIntentParams(clientSecret: clientSecret)
                STPPaymentHandler.shared().confirmPayment(piParams, with: authContext) { status, _, error in
                    if let error = error { cont.resume(throwing: error); return }
                    switch status {
                    case .succeeded: cont.resume(returning: .completed)
                    case .canceled: cont.resume(returning: .canceled)
                    case .failed:
                        cont.resume(throwing: NSError(domain: "StripeAuth", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Authentication failed."
                        ]))
                    @unknown default:
                        cont.resume(throwing: NSError(domain: "StripeAuth", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "Unknown authentication result."
                        ]))
                    }
                }
            }
        }
        
        private func callCreateTransaction(
            paymentMethodId: String,
            userId: String,
            eventId: String,
            eventName: String,
            eventImagePath: String,
            ticketQty: Int,
            ticketPrice: Double,
            tableQty: Int,
            tablePrice: Double,
            eventTime: Int
        ) async throws -> CreateTransactionResponse {

            guard let url = URL(string: "https://us-central1-blackappios.cloudfunctions.net/createTransaction") else {
                throw URLError(.badURL)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "paymentMethodId": paymentMethodId,
                "userId": userId,
                "eventId": eventId,
                "eventName": eventName,
                "eventImagePath": eventImagePath,
                "ticketQty": ticketQty,
                "ticketPrice": ticketPrice,
                "tableQty": tableQty,
                "tablePrice": tablePrice,
                "eventTime": eventTime,
                "currency": "usd"
            ]

            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, response) = try await URLSession.shared.data(for: req)

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"

            print("[iOS][createTransaction] http=\(statusCode) eventId=\(eventId) raw=\(raw)")

            guard (200...299).contains(statusCode) else {
                throw NSError(domain: "CreateTransaction", code: statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Server error (\(statusCode)). \(raw)"
                ])
            }

            do {
                return try JSONDecoder().decode(CreateTransactionResponse.self, from: data)
            } catch {
                print("[iOS][createTransaction] decode failed: \(error.localizedDescription)")
                throw error
            }
        }

        // MARK: - Card Entry UI
        
        private struct CardEntrySheet: View {
            let eventTitle: String
            let totalWithFee: Double
            let onCancel: () -> Void
            let onPay: (STPPaymentMethodCardParams) -> Void
            
            @State private var isValidCard = false
            @State private var isSubmitting = false
            
            var body: some View {
                NavigationView {
                    VStack(spacing: 14) {
                        Text(eventTitle)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        Text("Total: $\(totalWithFee, specifier: "%.2f")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        StripeCardField(isValid: $isValidCard)
                            .frame(height: 56)
                            .padding(.horizontal)
                            .padding(.top, 8)
                        
                        Button {
                            guard isValidCard else { return }
                            isSubmitting = true
                            
                            StripeCardField.lastCardParams { params in
                                guard let params = params else {
                                    isSubmitting = false
                                    return
                                }
                                onPay(params)
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting { ProgressView() }
                                else { Text("Pay").font(.headline) }
                                Spacer()
                            }
                            .padding()
                            .background(isValidCard ? Color.blue : Color.gray.opacity(0.4))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(!isValidCard || isSubmitting)
                        .padding(.horizontal)
                        
                        Spacer()
                    }
                    .padding(.top, 18)
                    .navigationTitle("Card Payment")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { onCancel() }
                        }
                    }
                }
            }
        }
        
        private struct StripeCardField: UIViewRepresentable {
            @Binding var isValid: Bool
            
            private static var _lastParams: STPPaymentMethodCardParams? = nil
            private static var _lastParamsCallback: ((STPPaymentMethodCardParams?) -> Void)? = nil
            
            static func lastCardParams(_ cb: @escaping (STPPaymentMethodCardParams?) -> Void) {
                if let p = _lastParams { cb(p); return }
                _lastParamsCallback = cb
            }
            
            func makeUIView(context: Context) -> STPPaymentCardTextField {
                let tf = STPPaymentCardTextField()
                tf.delegate = context.coordinator
                tf.postalCodeEntryEnabled = false
                tf.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.6)
                tf.layer.cornerRadius = 10
                tf.layer.masksToBounds = true
                tf.textColor = .white
                return tf
            }
            
            func updateUIView(_ uiView: STPPaymentCardTextField, context: Context) {}
            
            func makeCoordinator() -> Coordinator { Coordinator(isValid: $isValid) }
            
            final class Coordinator: NSObject, STPPaymentCardTextFieldDelegate {
                @Binding var isValid: Bool
                init(isValid: Binding<Bool>) { _isValid = isValid }
                
                func paymentCardTextFieldDidChange(_ textField: STPPaymentCardTextField) {
                    isValid = textField.isValid
                    
                    if textField.isValid {
                        let card = STPPaymentMethodCardParams()
                        card.number = textField.cardNumber
                        card.expMonth = NSNumber(value: Int(textField.expirationMonth))
                        card.expYear = NSNumber(value: Int(textField.expirationYear))
                        card.cvc = textField.cvc
                        
                        StripeCardField._lastParams = card
                        StripeCardField._lastParamsCallback?(card)
                        StripeCardField._lastParamsCallback = nil
                    } else {
                        StripeCardField._lastParams = nil
                    }
                }
            }
        }
        
        // MARK: - Share
        
        private func shareToSystem() {
            let url = URL(string: "https://blackappios.web.app/event.html?eventId=\(event.id)")
            var items: [Any] = [event.title]
            if let url = url { items.append(url) }
            presentSystemShare(items)
        }
    }
    
    // MARK: - EventStatsView (clean, no Stripe vars inside, no stray braces)
    
    // MARK: - Local stats model (avoids PurchaseModel collisions)
    fileprivate struct EVT_CheckIn: Identifiable, Equatable {
        let id: String
        let userId: String
        let type: String
        let quantity: Int
    }
    
    
    // MARK: - EventStatsView (collision-safe)
    
    struct EventStatsView: View {
        let event: EventModel
        @State private var checkIns: [EVT_CheckIn] = []
        @State private var totalTickets = 0
        @State private var totalTables = 0
        
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Event Stats")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                    
                    Text(event.title)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("Total Tickets Sold: \(totalTickets)")
                        .foregroundColor(.white)
                    Text("Total Tables Booked: \(totalTables)")
                        .foregroundColor(.white)
                    Text("Checked-In Attendees: \(checkIns.count)")
                        .foregroundColor(.white)
                    
                    Divider().background(Color.white.opacity(0.2))
                    
                    Text("Checked-In Users")
                        .font(.title3)
                        .bold()
                        .foregroundColor(.white)
                    
                    if checkIns.isEmpty {
                        Text("No one has checked in yet.")
                            .foregroundColor(.gray)
                            .padding(.top, 4)
                    } else {
                        ForEach(checkIns) { item in
                            HStack(alignment: .top, spacing: 12) {
                                UserAvatarView(userId: item.userId)
                                VStack(alignment: .leading, spacing: 2) {
                                    UserNameView(userId: item.userId)
                                    Text("Type: \(item.type.capitalized) • Qty: \(item.quantity)")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                            }
                            Divider().background(Color.white.opacity(0.12))
                        }
                    }
                }
                .padding()
                .onAppear { loadStats() }
            }
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
        }
        
        private func loadStats() {
            let ref = Database.database().reference().child("purchases")
            
            ref.observeSingleEvent(of: .value) { snapshot in
                var checked: [EVT_CheckIn] = []
                var ticketTotal = 0
                var tableTotal = 0
                
                for case let userSnapshot as DataSnapshot in snapshot.children {
                    for case let purchaseSnapshot as DataSnapshot in userSnapshot.children {
                        guard
                            let value = purchaseSnapshot.value as? [String: Any],
                            (value["eventId"] as? String) == event.id
                        else { continue }
                        
                        let type = (value["type"] as? String) ?? "ticket"
                        let quantity: Int = {
                            if let i = value["quantity"] as? Int { return i }
                            if let n = value["quantity"] as? NSNumber { return n.intValue }
                            if let s = value["quantity"] as? String { return Int(s) ?? 0 }
                            return 0
                        }()
                        
                        if type == "ticket" { ticketTotal += quantity }
                        else if type == "table" { tableTotal += quantity }
                        
                        if (value["checkedIn"] as? Bool) == true {
                            let uid = (value["userId"] as? String) ?? userSnapshot.key
                            checked.append(EVT_CheckIn(
                                id: purchaseSnapshot.key,
                                userId: uid,
                                type: type,
                                quantity: quantity
                            ))
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.totalTickets = ticketTotal
                    self.totalTables = tableTotal
                    self.checkIns = checked
                }
            }
        }
    }
    
    // MARK: - Placeholder views (remove if you already have real ones)
    /*
     struct PromoterDashboardView: View {
     var body: some View {
     VStack {
     Text("Promoter Dashboard").foregroundColor(.white)
     Text("Wire your real promoter tools here.").foregroundColor(.gray)
     }
     .frame(maxWidth: .infinity, maxHeight: .infinity)
     .background(Color.black.ignoresSafeArea())
     .preferredColorScheme(.dark)
     }
     }
     
     struct NightlifeHomeView: View {
     var body: some View {
     VStack {
     Text("Nightlife").foregroundColor(.white)
     Text("Wire your nightlife module here.").foregroundColor(.gray)
     }
     .frame(maxWidth: .infinity, maxHeight: .infinity)
     .background(Color.black.ignoresSafeArea())
     .preferredColorScheme(.dark)
     }
     }
     */

