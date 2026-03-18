import SwiftUI
import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage

struct CheckoutConfirmationView: View {
    let event: EventModel
    /// Called when the user taps "Proceed to Payment" on a paid order
    let onConfirm: (_ ticketQty: Int, _ tableQty: Int) -> Void

    @Environment(\.dismiss) private var dismiss

    // Quantities
    @State private var ticketQty: Int = 0
    @State private var tableQty: Int = 0

    // ✅ Single source of truth for buyer platform fee
    private let platformBuyerFeeRate: Double = 0.05

    // Flyer gallery state
    @State private var flyerURLs: [URL] = []
    @State private var flyerLoading: Bool = false
    @State private var flyerLoadToken: Int = 0 // prevents late callbacks from older loads

    // Subtotals
    private var ticketTotal: Double { Double(ticketQty) * event.ticketPrice }
    private var tableTotal: Double { Double(tableQty) * event.tablePrice }
    private var subTotal: Double { ticketTotal + tableTotal }

    // Fee + total (rounded to 2 decimals)
    private var platformFee: Double { round2(subTotal * platformBuyerFeeRate) }
    private var totalWithFee: Double { round2(subTotal + platformFee) }

    // MARK: - Canonical image paths (aligned to your EventModel)

    /// Your EventModel guarantees `imagePaths` exists (can be empty),
    /// and `imagePath` is the legacy cover (should match first imagePaths if present).
    private var effectiveImagePaths: [String] {
        let normalized = event.imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalized.isEmpty { return normalized }

        let legacy = event.imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy.isEmpty ? [] : [legacy]
    }

