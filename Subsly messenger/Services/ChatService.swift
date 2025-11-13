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
#if DEBUG
        FrontEndLog.chat.debug("ensureThread current=\(currentUID, privacy: .public) other=\(otherUID, privacy: .public) tid=\(tid, privacy: .public)")
#endif
        guard let threadsCol = await threadsCollection() else {
#if DEBUG
            FrontEndLog.chat.error("ensureThread offline fallback tid=\(tid, privacy: .public)")
#endif
            return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
        }
        try await threadsCol.document(tid).setData(["members": [currentUID, otherUID]], merge: true)
#if DEBUG
        let membersLabel = "\(currentUID),\(otherUID)"
        FrontEndLog.chat.debug("ensureThread persisted tid=\(tid, privacy: .public) members=\(membersLabel, privacy: .public)")
#endif
        return ThreadModel(id: tid, members: [currentUID, otherUID], lastMessagePreview: nil, updatedAt: nil)
    }

    // MARK: Send message + bump preview/timestamp
    func sendMessage(threadId: String, from senderId: String, text: String) async throws {
#if DEBUG
        let snippet = MessageModel.logSnippet(from: text)
        if MessageModel.isLikelyVoiceNotePayload(text) {
            FrontEndLog.voice.debug("sendMessage invoked (voice candidate) threadId=\(threadId, privacy: .public) sender=\(senderId, privacy: .public) snippet=\(snippet, privacy: .public)")
        } else {
            FrontEndLog.chat.debug("sendMessage invoked threadId=\(threadId, privacy: .public) sender=\(senderId, privacy: .public) snippet=\(snippet, privacy: .public)")
        }
#endif
        guard let threadsCol = await threadsCollection() else {
#if DEBUG
            FrontEndLog.chat.error("sendMessage aborted (Firebase unavailable) threadId=\(threadId, privacy: .public) sender=\(senderId, privacy: .public)")
#endif
            return
        }
        let msgRef = threadsCol.document(threadId).collection("messages").document()
        try await msgRef.setData([
            "senderId": senderId,
            "text": text,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)
#if DEBUG
        FrontEndLog.chat.debug("sendMessage stored docId=\(msgRef.documentID, privacy: .public) threadId=\(threadId, privacy: .public) sender=\(senderId, privacy: .public)")
        if MessageModel.isLikelyVoiceNotePayload(text) {
            FrontEndLog.voice.debug("sendMessage stored voice payload docId=\(msgRef.documentID, privacy: .public) threadId=\(threadId, privacy: .public)")
        }
#endif

        try await threadsCol.document(threadId).updateData([
            "lastMessagePreview": text,
            "updatedAt": FieldValue.serverTimestamp()
        ])
#if DEBUG
        FrontEndLog.chat.debug("sendMessage updated thread preview threadId=\(threadId, privacy: .public) preview=\(MessageModel.logSnippet(from: text), privacy: .public)")
#endif
    }

    // MARK: Listeners (run on main actor to match ListenerRegistration)
    @MainActor
    func listenThreads(for uid: String,
                       onChange: @escaping ([ThreadModel]) -> Void) -> ListenerRegistration {
        guard FirebaseApp.app() != nil else {
#if DEBUG
            FrontEndLog.chat.error("listenThreads skipped - Firebase not configured for uid=\(uid, privacy: .public)")
#endif
            onChange([])
            return DummyListener.shared
        }

        let q = Firestore.firestore()
            .collection("threads")
            .whereField("members", arrayContains: uid)
            .order(by: "updatedAt", descending: true)

        return q.addSnapshotListener { snap, err in
            guard let snap else {
#if DEBUG
                FrontEndLog.chat.error("listenThreads error uid=\(uid, privacy: .public) message=\(err?.localizedDescription ?? "unknown", privacy: .public)")
#endif
                onChange([])
                return
            }
            let models = snap.documents.map { Self.mapToThread(id: $0.documentID, map: $0.data()) }
#if DEBUG
            FrontEndLog.chat.debug("listenThreads snapshot uid=\(uid, privacy: .public) count=\(models.count, privacy: .public)")
#endif
            onChange(models)
        }
    }

    @MainActor
    func listenMessages(threadId: String,
                        limit: Int = 100,
                        onChange: @escaping ([MessageModel]) -> Void) -> ListenerRegistration {
        guard FirebaseApp.app() != nil else {
#if DEBUG
            FrontEndLog.chat.error("listenMessages skipped - Firebase not configured threadId=\(threadId, privacy: .public)")
#endif
            onChange([])
            return DummyListener.shared
        }

        let q = Firestore.firestore()
            .collection("threads").document(threadId)
            .collection("messages")
            .order(by: "createdAt", descending: false)
            .limit(toLast: limit)

#if DEBUG
        FrontEndLog.chat.debug("listenMessages start threadId=\(threadId, privacy: .public) limit=\(limit, privacy: .public)")
#endif
        return q.addSnapshotListener { snap, err in
            guard let snap else {
#if DEBUG
                FrontEndLog.chat.error("listenMessages error threadId=\(threadId, privacy: .public) message=\(err?.localizedDescription ?? "unknown", privacy: .public)")
#endif
                onChange([])
                return
            }
#if DEBUG
            FrontEndLog.chat.debug("listenMessages snapshot threadId=\(threadId, privacy: .public) documents=\(snap.documents.count, privacy: .public)")
            for doc in snap.documents {
                let data = doc.data()
                let text = data["text"] as? String ?? ""
                let sender = data["senderId"] as? String ?? ""
                let snippet = MessageModel.logSnippet(from: text)
                if MessageModel.isLikelyVoiceNotePayload(text) {
                    FrontEndLog.voice.debug("listenMessages doc voiceCandidate threadId=\(threadId, privacy: .public) docId=\(doc.documentID, privacy: .public) sender=\(sender, privacy: .public) snippet=\(snippet, privacy: .public)")
                } else {
                    FrontEndLog.chat.debug("listenMessages doc threadId=\(threadId, privacy: .public) docId=\(doc.documentID, privacy: .public) sender=\(sender, privacy: .public) snippet=\(snippet, privacy: .public)")
                }
            }
#endif
            let models: [MessageModel] = snap.documents.map { doc in
                let data = doc.data()
                let ts = (data["createdAt"] as? Timestamp)?.dateValue()
                return MessageModel(
                    id: doc.documentID,
                    senderId: data["senderId"] as? String ?? "",
                    text: data["text"] as? String ?? "",
                    createdAt: ts
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
}
