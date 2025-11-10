import Foundation

struct AppUser: Identifiable, Equatable, Codable {
    var id: String?
    var handle: String
    var handleLower: String
    var displayName: String
    var avatarURL: String?
    var bio: String?
    var createdAt: Date?
    var isOnline: Bool
    var shareOnlineStatus: Bool
    var lastOnlineAt: Date?

    init(id: String? = nil,
         handle: String,
         displayName: String,
         avatarURL: String? = nil,
         bio: String? = nil,
         createdAt: Date? = nil,
         isOnline: Bool = false,
         shareOnlineStatus: Bool = true,
         lastOnlineAt: Date? = nil) {
        self.id = id
        self.handle = handle
        self.handleLower = handle.lowercased()
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.createdAt = createdAt
        self.isOnline = isOnline
        self.shareOnlineStatus = shareOnlineStatus
        self.lastOnlineAt = lastOnlineAt
    }
}
