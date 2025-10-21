import SwiftUI

struct HomeView: View {
    let currentUser: AppUser

    var body: some View {
        TabView {
            ThreadsListView(currentUser: currentUser)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            PeopleSearchView(currentUser: currentUser)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView(currentUser: currentUser)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
