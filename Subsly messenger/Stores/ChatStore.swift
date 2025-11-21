import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [MessageModel] = []
    private var listener: ListenerRegistration?
    
    // E2EE: Store the other user's public key to decrypt incoming messages
    private var otherUserPublicKey: String?

    // UPDATED: Requires otherUserId to fetch keys for decryption
    func start(threadId: String, otherUserId: String) {
        stop()
        
        Task {
            // 1. Fetch other user's public key for decryption
            if let doc = try? await Firestore.firestore().collection("users").document(otherUserId).getDocument(),
               let key = doc.data()?["publicKey"] as? String {
                self.otherUserPublicKey = key
            }
            
            // 2. Start listener
            self.listener = ChatService.shared.listenMessages(threadId: threadId) { [weak self] models in
                guard let self else { return }
                
                let myId = SessionStore.shared.id
                
                // 3. Process and Decrypt
                let processedMessages = models.map { msg -> MessageModel in
                    // If message has no text, return as is
                    if msg.text.isEmpty { return msg }
                    
                    var decryptedText = msg.text
                    
                    // A. If I sent it (My Private Key + Their Public Key)
                    if msg.senderId == myId {
                        if let key = self.otherUserPublicKey {
                            if let decrypted = try? CryptoService.shared.decrypt(encryptedString: msg.text, otherUserPublicKeyString: key) {
                                decryptedText = decrypted
                            }
                        }
                    }
                    // B. If They sent it (My Private Key + Their Public Key)
                    // Note: In 1:1 ECDH, the shared secret is identical for both directions.
                    else if msg.senderId == otherUserId {
                        if let key = self.otherUserPublicKey {
                            if let decrypted = try? CryptoService.shared.decrypt(encryptedString: msg.text, otherUserPublicKeyString: key) {
                                decryptedText = decrypted
                            }
                        }
                    }
                    
                    // Return copy with decrypted text
                    return MessageModel(
                        id: msg.id,
                        clientMessageId: msg.clientMessageId,
                        senderId: msg.senderId,
                        text: decryptedText,
                        createdAt: msg.createdAt,
                        media: msg.media,
                        deliveredTo: msg.deliveredTo,
                        readBy: msg.readBy,
                        replyTo: msg.replyTo
                    )
                }
                
                Task { @MainActor in self.messages = processedMessages }
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        otherUserPublicKey = nil
    }
}
