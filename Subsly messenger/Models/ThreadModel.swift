import Foundation

struct ThreadModel: Identifiable, Equatable {
    var id: String?
    var members: [String]
    var lastMessagePreview: String?
    var updatedAt: Date?
}
