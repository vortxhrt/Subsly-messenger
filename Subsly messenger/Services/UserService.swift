import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import FirebaseAuth
import FirebaseFirestore

actor UserService {
    static let shared = UserService()
    private var db: Firestore { Firestore.firestore() }
    private let maxBioLength = 160

    // Create or update profile on sign-up
    func createUserProfile(uid: String,
                           handle: String,
                           displayName: String,
                           avatarURL: String? = nil,
                           bio: String? = nil) async throws {
        let sanitizedDisplayName = ProfileSanitizer.sanitizeDisplayName(displayName, fallback: handle)
        let sanitizedBio = ProfileSanitizer.sanitizeBio(bio)
        var payload: [String: Any] = [
            "handle": handle,
            "handleLower": handle.lowercased(),
            "displayName": sanitizedDisplayName,
            "createdAt": FieldValue.serverTimestamp(),
            "shareOnlineStatus": true,
            "isOnline": false
        ]
        if let avatarURL, !avatarURL.isEmpty {
            payload["avatarURL"] = avatarURL
        }
        if let sanitizedBio {
            payload["bio"] = sanitizedBio
        }
        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    func updateAvatarURL(uid: String, urlString: String?) async throws {
        var payload: [String: Any] = [
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let urlString, !urlString.isEmpty {
            payload["avatarURL"] = urlString
        } else {
            payload["avatarURL"] = FieldValue.delete()
        }
        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    // Build AppUser on main actor (avoids MainActor initializer warnings)
    private func mapUser(id: String, data: [String: Any]) async -> AppUser {
        let handle = (data["handle"] as? String) ?? "user\(id.prefix(6))"
        let displayNameRaw = (data["displayName"] as? String) ?? handle
        let displayName = ProfileSanitizer.sanitizeDisplayName(displayNameRaw, fallback: handle)
        let avatarURL = data["avatarURL"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        let bio = ProfileSanitizer.sanitizeBio(data["bio"] as? String, limit: maxBioLength)
        let isOnline = data["isOnline"] as? Bool ?? false
        let shareOnlineStatus = data["shareOnlineStatus"] as? Bool ?? true
        let lastOnlineAt = (data["lastOnlineAt"] as? Timestamp)?.dateValue()
        return await MainActor.run {
            AppUser(id: id,
                    handle: handle,
                    displayName: displayName,
                    avatarURL: avatarURL,
                    bio: bio,
                    createdAt: createdAt,
                    isOnline: isOnline,
                    shareOnlineStatus: shareOnlineStatus,
                    lastOnlineAt: lastOnlineAt)
        }
    }

    // Fetch by uid
    func fetchUser(uid: String) async throws -> AppUser? {
        let snap = try await db.collection("users").document(uid).getDocument()
        guard let data = snap.data() else { return nil }
        return await mapUser(id: snap.documentID, data: data)
    }

    func listenUser(uid: String, onChange: @escaping (AppUser?) -> Void) -> ListenerRegistration {
        db.collection("users").document(uid).addSnapshotListener { snapshot, error in
            guard error == nil else {
                onChange(nil)
                return
            }
            guard let snapshot, let data = snapshot.data() else {
                onChange(nil)
                return
            }
            Task {
                let user = await self.mapUser(id: snapshot.documentID, data: data)
                onChange(user)
            }
        }
    }

    // Current user for SessionStore
    func fetchCurrentUser() async throws -> AppUser? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return try await fetchUser(uid: uid)
    }

    // Overload used by some call sites
    func fetchCurrentUser(uid: String) async throws -> AppUser? {
        try await fetchUser(uid: uid)
    }

    // Save the current user's FCM token in their Firestore document
    func saveFCMToken(uid: String, token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tokenId = TokenHasher.hash(trimmed)
        try await db.collection("users")
            .document(uid)
            .collection("deviceTokens")
            .document(tokenId)
            .setData([
                "token": trimmed,
                "platform": "ios",
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    func removeFCMToken(uid: String, token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tokenId = TokenHasher.hash(trimmed)
        try await db.collection("users")
            .document(uid)
            .collection("deviceTokens")
            .document(tokenId)
            .delete()
    }

    func updateProfile(uid: String, displayName: String, bio: String?) async throws {
        let sanitizedName = ProfileSanitizer.sanitizeDisplayName(displayName, fallback: displayName)
        let sanitizedBio = ProfileSanitizer.sanitizeBio(bio)
        var payload: [String: Any] = [
            "displayName": sanitizedName,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let sanitizedBio {
            payload["bio"] = sanitizedBio
        } else {
            payload["bio"] = FieldValue.delete()
        }

        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    func setOnlineStatus(uid: String, isOnline: Bool) async throws {
        var payload: [String: Any] = [
            "isOnline": isOnline,
            "updatedAt": FieldValue.serverTimestamp(),
            "lastOnlineAt": FieldValue.serverTimestamp()
        ]
        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    func setShareOnlineStatus(uid: String, isEnabled: Bool) async throws {
        var payload: [String: Any] = [
            "shareOnlineStatus": isEnabled,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if !isEnabled {
            payload["isOnline"] = false
            payload["lastOnlineAt"] = FieldValue.serverTimestamp()
        }
        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    func handleExists(handleLower: String) async throws -> Bool {
        let snapshot = try await db.collection("users")
            .whereField("handleLower", isEqualTo: handleLower)
            .limit(to: 1)
            .getDocuments()
        return !snapshot.documents.isEmpty
    }
}

// MARK: - Helpers

enum ProfileSanitizer {
    static func sanitizeDisplayName(_ name: String, fallback: String) -> String {
        let filtered = filterControlCharacters(in: name, allowNewlines: false)
        let collapsed = collapseWhitespace(filtered)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(50))

        let fallbackCollapsed = collapseWhitespace(fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackValue = fallbackCollapsed.isEmpty ? "User" : fallbackCollapsed
        return capped.isEmpty ? String(fallbackValue.prefix(50)) : capped
    }

    static func sanitizeBio(_ bio: String?, limit: Int = 160) -> String? {
        guard let bio else { return nil }
        let filtered = filterControlCharacters(in: bio, allowNewlines: true)
        let normalizedNewlines = filtered
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let collapsedLines = normalizedNewlines
            .components(separatedBy: "\n")
            .map { collapseInlineWhitespace($0) }
        let cleaned = trimEmptyLines(from: collapsedLines).joined(separator: "\n")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func normalizeBioDraft(_ draft: String, limit: Int) -> String {
        let filtered = filterControlCharacters(in: draft, allowNewlines: true)
        if filtered.count <= limit { return filtered }
        let endIndex = filtered.index(filtered.startIndex, offsetBy: limit)
        return String(filtered[..<endIndex])
    }

    private static func filterControlCharacters(in string: String, allowNewlines: Bool) -> String {
        let newline = UnicodeScalar(10)
        let carriageReturn = UnicodeScalar(13)

        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(string.unicodeScalars.count)

        for scalar in string.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                if allowNewlines {
                    if scalar == newline {
                        scalars.append(scalar)
                    } else if scalar == carriageReturn {
                        scalars.append(newline)
                    }
                }
                continue
            }
            scalars.append(scalar)
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func collapseInlineWhitespace(_ line: String) -> String {
        line
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func trimEmptyLines(from lines: [String]) -> [String] {
        var result = lines
        while let first = result.first, first.isEmpty {
            result.removeFirst()
        }
        while let last = result.last, last.isEmpty {
            result.removeLast()
        }

        var collapsed: [String] = []
        var previousEmpty = false
        for line in result {
            if line.isEmpty {
                if previousEmpty { continue }
                previousEmpty = true
                collapsed.append("")
            } else {
                previousEmpty = false
                collapsed.append(line)
            }
        }
        return collapsed
    }
}

enum TokenHasher {
    static func hash(_ token: String) -> String {
        #if canImport(CryptoKit)
        let data = Data(token.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
        let prime: UInt64 = 0x100000001b3
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
        #endif
    }
}
