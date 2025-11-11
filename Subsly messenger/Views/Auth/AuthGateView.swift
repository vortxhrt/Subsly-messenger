import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var threadsStore: ThreadsStore

    var body: some View {
        Group {
            if session.isLoading {
                ProgressView("Loading…")
            } else if let email = session.pendingEmailVerification {
                EmailVerificationView(email: email)
            } else if let user = session.currentUser, let uid = user.id {
                HomeView(currentUser: user)
                    .onAppear {
                        threadsStore.start(uid: uid)
                        Task { await session.setPresence(isOnline: true) }
                    }
                    .onDisappear {
                        threadsStore.stop()
                    }
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isLoading)
        .animation(.easeInOut(duration: 0.25), value: session.currentUser?.id)
        .onChange(of: session.currentUser?.id) { _, newId in
            guard newId != nil else { return }
            Task { await session.setPresence(isOnline: true) }
        }
    }
}
