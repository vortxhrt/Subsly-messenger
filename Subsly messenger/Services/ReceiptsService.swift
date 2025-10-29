import Foundation
import FirebaseFirestore

/// Firestore helpers for delivery/read receipts on 1:1 threads.
/// Message schema fields expected per document:
///   deliveredTo: [String]   // user IDs that have received the message
///   readBy:      [String]   // user IDs that have read the message
final class ReceiptsService {
    static let shared = ReceiptsService()
    private init() {}

    private let db = Firestore.firestore()

    /// Mark the message as delivered *to* `uid` (idempotent).
    func markDelivered(threadId: String, messageId: String, to uid: String) async {
        let ref = db.collection("threads").document(threadId)
            .collection("messages").document(messageId)
        do {
            try await ref.updateData([
                "deliveredTo": FieldValue.arrayUnion([uid])
            ])
        } catch {
            do {
                try await ref.setData(["deliveredTo": [uid]], merge: true)
            } catch {
                print("⚠️ markDelivered failed: \(error.localizedDescription)")
            }
        }
    }

    /// Mark the message as read *by* `uid` (idempotent).
    func markRead(threadId: String, messageId: String, by uid: String) async {
        let ref = db.collection("threads").document(threadId)
            .collection("messages").document(messageId)
        do {
            try await ref.updateData([
                "readBy": FieldValue.arrayUnion([uid]),
                "deliveredTo": FieldValue.arrayUnion([uid]) // read implies delivered
            ])
        } catch {
            do {
                try await ref.setData([
                    "readBy": [uid],
                    "deliveredTo": [uid]
                ], merge: true)
            } catch {
                print("⚠️ markRead failed: \(error.localizedDescription)")
            }
        }
    }

    /// Listen for receipt changes on a single message.
    /// Returns (deliveredTo, readBy) as sets of UIDs.
    @discardableResult
    func listenReceipts(
        threadId: String,
        messageId: String,
        onChange: @escaping (_ deliveredTo: Set<String>, _ readBy: Set<String>) -> Void
    ) -> ListenerRegistration {
        let ref = db.collection("threads").document(threadId)
            .collection("messages").document(messageId)
        return ref.addSnapshotListener { snap, _ in
            let delivered = (snap?.get("deliveredTo") as? [String]) ?? []
            let read = (snap?.get("readBy") as? [String]) ?? []
            onChange(Set(delivered), Set(read))
        }
    }
}
