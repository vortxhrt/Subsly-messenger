import Foundation
import FirebaseAuth

enum AuthServiceError: LocalizedError {
    case missingAuthenticatedUser

    var errorDescription: String? {
        switch self {
        case .missingAuthenticatedUser:
            return "No authenticated user is available for this operation."
        }
    }
}

actor AuthService {
    static let shared = AuthService()

    func signIn(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Auth.auth().signIn(withEmail: trimmedEmail, password: password)
    }

    func signUp(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Auth.auth().createUser(withEmail: trimmedEmail, password: password)
        let uid = result.user.uid

        let handle = try await generateUniqueHandle(for: uid)

        do {
            try await UserService.shared.createUserProfile(
                uid: uid,
                handle: handle,
                displayName: handle
            )
        } catch {
            // Roll back partially-created accounts to avoid unusable records.
            try? await result.user.delete()
            throw error
        }

        do {
            try await result.user.sendEmailVerification()
            await MainActor.run {
                SessionStore.shared.recordVerificationEmailSent()
            }
        } catch {
            // Still allow the account to exist even if the email could not be sent immediately.
            #if DEBUG
            print("Verification email dispatch failed: \(error.localizedDescription)")
            #endif
        }
    }

    func sendVerificationEmail() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.missingAuthenticatedUser
        }

        try await user.sendEmailVerification()
        await MainActor.run {
            SessionStore.shared.recordVerificationEmailSent()
        }
    }

    func reloadCurrentUser() async throws {
        guard let user = Auth.auth().currentUser else { return }
        try await user.reload()
    }

    func signOut() async throws {
        if let uid = Auth.auth().currentUser?.uid {
            do {
                try await UserService.shared.clearFCMToken(uid: uid)
            } catch {
                print("Clearing push token on sign-out failed.")
            }
            PushNotificationManager.shared.clearCachedToken()
        }

        try Auth.auth().signOut()
    }

    // MARK: - Helpers

    private func generateUniqueHandle(for uid: String) async throws -> String {
        let base = "user" + uid.prefix(6)
        var candidate = String(base)

        let maxAttempts = 25
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                let suffix = Int.random(in: 1000...9999)
                candidate = base + String(suffix)
            }

            let lower = candidate.lowercased()
            let exists = try await UserService.shared.handleExists(handleLower: lower)
            if !exists {
                return candidate
            }
        }

        // Fallback in the extremely unlikely case of exhausting the pool.
        return base + String(UUID().uuidString.prefix(4))
    }
}
