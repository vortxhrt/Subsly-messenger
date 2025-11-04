import Foundation
import Combine

@MainActor
final class UsersStore: ObservableObject {
    @Published private(set) var users: [String: AppUser] = [:]

    func user(for uid: String) -> AppUser? {
        users[uid]
    }

    func displayName(for uid: String) -> String? {
        guard let user = users[uid] else { return nil }
        let preferred = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return preferred.isEmpty ? user.handle : preferred
    }

    func ensure(uid: String) async {
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
        users[id] = user
    }

    private func fallbackUser(for uid: String) -> AppUser {
        AppUser(id: uid,
                handle: "user\(uid.prefix(6))",
                displayName: "User \(uid.prefix(6))",
                avatarURL: nil,
                bio: nil)
    }
}
