

import Foundation
import FirebaseDatabase // ✅ This is required for DataSnapshot

struct Event: Identifiable {
    let id: String
    let name: String
    let description: String
    let timestamp: TimeInterval
    let date: TimeInterval
    let price: String
    let paymentLink: String
    let imageURL: String?
    let userId: String
    let location: String
    let sellTickets: Bool
    let sellTables: Bool
    let ticketPrice: String
    let tablePrice: String
    let ticketQuantity: String
    let tableQuantity: String

    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: date))
    }

    // ✅ Factory method to create Event from Firebase snapshot
    static func from(snapshot: DataSnapshot) -> Event? {
        guard let dict = snapshot.value as? [String: Any],
              let name = dict["name"] as? String,
              let description = dict["description"] as? String,
              let timestamp = dict["timestamp"] as? TimeInterval,
              let date = dict["date"] as? TimeInterval,
              let userId = dict["userId"] as? String else { return nil }

        let price = dict["price"] as? String ?? ""
        let paymentLink = dict["paymentLink"] as? String ?? ""
        let imageURL = dict["imageURL"] as? String
        let location = dict["location"] as? String ?? ""

        let sellTickets = dict["sellTickets"] as? Bool ?? false
        let sellTables = dict["sellTables"] as? Bool ?? false
        let ticketPrice = dict["ticketPrice"] as? String ?? ""
        let tablePrice = dict["tablePrice"] as? String ?? ""
        let ticketQuantity = dict["ticketQuantity"] as? String ?? ""
        let tableQuantity = dict["tableQuantity"] as? String ?? ""

        return Event(
            id: snapshot.key,
            name: name,
            description: description,
            timestamp: timestamp,
            date: date,
            price: price,
            paymentLink: paymentLink,
            imageURL: imageURL,
            userId: userId,
            location: location,
            sellTickets: sellTickets,
            sellTables: sellTables,
            ticketPrice: ticketPrice,
            tablePrice: tablePrice,
            ticketQuantity: ticketQuantity,
            tableQuantity: tableQuantity
        )
    }
}
