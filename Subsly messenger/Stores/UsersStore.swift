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
                #if DEBUG
                print("UsersStore.ensure(\(uid)) error:", error.localizedDescription)
                #endif
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

    // MARK: - Listening

    private func startListening(uid: String) {
        guard listeners[uid] == nil else { return }

        // Hop off the main actor to call the actor-isolated UserService method,
        // then come back to the main actor to mutate @Published state.
        Task { [weak self] in
            guard let self else { return }

            // Call the actor-isolated API.
            let registration = await UserService.shared.listenUser(uid: uid) { [weak self] user in
                // Ensure UI/state updates happen on the main actor.
                Task { @MainActor in
                    self?.applyUserUpdate(user, for: uid)
                }
            }

            // Store the listener on the main actor.
            await MainActor.run {
                self.listeners[uid] = registration
            }
        }
    }

    // MARK: - Helpers

    private func fallbackUser(for uid: String) -> AppUser {
        AppUser(
            id: uid,
            handle: "user\(uid.prefix(6))",
            displayName: "User \(uid.prefix(6))",
            avatarURL: nil,
            bio: nil,
            createdAt: nil,
            isOnline: false,
            shareOnlineStatus: true,
            lastOnlineAt: nil
        )
    }

    private func applyUserUpdate(_ user: AppUser?, for uid: String) {
        if let user {
            users[uid] = user
        } else if users[uid] == nil {
            users[uid] = fallbackUser(for: uid)
        }
    }
}
