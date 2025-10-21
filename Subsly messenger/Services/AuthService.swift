import Foundation
import FirebaseAuth

actor AuthService {
    static let shared = AuthService()

    func signIn(email: String, password: String) async throws {
        _ = try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        // Create a simple profile on first sign-up
        let uid = result.user.uid
        let handle = email.split(separator: "@").first.map(String.init) ?? "user\(Int.random(in: 1000...9999))"
        try await UserService.shared.createUserProfile(uid: uid, handle: handle, displayName: handle)
    }

    // Make this callable without awaiting the actor (safe: no actor state)
    nonisolated func signOut() throws {
        try Auth.auth().signOut()
    }
}
