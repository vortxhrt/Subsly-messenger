import Foundation
import SwiftUI
import Combine
import FirebaseAuth

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    // Indicates whether the session is currently loading
    @Published var isLoading: Bool = true
    // Holds the current user object (nil while signed out)
    @Published var currentUser: AppUser?

    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {
        // Observe Firebase Auth state changes
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { await self?.reload(for: user?.uid) }
        }
    }

    deinit {
        // Clean up the auth state listener
        if let h = authHandle {
            Auth.auth().removeStateDidChangeListener(h)
        }
    }

    /// Reloads the session for a given user ID.  If `uid` is nil, clears the current user.
    func reload(for uid: String?) async {
        isLoading = true
        defer { isLoading = false }

        if uid == nil, let previousId = currentUser?.id {
            do {
                try await UserService.shared.setOnlineStatus(uid: previousId, isOnline: false)
            } catch {
                print("SessionStore.reload offline update error:", error.localizedDescription)
            }
        }

        guard let uid = uid else {
            currentUser = nil
            return
        }

        do {
            // Fetch the user from Firestore
            currentUser = try await UserService.shared.fetchUser(uid: uid)
            // Save any pending FCM token once user is loaded
            PushNotificationManager.shared.savePendingToken(for: uid)
        } catch {
            print("SessionStore.reload error:", error.localizedDescription)
            currentUser = nil
        }
    }

    /// Convenience getter for the current user's ID
    var id: String? { currentUser?.id }

    /// Updates the current user's presence state if sharing is enabled.
    func setPresence(isOnline: Bool) async {
        guard var user = currentUser, let uid = user.id else { return }
        let effectiveStatus = user.shareOnlineStatus && isOnline
        if user.isOnline == effectiveStatus { return }

        do {
            try await UserService.shared.setOnlineStatus(uid: uid, isOnline: effectiveStatus)
            user.isOnline = effectiveStatus
            user.lastOnlineAt = Date()
            currentUser = user
        } catch {
            print("SessionStore.setPresence error:", error.localizedDescription)
        }
    }
}
