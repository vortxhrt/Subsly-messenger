import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class ThreadsStore: ObservableObject {
    static let shared = ThreadsStore()
    @Published private(set) var threads: [ThreadModel] = []
    private var listener: ListenerRegistration?

    func start(uid: String) {
        stop()
        listener = ChatService.shared.listenThreads(for: uid) { [weak self] models in
            Task { @MainActor in self?.threads = models }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }
}
