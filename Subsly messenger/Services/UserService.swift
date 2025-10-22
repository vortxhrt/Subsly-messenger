import Foundation
import FirebaseAuth
import FirebaseFirestore

actor UserService {
    static let shared = UserService()
    private var db: Firestore { Firestore.firestore() }

    // Create or update profile on sign-up
    func createUserProfile(uid: String, handle: String, displayName: String) async throws {
        try await db.collection("users").document(uid).setData([
            "handle": handle,
            "handleLower": handle.lowercased(),
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    // Build AppUser on main actor (avoids MainActor initializer warnings)
    private func mapUser(id: String, data: [String: Any]) async -> AppUser {
        let handle = (data["handle"] as? String) ?? "user\(id.prefix(6))"
        let displayName = (data["displayName"] as? String) ?? handle
        return await MainActor.run {
            AppUser(id: id, handle: handle, displayName: displayName)
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

    // Name helper (used in list rows)
    func fetchUserName(uid: String) async throws -> String? {
        if let u = try await fetchUser(uid: uid) {
            return u.displayName.isEmpty ? u.handle : u.displayName
        }
        return nil
    }

    // Search by handleLower prefix
    func searchUsers(query: String) async throws -> [AppUser] {
        let q = query.lowercased()
        let snap = try await db.collection("users")
            .whereField("handleLower", isGreaterThanOrEqualTo: q)
            .whereField("handleLower", isLessThan: q + "\u{f8ff}")
            .limit(to: 20)
            .getDocuments()

        var list: [AppUser] = []
        for d in snap.documents {
            list.append(await mapUser(id: d.documentID, data: d.data()))
        }
        return list
    }

    // Save the current user's FCM token in their Firestore document
    func saveFCMToken(uid: String, token: String) async throws {
        try await db.collection("users").document(uid)
            .setData(["fcmToken": token], merge: true)
    }
}
