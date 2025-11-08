import Foundation
import FirebaseCore
import FirebaseFirestore

// ListenerRegistration is @MainActor, so make this class @MainActor too.
@MainActor
final class DummyListener: NSObject, ListenerRegistration {
    static let shared = DummyListener()
    private override init() {}
    func remove() {}
}

actor ChatService {
    // Warning-free singleton
    nonisolated static let shared = ChatService()

    // MARK: Availability / references
    private func isConfigured() async -> Bool {
        await MainActor.run { FirebaseApp.app() != nil }
    }
    private func threadsCollection() async -> CollectionReference? {
        guard await isConfigured() else { return nil }
        return Firestore.firestore().collection("threads")
    }

    // Deterministic 1:1 id
    nonisolated func threadId(for a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    // MARK: Ensure thread (don’t clobber preview/timestamp)
    func ensureThread(currentUID: String, otherUID: String) async throws -> ThreadModel {
        let tid = threadId(for: currentUID, otherUID)
        guard let threadsCol = await threadsCollection() else {
            return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
        }
        try await threadsCol.document(tid).setData(["members": [currentUID, otherUID]], merge: true)
        return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
    }

    // MARK: Send message + bump preview/timestamp
    func sendMessage(threadId: String,
                     from senderId: String,
                     text: String,
                     attachment: PendingAttachment? = nil,
                     reply: MessageModel.ReplyPreview? = nil) async throws {
        guard let threadsCol = await threadsCollection() else {
            print("✈️ Offline/local mode: not sending message.")
            return
        }
        let msgRef = threadsCol.document(threadId).collection("messages").document()
        var payload: [String: Any] = [
            "senderId": senderId,
            "text": text,
            "createdAt": FieldValue.serverTimestamp()
        ]

        var uploadedAttachment: UploadedAttachment?
        if let attachment {
            uploadedAttachment = try await AttachmentService.shared.upload(attachment, threadId: threadId)
        }

        if let uploadedAttachment {
            payload["mediaType"] = uploadedAttachment.kind.rawValue
            payload["mediaURL"] = uploadedAttachment.mediaURL
            if let thumb = uploadedAttachment.thumbnailURL {
                payload["thumbnailURL"] = thumb
            }
            payload["mediaWidth"] = uploadedAttachment.width
            payload["mediaHeight"] = uploadedAttachment.height
            if let duration = uploadedAttachment.duration {
                payload["mediaDuration"] = duration
            }
        }

        if let reply {
            payload["replyToMessageId"] = reply.messageId
            if let replySenderId = reply.senderId { payload["replyToSenderId"] = replySenderId }
            if let replySenderName = reply.senderName { payload["replyToSenderName"] = replySenderName }
            if let replyText = reply.text { payload["replyToText"] = replyText }
            if let mediaKind = reply.mediaKind { payload["replyToMediaType"] = mediaKind.rawValue }
        }

        try await msgRef.setData(payload, merge: true)

        let previewText: String
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previewText = text
        } else if let uploadedAttachment {
            previewText = uploadedAttachment.previewText
        } else {
            previewText = ""
        }

        try await threadsCol.document(threadId).updateData([
            "lastMessagePreview": previewText,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    // MARK: Listeners (run on main actor to match ListenerRegistration)
    @MainActor
    func listenThreads(for uid: String,
                       onChange: @escaping ([ThreadModel]) -> Void) -> ListenerRegistration {
        guard FirebaseApp.app() != nil else {
            onChange([])
            return DummyListener.shared
        }

        let q = Firestore.firestore()
            .collection("threads")
            .whereField("members", arrayContains: uid)
            .order(by: "updatedAt", descending: true)

        return q.addSnapshotListener { snap, err in
            guard let snap else {
                print("Threads listen error:", err?.localizedDescription ?? "")
                onChange([])
                return
            }
            let models = snap.documents.map { Self.mapToThread(id: $0.documentID, map: $0.data()) }
            onChange(models)
        }
    }

    @MainActor
    func listenMessages(threadId: String,
                        limit: Int = 100,
                        onChange: @escaping ([MessageModel]) -> Void) -> ListenerRegistration {
        guard FirebaseApp.app() != nil else {
            onChange([])
            return DummyListener.shared
        }

        let q = Firestore.firestore()
            .collection("threads").document(threadId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(toLast: limit)

        return q.addSnapshotListener { snap, err in
            guard let snap else {
                print("Messages listen error:", err?.localizedDescription ?? "")
                onChange([])
                return
            }
            let models: [MessageModel] = snap.documents.map { doc in
                let data = doc.data()
                let ts = (data["createdAt"] as? Timestamp)?.dateValue()
                let text = data["text"] as? String ?? ""
                let media = Self.mapMedia(from: data)
                let delivered = data["deliveredTo"] as? [String] ?? []
                let read = data["readBy"] as? [String] ?? []
                return MessageModel(
                    id: doc.documentID,
                    senderId: data["senderId"] as? String ?? "",
                    text: text,
                    createdAt: ts,
                    media: media,
                    deliveredTo: delivered,
                    readBy: read,
                    replyTo: ChatService.mapReply(from: data)
                )
            }
            onChange(models)
        }
    }

    // MARK: Mapping
    nonisolated private static func mapToThread(id: String, map: [String: Any]) -> ThreadModel {
        let members = map["members"] as? [String] ?? []
        let last = map["lastMessagePreview"] as? String
        let updated = (map["updatedAt"] as? Timestamp)?.dateValue()
        return ThreadModel(id: id, members: members, lastMessagePreview: last, updatedAt: updated)
    }

    nonisolated private static func mapMedia(from data: [String: Any]) -> MessageModel.Media? {
        if let attachments = data["attachments"] as? [[String: Any]],
           let first = attachments.first,
           let legacyAttachment = mapAttachmentDict(first) {
            return legacyAttachment
        }

        guard let typeRaw = data["mediaType"] as? String,
              let kind = MessageModel.Media.Kind(rawValue: typeRaw) else {
            return nil
        }

        func number(from value: Any?) -> Double? {
            if let doubleValue = value as? Double {
                return doubleValue
            }
            if let intValue = value as? Int {
                return Double(intValue)
            }
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            return nil
        }

        let url = data["mediaURL"] as? String
        let thumbnail = data["thumbnailURL"] as? String
        let width = number(from: data["mediaWidth"])
        let height = number(from: data["mediaHeight"])
        let duration = number(from: data["mediaDuration"])

        return MessageModel.Media(
            kind: kind,
            url: url,
            thumbnailURL: thumbnail,
            width: width,
            height: height,
            duration: duration,
            localData: nil,
            localThumbnailData: nil
        )
    }

    nonisolated private static func mapAttachmentDict(_ dict: [String: Any]) -> MessageModel.Media? {
        guard let typeRaw = dict["type"] as? String,
              let kind = MessageModel.Media.Kind(rawValue: typeRaw) else {
            return nil
        }

        func number(from value: Any?) -> Double? {
            if let doubleValue = value as? Double {
                return doubleValue
            }
            if let intValue = value as? Int {
                return Double(intValue)
            }
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            return nil
        }

        let url = dict["url"] as? String
        let thumbnail = dict["thumbnailURL"] as? String
        let width = number(from: dict["width"])
        let height = number(from: dict["height"])
        let duration = number(from: dict["duration"])

        return MessageModel.Media(
            kind: kind,
            url: url,
            thumbnailURL: thumbnail,
            width: width,
            height: height,
            duration: duration,
            localData: nil,
            localThumbnailData: nil
        )
    }

    nonisolated private static func mapReply(from data: [String: Any]) -> MessageModel.ReplyPreview? {
        guard let messageId = data["replyToMessageId"] as? String, !messageId.isEmpty else {
            return nil
        }

        let senderId = data["replyToSenderId"] as? String
        let senderName = data["replyToSenderName"] as? String
        let text = data["replyToText"] as? String

        let rawMediaType = (data["replyToMediaType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaKind: MessageModel.Media.Kind?
        if let rawMediaType, !rawMediaType.isEmpty {
            mediaKind = MessageModel.Media.Kind(rawValue: rawMediaType)
        } else {
            mediaKind = nil
        }

        return MessageModel.ReplyPreview(
            messageId: messageId,
            senderId: senderId,
            senderName: senderName,
            text: text,
            mediaKind: mediaKind
        )
    }
}
