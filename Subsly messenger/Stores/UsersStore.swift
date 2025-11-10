import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class UsersStore: ObservableObject {
    @Published private(set) var users: [String: AppUser] = [:]

    private var listeners: [String: ListenerRegistration] = [:]

    deinit {
        for listener in listeners.values {
            listener.remove()
        }
        listeners.removeAll()
    }

    func user(for uid: String) -> AppUser? {
        users[uid]
    }

    func displayName(for uid: String) -> String? {
        guard let user = users[uid] else { return nil }
        let preferred = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return preferred.isEmpty ? user.handle : preferred
    }

    func ensure(uid: String) async {
        if users[uid] == nil {
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

        startListening(uid: uid)
    }

    func upsert(_ user: AppUser) {
        guard let id = user.id else { return }
        users[id] = user
        startListening(uid: id)
    }

    private func startListening(uid: String) {
        guard listeners[uid] == nil else { return }
        listeners[uid] = UserService.shared.listenUser(uid: uid) { [weak self] user in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.users[uid] = user
                } else if self.users[uid] == nil {
                    self.users[uid] = self.fallbackUser(for: uid)
                }
            }
        }
    }

    private func fallbackUser(for uid: String) -> AppUser {
        AppUser(id: uid,
                handle: "user\(uid.prefix(6))",
                displayName: "User \(uid.prefix(6))",
                avatarURL: nil,
                bio: nil,
                createdAt: nil,
                isOnline: false,
                shareOnlineStatus: true,
                lastOnlineAt: nil)
    }
}
