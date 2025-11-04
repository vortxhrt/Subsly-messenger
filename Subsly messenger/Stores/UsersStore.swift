import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class UsersStore: ObservableObject {
    @Published private(set) var users: [String: AppUser] = [:]
    private var listeners: [String: ListenerRegistration] = [:]

    func user(for uid: String) -> AppUser? {
        users[uid]
    }

    func displayName(for uid: String) -> String? {
        guard let user = users[uid] else { return nil }
        let preferred = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return preferred.isEmpty ? user.handle : preferred
    }

    func ensure(uid: String) async {
        ensureListener(for: uid)

        if users[uid] != nil { return }
        do {
            if let user = try await UserService.shared.fetchUser(uid: uid) {
                users[uid] = user
            } else {
                users[uid] = fallbackUser(for: uid)
            }
        } catch {
            print("UsersStore.ensure(\(uid)) error:", error.localizedDescription)
            users[uid] = fallbackUser(for: uid)
        }
    }

    func upsert(_ user: AppUser) {
        guard let id = user.id else { return }
        ensureListener(for: id)
        users[id] = user
    }

    deinit {
        for listener in listeners.values {
            listener.remove()
        }
        listeners.removeAll()
    }

    private func ensureListener(for uid: String) {
        guard listeners[uid] == nil else { return }
        let listener = UserService.shared.listenUser(uid: uid) { [weak self] user in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.users[uid] = user
                } else {
                    self.users[uid] = self.fallbackUser(for: uid)
                }
            }
        }
        listeners[uid] = listener
    }

    private func fallbackUser(for uid: String) -> AppUser {
        AppUser(id: uid,
                handle: "user\(uid.prefix(6))",
                displayName: "User \(uid.prefix(6))",
                avatarURL: nil,
                bio: nil,
                createdAt: nil,
                isOnline: false,
                lastActiveAt: nil,
                isStatusHidden: false)
    }
}
