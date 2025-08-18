import SwiftUI
import FirebaseAuth
import FirebaseDatabase

// MARK: - Stats model
struct PromoterStats {
    var gmv: Double
    var paidCount: Int
    var heldCount: Int
    var expiredCount: Int

    static var empty: PromoterStats { .init(gmv: 0, paidCount: 0, heldCount: 0, expiredCount: 0) }
}

// MARK: - Promoter Dashboard
struct PromoterDashboardView: View {
    enum Window: String, CaseIterable { case today = "Today", week = "7d", month = "30d", all = "All" }

    @State private var window: Window = .week
    @State private var nights: [NightModel] = []
    @State private var reservations: [ReservationModel] = []
    @State private var stats: PromoterStats = .empty
    @State private var selectedNightForShare: NightModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header
                Text("Promoter Dashboard")
                    .font(.title2).bold()

                // Window control
                HStack {
                    ForEach(Window.allCases, id: \.self) { w in
                        Button(action: { window = w; reload() }) {
                            Text(w.rawValue)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(window == w ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                }

                // KPI cards
                HStack(spacing: 12) {
                    KPI(title: "GMV", value: "$\(Int(stats.gmv))")
                    KPI(title: "Paid", value: "\(stats.paidCount)")
                    KPI(title: "Held", value: "\(stats.heldCount)")
                    KPI(title: "Expired", value: "\(stats.expiredCount)")
                }

                // Nights you promote
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("My Nights").font(.headline)
                        Spacer()
                        Menu {
                            ForEach(nights, id: \.id) { n in
                                Button("\(n.title) – \(shortDate(n.date))") {
                                    selectedNightForShare = n
                                }
                            }
                        } label: {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        .disabled(nights.isEmpty)
                    }

                    if nights.isEmpty {
                        Text("No attached nights yet. Ask a venue admin to add you.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(nights.prefix(5), id: \.id) { n in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(n.title).font(.subheadline).bold()
                                    Text(shortDate(n.date))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Share") { selectedNightForShare = n }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                        }
                    }
                }

                // Reservations list
                VStack(alignment: .leading, spacing: 8) {
                    Text("My Reservations").font(.headline)
                    if reservations.isEmpty {
                        Text("No reservations yet for this window.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(reservations, id: \.id) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reservation \(r.id.suffix(6))").font(.subheadline).bold()
                                    Text("Table \(r.tableId) • Min $\(Int(r.minSpend))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                StatusPill(r.status)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { reload() }
        .sheet(item: $selectedNightForShare) { night in
            PromoterShareSheet(night: night)
        }
    }

    // MARK: - Data
    private func reload() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        fetchPromoterNights(promoterId: uid) { ns in
            DispatchQueue.main.async { self.nights = ns }
        }

        let start: Date? = {
            let now = Date()
            switch window {
            case .today: return Calendar.current.startOfDay(for: now)
            case .week:  return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
            case .all:   return nil
            }
        }()

        fetchPromoterReservations(promoterId: uid, windowStart: start) { rs in
            let s = computeStats(for: rs)
            DispatchQueue.main.async {
                self.reservations = rs.sorted { $0.amountPaid > $1.amountPaid }
                self.stats = s
            }
        }
    }

    private func fetchPromoterNights(promoterId: String, completion: @escaping ([NightModel]) -> Void) {
        let ref = Database.database().reference().child("nights")
        ref.observeSingleEvent(of: .value) { snap in
            var out: [NightModel] = []
            for case let child as DataSnapshot in snap.children {
                guard let n = NightModel.from(child) else { continue }
                if n.promoterIds[promoterId] == true { out.append(n) }
            }
            completion(out.sorted { $0.date < $1.date })
        }
    }

    private func fetchPromoterReservations(promoterId: String,
                                           windowStart: Date?,
                                           completion: @escaping ([ReservationModel]) -> Void) {
        let ref = Database.database().reference().child("reservations")
        ref.observeSingleEvent(of: .value) { snap in
            var out: [ReservationModel] = []
            for case let child as DataSnapshot in snap.children {
                guard let r = ReservationModel.from(child) else { continue }

                // Only those attributed to this promoter (field may be missing on older data)
                let promoterIdField = (child.value as? [String: Any])?["promoterId"] as? String
                guard promoterIdField == promoterId else { continue }

                // Optional time window filter:
                if let start = windowStart {
                    // If you mirror reservation -> night date in the future, filter here.
                    // MVP: accept all; window can be applied later with night lookup.
                    _ = start
                }
                out.append(r)
            }
            completion(out)
        }
    }

    private func computeStats(for reservations: [ReservationModel]) -> PromoterStats {
        let paid = reservations.filter { $0.status == "paid" }
        let held = reservations.filter { $0.status == "held" }
        let expired = reservations.filter { $0.status == "expired" }
        let gmv = paid.map { $0.amountPaid }.reduce(0, +)
        return PromoterStats(gmv: gmv,
                             paidCount: paid.count,
                             heldCount: held.count,
                             expiredCount: expired.count)
    }

    // MARK: - Formatting
    private func shortDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}

// MARK: - Small UI bits
private struct KPI: View {
    let title: String; let value: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

private struct StatusPill: View {
    let text: String
    init(_ t: String) { self.text = t }
    var color: Color {
        switch text {
        case "paid": return .green
        case "held": return .orange
        case "expired": return .red
        default: return .gray
        }
    }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Share sheet (uses your QRCodeView from NightlifeModule.swift)
struct PromoterShareSheet: View, Identifiable {
    let night: NightModel
    var id: String { night.id }
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Share your link").font(.headline)

            if let link = shareURL {
                Text(link.absoluteString)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                QRCodeView(text: link.absoluteString)
                    .padding(.vertical, 8)

                if #available(iOS 16.0, *) {
                    ShareLink(item: link) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Couldn’t build link.").foregroundColor(.red)
            }

            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var shareURL: URL? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        var comps = URLComponents(string: "https://blackapp.app/nightlife/venue/\(night.venueId)")!
        comps.queryItems = [
            URLQueryItem(name: "nightId", value: night.id),
            URLQueryItem(name: "promoterId", value: uid)
        ]
        return comps.url
    }
}
