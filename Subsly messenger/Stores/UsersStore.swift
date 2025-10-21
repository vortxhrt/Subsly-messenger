import Foundation
import Combine

@MainActor
final class UsersStore: ObservableObject {
    @Published private(set) var names: [String: String] = [:] // uid -> cached display name/handle

    func name(for uid: String) -> String? { names[uid] }

    func ensure(uid: String) async {
        if names[uid] != nil { return }
        do {
            if let name = try await UserService.shared.fetchUserName(uid: uid) {
                names[uid] = name
            } else {
                names[uid] = "User \(uid.prefix(6))"
            }
        } catch {
            print("UsersStore.ensure(\(uid)) error:", error.localizedDescription)
            names[uid] = "User \(uid.prefix(6))"
        }
    }
}
