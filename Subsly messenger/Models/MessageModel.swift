import Foundation

struct MessageModel: Identifiable, Hashable {
    let id: String          // non-optional so ForEach never sees an optional
    let senderId: String
    let text: String
    let createdAt: Date?
}
