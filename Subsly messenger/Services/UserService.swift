import Foundation
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
        
        // Ensure keys exist and get public key
        try? CryptoService.shared.ensureKeysExist()
        let publicKey = CryptoService.shared.getMyPublicKey()
        
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
        if let publicKey {
            payload["publicKey"] = publicKey
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
    
    // Helper to backfill keys for existing users
    func updateUserPublicKey(uid: String, key: String) async throws {
        try await db.collection("users").document(uid).setData([
            "publicKey": key,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
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
        let publicKey = data["publicKey"] as? String
        
        return await MainActor.run {
            AppUser(id: id,
                    handle: handle,
                    displayName: displayName,
                    avatarURL: avatarURL,
                    bio: bio,
                    createdAt: createdAt,
                    isOnline: isOnline,
                    shareOnlineStatus: shareOnlineStatus,
                    lastOnlineAt: lastOnlineAt,
                    publicKey: publicKey)
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
