import Foundation
import FirebaseAuth
import FirebaseFirestore

enum DMGateState {
    case accepted
    case blockedByMe
    case blockedByThem
    case needsRequest         // neither side accepted or requested
    case requestSent          // I sent a request to them
    case requestFromThem      // they sent a request to me
}

struct DMRequest: Identifiable, Codable {
    var id: String { fromUid }
    let fromUid: String
    let fromName: String
    let fromUsername: String
    let fromAvatarUrl: String?
    let lastText: String
    let lastAt: TimeInterval
    let count: Int
}

final class DMRelationshipService {
    static let shared = DMRelationshipService()
    private let db = Firestore.firestore()

    // Paths:
    // /dmBlocks/{uid}/blocked/{otherUid} -> true
    // /dmRelationships/{uid}/accepted/{otherUid} -> true
    // /dmRequests/{toUid}/incoming/{fromUid} -> { from..., lastText, lastAt, count }

    func gateState(with otherUid: String, completion: @escaping (DMGateState) -> Void) {
        guard let me = Auth.auth().currentUser?.uid else { completion(.needsRequest); return }
        let blocksMe    = db.collection("dmBlocks").document(otherUid).collection("blocked").document(me)
        let iBlockThem  = db.collection("dmBlocks").document(me).collection("blocked").document(otherUid)
        let iAccepted   = db.collection("dmRelationships").document(me).collection("accepted").document(otherUid)
        let reqsToMe    = db.collection("dmRequests").document(me).collection("incoming").document(otherUid)
        let reqsToThem  = db.collection("dmRequests").document(otherUid).collection("incoming").document(me)

        var blockedByMe = false, blockedByThem = false, accepted = false, requestFromThem = false, requestToThem = false
        let group = DispatchGroup()

        [blocksMe, iBlockThem, iAccepted, reqsToMe, reqsToThem].forEach { _ in group.enter() }

        blocksMe.getDocument { s, _ in blockedByThem = s?.exists == true; group.leave() }
        iBlockThem.getDocument { s, _ in blockedByMe  = s?.exists == true; group.leave() }
        iAccepted.getDocument { s, _ in accepted     = s?.exists == true; group.leave() }
        reqsToMe.getDocument { s, _ in requestFromThem = s?.exists == true; group.leave() }
        reqsToThem.getDocument { s, _ in requestToThem  = s?.exists == true; group.leave() }

        group.notify(queue: .main) {
            if blockedByMe   { completion(.blockedByMe); return }
            if blockedByThem { completion(.blockedByThem); return }
            if accepted      { completion(.accepted); return }
            if requestFromThem { completion(.requestFromThem); return }
            if requestToThem { completion(.requestSent); return }
            completion(.needsRequest)
        }
    }

    func sendRequest(to other: ChatUserProfile, firstText: String, meProfile: ChatUserProfile, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else { completion?(nil); return }
        let doc = db.collection("dmRequests").document(other.id).collection("incoming").document(me)
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            "fromUid": me,
            "fromName": meProfile.name,
            "fromUsername": meProfile.username,
            "fromAvatarUrl": meProfile.profileImageURL ?? NSNull(),
            "lastText": firstText,
            "lastAt": now,
            "count": FieldValue.increment(Int64(1))
        ]
        doc.setData(payload, merge: true, completion: completion)
    }

    func acceptRequest(from otherUid: String, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else { completion?(nil); return }
        let batch = db.batch()
        let myRel    = db.collection("dmRelationships").document(me).collection("accepted").document(otherUid)
        let theirRel = db.collection("dmRelationships").document(otherUid).collection("accepted").document(me)
        let myReq    = db.collection("dmRequests").document(me).collection("incoming").document(otherUid)
        batch.setData([:], forDocument: myRel)
        batch.setData([:], forDocument: theirRel)
        batch.deleteDocument(myReq)
        batch.commit(completion: completion)
    }
    
    func declineRequest(from otherUid: String, completion: ((Error?) -> Void)? = nil) {
        // Removes the incoming request from `otherUid` to me (no block; no accept)
        guard let me = Auth.auth().currentUser?.uid else { completion?(nil); return }
        Firestore.firestore()
            .collection("dmRequests").document(me).collection("incoming").document(otherUid)
            .delete(completion: completion)
    }

    func block(_ otherUid: String, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else { completion?(nil); return }
        let batch = db.batch()
        let blk = db.collection("dmBlocks").document(me).collection("blocked").document(otherUid)
        let reqToMe   = db.collection("dmRequests").document(me).collection("incoming").document(otherUid)
        let reqToThem = db.collection("dmRequests").document(otherUid).collection("incoming").document(me)
        batch.setData([:], forDocument: blk)
        batch.deleteDocument(reqToMe)
        batch.deleteDocument(reqToThem)
        batch.commit(completion: completion)
    }

    func unblock(_ otherUid: String, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else { completion?(nil); return }
        db.collection("dmBlocks").document(me).collection("blocked").document(otherUid).delete(completion: completion)
    }

    /// Observe number of incoming requests for badge
    func observeIncomingRequestsCount(_ handler: @escaping (Int) -> Void) -> ListenerRegistration? {
        guard let me = Auth.auth().currentUser?.uid else { handler(0); return nil }
        return db.collection("dmRequests").document(me).collection("incoming")
            .addSnapshotListener { snap, _ in
                handler(snap?.documents.count ?? 0)
            }
    }

    /// Convenience: compute deterministic chatId for a direct chat
    static func chatId(with otherUid: String, me: String) -> String {
        [me, otherUid].sorted().joined(separator: "_")
    }
}
