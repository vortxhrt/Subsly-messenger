import Foundation
import FirebaseAuth
import FirebaseFirestore

actor UserService {
    static let shared = UserService()
    private var db: Firestore { Firestore.firestore() }

    // Create or update profile on sign-up
    func createUserProfile(uid: String,
                           handle: String,
                           displayName: String,
                           avatarURL: String? = nil,
                           bio: String? = nil) async throws {
        var payload: [String: Any] = [
            "handle": handle,
            "handleLower": handle.lowercased(),
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp(),
            "isOnline": false,
            "isStatusHidden": false,
            "lastActiveAt": FieldValue.serverTimestamp()
        ]
        if let avatarURL, !avatarURL.isEmpty {
            payload["avatarURL"] = avatarURL
        }
        if let bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["bio"] = bio
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

    func updatePresence(uid: String, isOnline: Bool, recordLastActive: Bool) async throws {
        var payload: [String: Any] = [
            "isOnline": isOnline,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if recordLastActive {
            payload["lastActiveAt"] = FieldValue.serverTimestamp()
        }
        try await db.collection("users").document(uid).setData(payload, merge: true)
    }

    func updateStatusVisibility(uid: String, isHidden: Bool) async throws {
        try await db.collection("users").document(uid).setData([
            "isStatusHidden": isHidden,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    nonisolated func listenUser(uid: String, onChange: @escaping @Sendable (AppUser?) -> Void) -> ListenerRegistration {
        let reference = Firestore.firestore().collection("users").document(uid)
        return reference.addSnapshotListener { snapshot, error in
            if let error = error {
                print("listenUser error:", error.localizedDescription)
            }
            guard let snapshot, let data = snapshot.data() else {
                Task { @MainActor in onChange(nil) }
                return
            }
            Task {
                let user = await UserService.shared.mapUser(id: snapshot.documentID, data: data)
                await MainActor.run {
                    onChange(user)
                }
            }
        }
    }

    // Build AppUser on main actor (avoids MainActor initializer warnings)
    private func mapUser(id: String, data: [String: Any]) async -> AppUser {
        let handle = (data["handle"] as? String) ?? "user\(id.prefix(6))"
        let displayName = (data["displayName"] as? String) ?? handle
        let avatarURL = data["avatarURL"] as? String
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        let bio = data["bio"] as? String
        let isOnline = data["isOnline"] as? Bool ?? false
        let lastActive = (data["lastActiveAt"] as? Timestamp)?.dateValue()
        let isStatusHidden = data["isStatusHidden"] as? Bool ?? false
        return await MainActor.run {
            AppUser(id: id,
                    handle: handle,
                    displayName: displayName,
                    avatarURL: avatarURL,
                    bio: bio,
                    createdAt: createdAt,
                    isOnline: isOnline,
                    lastActiveAt: lastActive,
                    isStatusHidden: isStatusHidden)
        }
    }

    // Fetch by uid
    func fetchUser(uid: String) async throws -> AppUser? {
        let snap = try await db.collection("users").document(uid).getDocument()
        guard let data = snap.data() else { return nil }
        return await mapUser(id: snap.documentID, data: data)
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
        try await db.collection("users").document(uid)
            .setData(["fcmToken": token], merge: true)
    }

    func updateProfile(uid: String, displayName: String, bio: String?) async throws {
        var payload: [String: Any] = [
            "displayName": displayName,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["bio"] = bio
        } else {
            payload["bio"] = FieldValue.delete()
        }

        try await db.collection("users").document(uid).setData(payload, merge: true)
    }
}
