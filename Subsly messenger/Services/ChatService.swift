import Foundation
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

enum ChatServiceError: LocalizedError {
    case notThreadMember
    case threadUnavailable
    case emptyMessage
    case textTooLong
    case tooManyAttachments
    case attachmentValidationFailed

    var errorDescription: String? {
        switch self {
        case .notThreadMember: return "You’re no longer a member of this conversation."
        case .threadUnavailable: return "This conversation is unavailable."
        case .emptyMessage: return "Messages must include text or an attachment."
        case .textTooLong: return "Messages are limited to 4,000 characters."
        case .tooManyAttachments: return "You can attach up to 20 items per message."
        case .attachmentValidationFailed: return "One of the attachments could not be processed."
        }
    }
}

// ListenerRegistration is main-actor isolated; keep this type main-actor too.
@MainActor
final class DummyListener: NSObject, ListenerRegistration {
    static let shared = DummyListener()
    private override init() {}
    func remove() {}
}

actor ChatService {
    // MARK: - Singleton
    nonisolated static let shared = ChatService()

    // MARK: - Debug helpers (nonisolated -> callable anywhere, no actor hop)
    nonisolated static func dbg(_ items: Any..., fn: String = #function) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = items.map { String(describing: $0) }.joined(separator: " ")
        print("🧭 [ChatService][\(fn)] \(ts): \(msg)")
    }

    nonisolated static func enableFirebaseSDKDebugIfNeeded() {
        struct Once { static var did = false }
        if Once.did { return }
        FirebaseConfiguration.shared.setLoggerLevel(.debug)
        Once.did = true
        dbg("Firebase logger level set to .debug")
    }

    nonisolated static func dumpNSError(_ error: Error, fn: String = #function) {
        let ns = error as NSError
        dbg("NSError domain=\(ns.domain) code=\(ns.code)", fn: fn)
        if !ns.userInfo.isEmpty {
            dbg("userInfo keys:", Array(ns.userInfo.keys), fn: fn)
            if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] { dbg("failureReason:", reason, fn: fn) }
            if let descr = ns.userInfo[NSLocalizedDescriptionKey] { dbg("desc:", descr, fn: fn) }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                dbg("underlying domain=\(underlying.domain) code=\(underlying.code) info=\(underlying.userInfo)", fn: fn)
            }
        }
    }

    // MARK: - Limits / validation
    private let maxAttachmentCount = 20
    private let maxImageBytes = 6 * 1024 * 1024
    private let maxVideoBytes: Int64 = Int64(40 * 1024 * 1024)
    private let maxVideoDuration: Double = 180
    private let maxAudioBytes: Int64 = Int64(12 * 1024 * 1024)
    private let maxAudioDuration: Double = 5 * 60

    // MARK: - Firestore helpers
    private func isConfigured() -> Bool { FirebaseApp.app() != nil }
    private func threadsCollection() -> CollectionReference? {
        guard isConfigured() else { return nil }
        return Firestore.firestore().collection("threads")
    }

    // Deterministic 1:1 id
    nonisolated func threadId(for a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    // MARK: - Attachment validation (actor-isolated)
    private func validateAttachments(_ attachments: [PendingAttachment]) throws {
        guard attachments.count <= maxAttachmentCount else {
            throw ChatServiceError.tooManyAttachments
        }
        for attachment in attachments {
            switch attachment.kind {
            case .image(let data, let w, let h):
                guard w > 0, h > 0, data.count <= maxImageBytes else {
                    throw ChatServiceError.attachmentValidationFailed
                }
            case .video(let fileURL, _, let w, let h, let duration):
                guard w > 0, h > 0, duration <= maxVideoDuration else {
                    throw ChatServiceError.attachmentValidationFailed
                }
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    if let size = attrs[.size] as? NSNumber, size.int64Value > maxVideoBytes {
                        throw ChatServiceError.attachmentValidationFailed
                    }
                } catch {
                    throw ChatServiceError.attachmentValidationFailed
                }
            case .audio(let fileURL, let duration):
                guard duration > 0, duration <= maxAudioDuration else {
                    throw ChatServiceError.attachmentValidationFailed
                }
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    if let size = attrs[.size] as? NSNumber, size.int64Value > maxAudioBytes {
                        throw ChatServiceError.attachmentValidationFailed
                    }
                } catch {
                    throw ChatServiceError.attachmentValidationFailed
                }
            }
        }
    }

    // MARK: - Ensure thread
    func ensureThread(currentUID: String, otherUID: String) async throws -> ThreadModel {
        ChatService.enableFirebaseSDKDebugIfNeeded()
        ChatService.dbg("ensureThread current=\(currentUID) other=\(otherUID)")
        let tid = threadId(for: currentUID, otherUID)
        guard let threadsCol = threadsCollection() else {
            ChatService.dbg("Firestore not configured; returning local model only.")
            return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
        }
        try await threadsCol.document(tid).setData(["members": [currentUID, otherUID]], merge: true)
        ChatService.dbg("ensureThread upserted members for tid=\(tid)")
        return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
    }

    // MARK: - Send message
    func sendMessage(threadId: String,
                     from senderId: String,
                     text: String,
                     clientMessageId: String,
                     attachments: [PendingAttachment] = [],
                     reply: MessageModel.ReplyPreview? = nil) async throws {

        ChatService.enableFirebaseSDKDebugIfNeeded()
        let authUid = Auth.auth().currentUser?.uid
        ChatService.dbg("sendMessage tid=\(threadId) senderId=\(senderId) authUid=\(authUid ?? "nil") textLen=\(text.count) attachCount=\(attachments.count)")
        guard let authUid, authUid == senderId else {
            ChatService.dbg("AUTH MISMATCH: senderId != auth.uid")
            throw ChatServiceError.notThreadMember
        }

        guard let threadsCol = threadsCollection() else {
            ChatService.dbg("Firestore not configured; abort send.")
            return
        }

        try validateAttachments(attachments)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            ChatService.dbg("Rejecting empty message.")
            throw ChatServiceError.emptyMessage
        }
        if trimmed.count > 4000 {
            ChatService.dbg("Rejecting too long text len=\(trimmed.count)")
            throw ChatServiceError.textTooLong
        }

        let threadRef = threadsCol.document(threadId)

        do {
            let snap = try await threadRef.getDocument()
            guard snap.exists else {
                ChatService.dbg("Thread doc not found.")
                throw ChatServiceError.threadUnavailable
            }
            let members = snap.data()?["members"] as? [String] ?? []
            ChatService.dbg("Thread members=", members)
            guard members.contains(senderId) else {
                ChatService.dbg("Sender not in thread members.")
                throw ChatServiceError.notThreadMember
            }
        } catch {
            ChatService.dbg("getDocument failed"); ChatService.dumpNSError(error)
            throw ChatServiceError.threadUnavailable
        }

        let msgRef = threadRef.collection("messages").document()
        var payload: [String: Any] = [
            "senderId": senderId,
            "clientMessageId": clientMessageId,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if !trimmed.isEmpty { payload["text"] = trimmed }

        let uploaded = try await AttachmentService.shared.upload(attachments, threadId: threadId)
        ChatService.dbg("uploaded attachments count=", uploaded.count)

        if let first = uploaded.first {
            payload["mediaType"] = first.kind.rawValue
            payload["mediaURL"] = first.mediaURL
            if let t = first.thumbnailURL { payload["thumbnailURL"] = t }
            if let width = first.width { payload["mediaWidth"] = width }
            if let height = first.height { payload["mediaHeight"] = height }
            if let d = first.duration { payload["mediaDuration"] = d }
        }
        if !uploaded.isEmpty {
            payload["attachments"] = uploaded.map { a in
                var d: [String: Any] = [
                    "type": a.kind.rawValue,
                    "url": a.mediaURL
                ]
                if let width = a.width { d["width"] = width }
                if let height = a.height { d["height"] = height }
                if let t = a.thumbnailURL { d["thumbnailURL"] = t }
                if let dur = a.duration { d["duration"] = dur }
                return d
            }
        }
        if let r = reply {
            payload["replyToMessageId"] = r.messageId
            if let s = r.senderId { payload["replyToSenderId"] = s }
            if let n = r.senderName { payload["replyToSenderName"] = n }
            if let tx = r.text { payload["replyToText"] = tx }
            if let mk = r.mediaKind { payload["replyToMediaType"] = mk.rawValue }
        }

        do {
            try await msgRef.setData(payload, merge: true)
            ChatService.dbg("Message written id=\(msgRef.documentID)")
        } catch {
            ChatService.dbg("setData failed"); ChatService.dumpNSError(error)
            throw error
        }

        let preview: String = {
            if !trimmed.isEmpty { return trimmed }
            if uploaded.isEmpty { return "" }
            if uploaded.count == 1, let f = uploaded.first { return f.previewText }
            let counts = uploaded.reduce(into: [MessageModel.Media.Kind: Int]()) { $0[$1.kind, default: 0] += 1 }
            return counts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { kind, c in
                    switch kind {
                    case .image:
                        return c > 1 ? "\(c) Photos" : "Photo"
                    case .video:
                        return c > 1 ? "\(c) Videos" : "Video"
                    case .audio:
                        return c > 1 ? "\(c) Voice messages" : "Voice message"
                    }
                }
                .joined(separator: ", ")
        }()

        do {
            try await threadRef.updateData([
                "lastMessagePreview": preview,
                "updatedAt": FieldValue.serverTimestamp()
            ])
            ChatService.dbg("Thread updated preview + timestamp")
        } catch {
            ChatService.dbg("threadRef.updateData failed"); ChatService.dumpNSError(error)
            throw error
        }
    }

    // MARK: - Listeners with deep debug
    @MainActor
    func listenThreads(for uidHint: String,
                       onChange: @escaping ([ThreadModel]) -> Void) -> ListenerRegistration {
        ChatService.enableFirebaseSDKDebugIfNeeded()

        guard FirebaseApp.app() != nil else {
            ChatService.dbg("No FirebaseApp; abort listen.")
            onChange([]); return DummyListener.shared
        }
        let authUid = Auth.auth().currentUser?.uid
        ChatService.dbg("listenThreads uidHint=\(uidHint) authUid=\(authUid ?? "nil")")

        guard let authUid else {
            ChatService.dbg("No Auth user present at listen time.")
            onChange([]); return DummyListener.shared
        }
        if authUid != uidHint {
            ChatService.dbg("UID mismatch: using authUid=\(authUid) (hint=\(uidHint))")
        }
        let uid = authUid

        let threadsCol = Firestore.firestore().collection("threads")
        let query = threadsCol.whereField("members", arrayContains: uid)
                              .order(by: "updatedAt", descending: true)
        ChatService.dbg("Query: threads WHERE members ARRAY_CONTAINS \(uid) ORDER BY updatedAt DESC")

        // Live listener
        return query.addSnapshotListener { snap, err in
            if let err = err {
                ChatService.dbg("LIVE LISTEN FAILED"); ChatService.dumpNSError(err)
                onChange([]); return
            }
            guard let snap else {
                ChatService.dbg("LIVE LISTEN: nil snapshot, no error"); onChange([]); return
            }
            let models = snap.documents.map { Self.mapToThread(id: $0.documentID, map: $0.data()) }
            ChatService.dbg("LIVE LISTEN OK, docs=\(models.count)")
            onChange(models)
        }
    }

    @MainActor
    func listenMessages(threadId: String,
                        limit: Int = 100,
                        onChange: @escaping ([MessageModel]) -> Void) -> ListenerRegistration {
        ChatService.enableFirebaseSDKDebugIfNeeded()
        ChatService.dbg("listenMessages tid=\(threadId) limit=\(limit)")

        guard FirebaseApp.app() != nil else {
            ChatService.dbg("No FirebaseApp; abort messages listen.")
            onChange([]); return DummyListener.shared
        }

        let q = Firestore.firestore()
            .collection("threads").document(threadId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(toLast: limit)

        // Probe
        q.limit(to: 1).getDocuments { snap, err in
            if let err = err {
                ChatService.dbg("PROBE messages one-shot failed"); ChatService.dumpNSError(err)
            } else {
                ChatService.dbg("PROBE messages one-shot OK count=\(snap?.documents.count ?? 0)")
            }
        }

        return q.addSnapshotListener { snap, err in
            if let err = err {
                ChatService.dbg("LIVE messages listen failed"); ChatService.dumpNSError(err)
                onChange([]); return
            }
            guard let snap else {
                ChatService.dbg("LIVE messages: nil snapshot"); onChange([]); return
            }
            let models: [MessageModel] = snap.documents.map { doc in
                let data = doc.data()
                return MessageModel(
                    id: doc.documentID,
                    clientMessageId: data["clientMessageId"] as? String,
                    senderId: data["senderId"] as? String ?? "",
                    text: data["text"] as? String ?? "",
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
                    media: Self.mapMediaList(from: data),
                    deliveredTo: data["deliveredTo"] as? [String] ?? [],
                    readBy: data["readBy"] as? [String] ?? [],
                    replyTo: ChatService.mapReply(from: data)
                )
            }
            ChatService.dbg("LIVE messages OK count=\(models.count)")
            onChange(models)
        }
    }

    // MARK: - Presence probe (optional helper for debugging a specific doc)
    @MainActor
    func debugProbePresence(threadId: String, userId: String) {
        ChatService.dbg("debugProbePresence tid=\(threadId) uid=\(userId)")
        guard FirebaseApp.app() != nil else {
            ChatService.dbg("No FirebaseApp; abort presence probe.")
            return
        }
        let ref = Firestore.firestore()
            .collection("threads").document(threadId)
            .collection("presence").document(userId)

        ref.getDocument { snap, err in
            if let err = err {
                ChatService.dbg("PRESENCE PROBE FAILED"); ChatService.dumpNSError(err)
            } else {
                let exists = snap?.exists ?? false
                ChatService.dbg("PRESENCE PROBE OK exists=\(exists) data=\(snap?.data() ?? [:])")
            }
        }
    }

    // MARK: - Mapping
    nonisolated private static func mapToThread(id: String, map: [String: Any]) -> ThreadModel {
        let members = map["members"] as? [String] ?? []
        let last = map["lastMessagePreview"] as? String
        let updated = (map["updatedAt"] as? Timestamp)?.dateValue()
        return ThreadModel(id: id, members: members, lastMessagePreview: last, updatedAt: updated)
    }

    nonisolated private static func mapMediaList(from data: [String: Any]) -> [MessageModel.Media] {
        if let attachments = data["attachments"] as? [[String: Any]] {
            let mapped = attachments.compactMap { mapAttachmentDict($0) }
            if !mapped.isEmpty { return mapped }
        }
        if let legacy = mapLegacyMedia(from: data) { return [legacy] }
        return []
    }

    nonisolated private static func mapLegacyMedia(from data: [String: Any]) -> MessageModel.Media? {
        guard let typeRaw = data["mediaType"] as? String,
              let kind = MessageModel.Media.Kind(rawValue: typeRaw) else { return nil }

        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        return MessageModel.Media(
            kind: kind,
            url: data["mediaURL"] as? String,
            thumbnailURL: data["thumbnailURL"] as? String,
            width: number(data["mediaWidth"]),
            height: number(data["mediaHeight"]),
            duration: number(data["mediaDuration"]),
            localData: nil,
            localThumbnailData: nil,
            localFilePath: nil
        )
    }

    nonisolated private static func mapAttachmentDict(_ dict: [String: Any]) -> MessageModel.Media? {
        guard let typeRaw = dict["type"] as? String,
              let kind = MessageModel.Media.Kind(rawValue: typeRaw) else { return nil }

        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        return MessageModel.Media(
            kind: kind,
            url: dict["url"] as? String,
            thumbnailURL: dict["thumbnailURL"] as? String,
            width: number(dict["width"]),
            height: number(dict["height"]),
            duration: number(dict["duration"]),
            localData: nil,
            localThumbnailData: nil,
            localFilePath: nil
        )
    }

    nonisolated private static func mapReply(from data: [String: Any]) -> MessageModel.ReplyPreview? {
        guard let messageId = data["replyToMessageId"] as? String, !messageId.isEmpty else { return nil }
        let raw = (data["replyToMediaType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaKind = raw.flatMap { MessageModel.Media.Kind(rawValue: $0) }
        return MessageModel.ReplyPreview(
            messageId: messageId,
            senderId: data["replyToSenderId"] as? String,
            senderName: data["replyToSenderName"] as? String,
            text: data["replyToText"] as? String,
            mediaKind: mediaKind
        )
    }
}
