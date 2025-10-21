import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var threadsStore: ThreadsStore

    var body: some View {
        Group {
            if session.isLoading {
                ProgressView("Loading…")
            } else if let user = session.currentUser, let uid = user.id {
                HomeView(currentUser: user)
                    .onAppear { threadsStore.start(uid: uid) }
                    .onDisappear { threadsStore.stop() }
            } else {
                LoginView()
            }
        }
        .animation(.smooth, value: session.isLoading)
        .animation(.smooth, value: session.currentUser?.id)
    }
}
