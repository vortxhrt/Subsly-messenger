import Foundation

struct MessageModel: Identifiable, Hashable {
    struct Media: Hashable {
        enum Kind: String, Hashable {
            case image
            case video
        }

        let kind: Kind
        let url: String?
        let thumbnailURL: String?
        let width: Double?
        let height: Double?
        let duration: Double?
        let localData: Data?
        let localThumbnailData: Data?
    }

    let id: String          // non-optional so ForEach never sees an optional
    let senderId: String
    let text: String
    let createdAt: Date?
    let media: Media?
    let deliveredTo: [String]
    let readBy: [String]
}
