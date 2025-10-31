import Foundation
import FirebaseFirestore

/// Firestore helpers for delivery/read receipts on 1:1 threads.
/// Message doc schema adds (arrays of UIDs):
///   deliveredTo: [String]
///   readBy:      [String]
final class ReceiptsService {
    static let shared = ReceiptsService()
    private init() {}

    private let db = Firestore.firestore()

    /// Mark delivered (idempotent). Safe if field doesn't exist yet.
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

    /// Mark read (idempotent). Also implies delivered.
    func markRead(threadId: String, messageId: String, by uid: String) async {
        let ref = db.collection("threads").document(threadId)
            .collection("messages").document(messageId)
        do {
            try await ref.updateData([
                "readBy": FieldValue.arrayUnion([uid]),
                "deliveredTo": FieldValue.arrayUnion([uid])
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

    /// Listen to receipt changes for one message.
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
