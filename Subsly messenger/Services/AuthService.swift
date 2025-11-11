// Subsly messenger/Services/AuthService.swift
import Foundation
import FirebaseAuth
import FirebaseMessaging

enum AuthServiceError: LocalizedError {
    case missingAuthenticatedUser
    case invalidEmail

    var errorDescription: String? {
        switch self {
        case .missingAuthenticatedUser:
            return "No authenticated user is available for this operation."
        case .invalidEmail:
            return "The provided email address is invalid."
        }
    }
}

actor AuthService {
    static let shared = AuthService()

    func signIn(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailValidator.isValid(trimmedEmail) else {
            throw AuthServiceError.invalidEmail
        }
        _ = try await Auth.auth().signIn(withEmail: trimmedEmail, password: password)
    }

    func signUp(email: String, password: String) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailValidator.isValid(trimmedEmail) else {
            throw AuthServiceError.invalidEmail
        }
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
                if let token = Messaging.messaging().fcmToken {
                    try await UserService.shared.removeFCMToken(uid: uid, token: token)
                }
            } catch {
                print("Clearing push token on sign-out failed.")
            }
            await PushNotificationManager.shared.clearCachedToken()
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

// MARK: - Helpers

enum EmailValidator {
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func isValid(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 254 else { return false }
        guard let detector else { return false }

        let nsRange = NSRange(location: 0, length: trimmed.utf16.count)
        let matches = detector.matches(in: trimmed, options: [], range: nsRange)
        guard matches.count == 1, let result = matches.first else { return false }
        guard result.range == nsRange, result.url?.scheme == "mailto" else { return false }
        return true
    }
}
