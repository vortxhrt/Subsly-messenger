import Foundation
import SwiftUI
import Combine        // <- needed for ObservableObject / @Published
import FirebaseAuth

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var isLoading: Bool = true
    @Published var currentUser: AppUser?   // optional while signed-out/loading

    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {
        // Keep session in sync with Firebase Auth
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { await self?.reload(for: user?.uid) }
        }
    }

    deinit {
        if let h = authHandle { Auth.auth().removeStateDidChangeListener(h) }
    }

    func reload(for uid: String?) async {
        isLoading = true
        defer { isLoading = false }

        guard let uid = uid else {
            currentUser = nil
            return
        }

        do {
            currentUser = try await UserService.shared.fetchUser(uid: uid)
        } catch {
            print("SessionStore.reload error:", error.localizedDescription)
            currentUser = nil
        }
    }

    var id: String? { currentUser?.id }
}
