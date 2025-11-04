import Foundation

struct AppUser: Identifiable, Equatable {
    var id: String?
    var handle: String
    var handleLower: String
    var displayName: String
    var avatarURL: String?
    var bio: String?
    var createdAt: Date?
    var isOnline: Bool
    var lastActiveAt: Date?
    var isStatusHidden: Bool

    init(id: String? = nil,
         handle: String,
         displayName: String,
         avatarURL: String? = nil,
         bio: String? = nil,
         createdAt: Date? = nil,
         isOnline: Bool = false,
         lastActiveAt: Date? = nil,
         isStatusHidden: Bool = false) {
        self.id = id
        self.handle = handle
        self.handleLower = handle.lowercased()
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.createdAt = createdAt
        self.isOnline = isOnline
        self.lastActiveAt = lastActiveAt
        self.isStatusHidden = isStatusHidden
    }

    var isVisiblyOnline: Bool { isOnline && !isStatusHidden }

    func lastSeenDescription(relativeTo reference: Date = Date()) -> String? {
        guard let lastActiveAt else { return nil }
        return AppUser.relativeFormatter.localizedString(for: lastActiveAt, relativeTo: reference)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
