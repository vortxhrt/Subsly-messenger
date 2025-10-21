import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [MessageModel] = []
    private var listener: ListenerRegistration?

    func start(threadId: String) {
        stop()
        listener = ChatService.shared.listenMessages(threadId: threadId) { [weak self] models in
            Task { @MainActor in self?.messages = models }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }
}
