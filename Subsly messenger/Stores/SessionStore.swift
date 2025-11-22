import Foundation
import SwiftUI
import Combine
import FirebaseAuth

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var isLoading: Bool = true
    @Published var currentUser: AppUser?
    @Published var pendingEmailVerification: String?
    @Published private(set) var lastVerificationEmailSentAt: Date?

    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { await self?.reload(for: user?.uid) }
        }
    }

    deinit {
        if let h = authHandle {
            Auth.auth().removeStateDidChangeListener(h)
        }
    }

    func reload(for uid: String?) async {
        isLoading = true
        defer { isLoading = false }
        pendingEmailVerification = nil

        if uid == nil, let previousId = currentUser?.id {
            do {
                try await UserService.shared.setOnlineStatus(uid: previousId, isOnline: false)
            } catch {
                #if DEBUG
                print("SessionStore.reload offline update error:", error.localizedDescription)
                #endif
            }
        }

        guard let uid = uid else {
            currentUser = nil
            return
        }

        do {
            if let authUser = Auth.auth().currentUser {
                try await authUser.reload()
                if !authUser.isEmailVerified {
                    pendingEmailVerification = authUser.email ?? ""
                    currentUser = nil
                    return
                }
            }
            
            // 1. Ensure local keys exist (Simulator or Device)
            try? CryptoService.shared.ensureKeysExist()
            let localPublicKey = CryptoService.shared.getMyPublicKey()
            
            // 2. Fetch the user from Firestore
            var fetchedUser = try await UserService.shared.fetchUser(uid: uid)
            
            // 3. CRITICAL FIX: Sync Key if Missing OR Different
            // If the key on the server doesn't match the key on this device (e.g. after .v2 update),
            // we must overwrite the server with the new key.
            if let myKey = localPublicKey {
                if fetchedUser?.publicKey != myKey {
                    try? await UserService.shared.updateUserPublicKey(uid: uid, key: myKey)
                    fetchedUser?.publicKey = myKey // Update local model immediately
                    print("Security: Public Key updated on server to match device.")
                }
            }
            
            currentUser = fetchedUser
            PushNotificationManager.shared.savePendingToken(for: uid)
        } catch {
            #if DEBUG
            print("SessionStore.reload error:", error.localizedDescription)
            #endif
            currentUser = nil
        }
    }

    var id: String? { currentUser?.id }

    var canResendVerificationEmail: Bool {
        guard let last = lastVerificationEmailSentAt else { return true }
        return Date().timeIntervalSince(last) >= 60
    }

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
            #if DEBUG
            print("SessionStore.setPresence error:", error.localizedDescription)
            #endif
        }
    }

    func recordVerificationEmailSent(at date: Date = Date()) {
        lastVerificationEmailSentAt = date
    }

    func refreshAuthUser() async {
        let uid = Auth.auth().currentUser?.uid
        await reload(for: uid)
    }
}
