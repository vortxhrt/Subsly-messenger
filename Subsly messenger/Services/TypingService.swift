import Foundation
import FirebaseFirestore

final class TypingService {
    static let shared = TypingService()
    private init() {}

    private let db = Firestore.firestore()

    // Current user toggles their typing state
    func setTyping(threadId: String, userId: String, isTyping: Bool) async throws {
        let ref = db
            .collection("threads").document(threadId)
            .collection("presence").document(userId)

        try await ref.setData([
            "isTyping": isTyping,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    // Listen to the OTHER participant's typing state
    @discardableResult
    func listenOtherTyping(
        threadId: String,
        otherUserId: String,
        onChange: @escaping (Bool) -> Void
    ) -> ListenerRegistration {
        let ref = db
            .collection("threads").document(threadId)
            .collection("presence").document(otherUserId)

        return ref.addSnapshotListener { snap, _ in
            let typing = (snap?.data()?["isTyping"] as? Bool) ?? false
            onChange(typing)
        }
    }
}
