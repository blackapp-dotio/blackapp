import SwiftUI
import UIKit

// MARK: Notifications
extension Notification.Name {
    static let gossipEditorReadyToPost = Notification.Name("gossipEditorReadyToPost")
}


// MARK: Payload passed around app
enum CapturedMediaKind: String { case photo, video }

struct CapturePayload: Identifiable {
    let id = UUID()
    let kind: CapturedMediaKind
    let url: URL?      // set for videos
    let image: UIImage?// set for photos
    let filter: String?

    // Build from NotificationCenter payload (keeps what InviteOrb/LiveCaptureView already sends)
    static func from(_ note: Notification) -> CapturePayload? {
        guard let info = note.userInfo else { return nil }
        let typeString = (info["type"] as? String) ?? "photo"
        let kind: CapturedMediaKind = (typeString == "video") ? .video : .photo
        let url  = info["mediaURL"] as? URL
        let img  = info["image"] as? UIImage
        let filt = info["filter"] as? String
        return CapturePayload(kind: kind, url: url, image: img, filter: filt)
    }
}

// MARK: Convenience: call this inside LiveCaptureView when capture finishes
@MainActor
func postInviteOrbCapture(kind: CapturedMediaKind, url: URL?, image: UIImage?, filter: String? = nil) {
    var payload: [String: Any] = [
        "type": kind.rawValue,
        "filter": filter as Any,
        "hasURL": url != nil,
        "hasImage": image != nil
    ]
    if let url { payload["mediaURL"] = url }
    if let image { payload["image"] = image }
    NotificationCenter.default.post(name: .inviteOrbCapturedMedia, object: nil, userInfo: payload)
}
