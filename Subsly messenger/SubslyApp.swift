import SwiftUI
import Combine
import FirebaseCore

@main
struct SubslyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session = SessionStore.shared
    @StateObject private var threadsStore = ThreadsStore.shared
    @StateObject private var usersStore = UsersStore()

    private var userIdPublisher: AnyPublisher<String?, Never> {
        session.$currentUser
            .map { $0?.id }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private var visibilityPublisher: AnyPublisher<Bool, Never> {
        session.$currentUser
            .map { $0?.isStatusHidden ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .environmentObject(session)
                .environmentObject(threadsStore)
                .environmentObject(usersStore)
                .onChange(of: scenePhase) { newPhase in
                    Task { await updatePresence(for: newPhase) }
                }
                .onReceive(userIdPublisher) { _ in
                    Task { await updatePresence(for: scenePhase) }
                }
                .onReceive(visibilityPublisher) { _ in
                    Task { await updatePresence(for: scenePhase) }
                }
                .task {
                    await updatePresence(for: scenePhase)
                }
        }
    }

    private func updatePresence(for phase: ScenePhase) async {
        guard let uid = session.currentUser?.id else { return }
        let isHidden = session.currentUser?.isStatusHidden ?? false
        let isActive = phase == .active
        let shouldRecordLastActive = phase != .active

        do {
            try await UserService.shared.updatePresence(uid: uid,
                                                        isOnline: isHidden ? false : isActive,
                                                        recordLastActive: shouldRecordLastActive)
            await MainActor.run {
                if var current = session.currentUser {
                    current.isOnline = isHidden ? false : isActive
                    if shouldRecordLastActive {
                        current.lastActiveAt = Date()
                    }
                    session.currentUser = current
                    if current.id != nil {
                        usersStore.upsert(current)
                    }
                }
            }
        } catch {
            #if DEBUG
            print("Presence update failed:", error.localizedDescription)
            #endif
        }
    }
}
