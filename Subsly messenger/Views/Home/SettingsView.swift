import SwiftUI

struct SettingsView: View {
    let currentUser: AppUser

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Button(role: .destructive) {
                        // nonisolated signOut() lets us call directly
                        do { try AuthService.shared.signOut() } catch { print("Sign out failed:", error) }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