    private var coverImagePath: String {
        // Prefer first gallery image; else legacy cover.
        effectiveImagePaths.first ?? event.imagePath
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                // ✅ Flyer gallery OUTSIDE Form to avoid row clipping/cropping.
                if !effectiveImagePaths.isEmpty {
                    flyerGallery
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                }

                Form {
                    // Event header
                    Section(header: Text("Event")) {
                        Text(event.title)
                            .font(.headline)
                        if !event.location.isEmpty {
                            Text(event.location)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text(formattedDate(event.date))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Quantities
                    Section(header: Text("Select Quantities")) {
                        if event.ticketQuantity > 0 && event.ticketPrice >= 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Tickets")
                                    Text(String(format: "$%.2f each", event.ticketPrice))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Stepper(value: $ticketQty, in: 0...event.ticketQuantity) {
                                    Text("\(ticketQty)")
                                }
                                .labelsHidden()
                            }
                            if ticketQty > 0 {
                                Text("Tickets subtotal: $\(ticketTotal, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("No ticket sales configured for this event.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        if event.tableQuantity > 0 && event.tablePrice >= 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Tables")
                                    Text(String(format: "$%.2f each", event.tablePrice))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Stepper(value: $tableQty, in: 0...event.tableQuantity) {
                                    Text("\(tableQty)")
                                }
                                .labelsHidden()
                            }
                            if tableQty > 0 {
                                Text("Tables subtotal: $\(tableTotal, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("No table sales configured for this event.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    // ✅ Clear price breakdown
                    Section(header: Text("Order Summary")) {
                        HStack {
                            Text("Subtotal")
                            Spacer()
                            Text("$\(subTotal, specifier: "%.2f")")
                        }
                        HStack {
                            Text("Platform Fee (5%)")
                            Spacer()
                            Text("$\(platformFee, specifier: "%.2f")")
                        }
                        HStack {
                            Text("Total")
                                .font(.headline)
                            Spacer()
                            Text("$\(totalWithFee, specifier: "%.2f")")
                                .font(.headline)
                        }

                        if ticketQty == 0 && tableQty == 0 {
                            Text("Select at least one ticket or table to continue.")
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }

                    // Action button
                    Section {
                        Button {
                            guard ticketQty > 0 || tableQty > 0 else { return }

                            dismiss()

                            if subTotal == 0 {
                                claimFreeTickets(ticketQty: ticketQty, tableQty: tableQty)
                            } else {
                                onConfirm(ticketQty, tableQty)
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text(subTotal == 0 ? "Claim Free Tickets" : "Proceed to Payment")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(ticketQty == 0 && tableQty == 0)

                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Confirm Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                resolveFlyerURLs()
            }
            // If the event changes (rare here), re-resolve.
            .onChange(of: event.id) { _ in
                resolveFlyerURLs()
            }
        }
    }

    // MARK: - Flyer gallery

    private var flyerGallery: some View {
        // Fixed height avoids “cropped-looking” behavior and keeps flyer readable.
        // If your flyers are very tall, increase to 460–520.
        let galleryHeight: CGFloat = 440

        return ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.08))

            if flyerLoading && flyerURLs.isEmpty {
                ProgressView()
            } else if flyerURLs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Flyer unavailable")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                TabView {
                    ForEach(flyerURLs, id: \.absoluteString) { url in
                        flyerImage(url: url)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: flyerURLs.count > 1 ? .automatic : .never))
            }
        }
        .frame(height: galleryHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 6)
        .accessibilityLabel(Text("Event flyer gallery"))
    }

    private func flyerImage(url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.08))
                    ProgressView()
                }

            case .success(let image):
                // ✅ THIS is the key: scaledToFit (no cropping) + a container that can grow vertically.
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

            case .failure:
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.08))
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("Image failed to load")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

            @unknown default:
                EmptyView()
            }
        }
    }

    private func resolveFlyerURLs() {
        let paths = effectiveImagePaths
        guard !paths.isEmpty else {
            flyerURLs = []
            flyerLoading = false
            return
        }

        flyerLoadToken &+= 1
        let myToken = flyerLoadToken

        flyerLoading = true
        flyerURLs = []

        let storage = Storage.storage()
        let group = DispatchGroup()

        // preserve order
        var results = Array<URL?>(repeating: nil, count: paths.count)

        for (idx, raw) in paths.enumerated() {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }

            group.enter()
            storage.reference(withPath: p).downloadURL { url, err in
                if let err = err {
                    print("[CheckoutConfirmation] downloadURL failed path=\(p): \(err.localizedDescription)")
                }
                results[idx] = url
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Ignore stale callbacks if a newer load started
            guard myToken == self.flyerLoadToken else { return }

            self.flyerURLs = results.compactMap { $0 }
            self.flyerLoading = false

            print("[CheckoutConfirmation] paths=\(paths.count) urlsResolved=\(self.flyerURLs.count)")
        }
    }

    // MARK: - Free ticket flow

    private func claimFreeTickets(ticketQty: Int, tableQty: Int) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let db = Database.database().reference()
        let timestamp = Date().timeIntervalSince1970

        let imagePaths = effectiveImagePaths
        let cover = coverImagePath.trimmingCharacters(in: .whitespacesAndNewlines)

        if ticketQty > 0 {
            let ticketRef = db.child("purchases").child(userId).childByAutoId()
            let data: [String: Any] = [
                "eventId": event.id,
                "eventTitle": event.title,

                // ✅ aligned to new schema + legacy-safe
                "eventImagePath": cover,
                "eventImagePaths": imagePaths,

                "quantity": ticketQty,
                "type": "ticket",
                "totalAmount": 0.0,
                "timestamp": timestamp
            ]
            ticketRef.setValue(data)
            db.child("events").child(event.id).child("ticketsSold")
                .runTransactionBlock { currentData in
                    let current = currentData.value as? Int ?? 0
                    currentData.value = current + ticketQty
                    return TransactionResult.success(withValue: currentData)
                }
        }

        if tableQty > 0 {
            let tableRef = db.child("purchases").child(userId).childByAutoId()
            let data: [String: Any] = [
                "eventId": event.id,
                "eventTitle": event.title,

                // ✅ aligned to new schema + legacy-safe
                "eventImagePath": cover,
                "eventImagePaths": imagePaths,

                "quantity": tableQty,
                "type": "table",
                "totalAmount": 0.0,
                "timestamp": timestamp
            ]
            tableRef.setValue(data)
            db.child("events").child(event.id).child("tablesSold")
                .runTransactionBlock { currentData in
                    let current = currentData.value as? Int ?? 0
                    currentData.value = current + tableQty
                    return TransactionResult.success(withValue: currentData)
                }
        }
    }

    // MARK: - Helpers

    private func round2(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
