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
    func sendMessage(threadId: String, from senderId: String, text: String) async throws {
        guard let threadsCol = await threadsCollection() else {
            print("✈️ Offline/local mode: not sending message.")
            return
        }
        let msgRef = threadsCol.document(threadId).collection("messages").document()
        try await msgRef.setData([
            "senderId": senderId,
            "text": text,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)

        try await threadsCol.document(threadId).updateData([
            "lastMessagePreview": text,
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
