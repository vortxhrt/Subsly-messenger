import SwiftUI
import FirebaseCore

@main
struct SubslyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var session = SessionStore.shared
    @StateObject private var threadsStore = ThreadsStore.shared
    @StateObject private var usersStore = UsersStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environmentObject(session)
                .environmentObject(threadsStore)
                .environmentObject(usersStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                switch newPhase {
                case .active:
                    await session.setPresence(isOnline: true)
                case .inactive, .background:
                    await session.setPresence(isOnline: false)
                @unknown default:
                    break
                }
            }
        }
    }
}
