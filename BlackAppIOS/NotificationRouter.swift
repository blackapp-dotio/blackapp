import Foundation
import Combine

@MainActor
class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    // Used for direct chat deep linking
    @Published var selectedChatUser: ChatUserProfile? = nil

    // Used for group chat deep linking and red dot
    @Published var selectedChatId: String? = nil

    // IDs of group chats with unread messages (used for red dots)
    @Published var unreadChatIds: [String] = []
    
    @Published var selectedGroupId: String? = nil

    // Mark a specific group chat as unread (trigger red dot)
    func markChatAsUnread(_ chatId: String) {
        if !unreadChatIds.contains(chatId) {
            unreadChatIds.append(chatId)
        }
    }

    // Optional: clear all navigation and unread states
    func clearAll() {
        selectedChatUser = nil
        selectedChatId = nil
        unreadChatIds.removeAll()
    }
}
