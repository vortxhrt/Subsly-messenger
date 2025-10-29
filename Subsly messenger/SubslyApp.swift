import SwiftUI
import FirebaseCore

@main
struct SubslyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var session = SessionStore.shared
    @StateObject private var threadsStore = ThreadsStore.shared
    @StateObject private var usersStore = UsersStore()

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environmentObject(session)
                .environmentObject(threadsStore)
                .environmentObject(usersStore)
        }
    }
}
