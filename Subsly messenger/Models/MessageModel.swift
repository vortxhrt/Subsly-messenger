import Foundation

struct MessageModel: Identifiable, Hashable {
    struct Media: Hashable {
        enum Kind: String, Hashable {
            case image
            case video
            case audio
        }

        let kind: Kind
        let url: String?
        let thumbnailURL: String?
        let width: Double?
        let height: Double?
        let duration: Double?
        let localData: Data?
        let localThumbnailData: Data?
        let localFilePath: String?
    }

    struct ReplyPreview: Hashable {
        let messageId: String
        let senderId: String?
        let senderName: String?
        let text: String?
        let mediaKind: MessageModel.Media.Kind?

        var displayName: String {
            if let senderName, !senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return senderName
            }
            if let senderId, !senderId.isEmpty {
                return senderId
            }
            return "Message"
        }

        var summary: String {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if let mediaKind {
                switch mediaKind {
                case .image:
                    return "Photo"
                case .video:
                    return "Video"
                case .audio:
                    return "Voice message"
                }
            }
            return "Message"
        }

        func withSenderName(_ name: String?) -> ReplyPreview {
            ReplyPreview(messageId: messageId,
                         senderId: senderId,
                         senderName: name,
                         text: text,
                         mediaKind: mediaKind)
        }
    }

    let id: String          // non-optional so ForEach never sees an optional
    let clientMessageId: String?
    let senderId: String
    let text: String
    let createdAt: Date?
    let media: [Media]
    let deliveredTo: [String]
    let readBy: [String]
    let replyTo: ReplyPreview?
}
