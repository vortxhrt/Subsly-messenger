import Foundation
import Combine
import FirebaseFirestore
import FirebaseAuth

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [MessageModel] = []
    private var listener: ListenerRegistration?
    private var otherUserPublicKey: String?

    func start(threadId: String, otherUserId: String) {
        stop()
        
        Task {
            if let doc = try? await Firestore.firestore().collection("users").document(otherUserId).getDocument(),
               let key = doc.data()?["publicKey"] as? String {
                self.otherUserPublicKey = key
            }
            
            self.listener = ChatService.shared.listenMessages(threadId: threadId) { [weak self] models in
                guard let self else { return }
                let myId = SessionStore.shared.id
                
                // 1. Decrypt Messages
                let decryptedMessages = models.map { msg -> MessageModel in
                    if msg.text.isEmpty { return msg }
                    var decryptedText = msg.text
                    
                    if msg.senderId == myId || msg.senderId == otherUserId {
                        if let key = self.otherUserPublicKey {
                            if let decrypted = try? CryptoService.shared.decrypt(encryptedString: msg.text, otherUserPublicKeyString: key) {
                                decryptedText = decrypted
                            }
                        }
                    }
                    
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
                
                // 2. AUDIT FIX: Resolve Reply Text Locally
                // Since we don't store replyText in DB anymore, we must look it up.
                let resolvedMessages = decryptedMessages.map { msg -> MessageModel in
                    guard let reply = msg.replyTo, reply.text == nil else { return msg }
                    
                    // Find the original message in the current list
                    if let parent = decryptedMessages.first(where: { $0.id == reply.messageId }) {
                        let newReply = MessageModel.ReplyPreview(
                            messageId: reply.messageId,
                            senderId: reply.senderId,
                            senderName: reply.senderName,
                            text: parent.text, // Use decrypted text from parent
                            mediaKind: reply.mediaKind
                        )
                        
                        // Return copy with updated reply info
                        return MessageModel(
                            id: msg.id,
                            clientMessageId: msg.clientMessageId,
                            senderId: msg.senderId,
                            text: msg.text,
                            createdAt: msg.createdAt,
                            media: msg.media,
                            deliveredTo: msg.deliveredTo,
                            readBy: msg.readBy,
                            replyTo: newReply
                        )
                    }
                    return msg
                }
                
                Task { @MainActor in self.messages = resolvedMessages }
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        otherUserPublicKey = nil
    }
}
