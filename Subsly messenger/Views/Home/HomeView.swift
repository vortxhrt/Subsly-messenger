import SwiftUI

struct HomeView: View {
    let currentUser: AppUser
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ThreadsListView(currentUser: currentUser)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)

            PeopleSearchView(currentUser: currentUser)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

            SettingsView(currentUser: currentUser) {
                selectedTab = 0
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(2)
        }
    }
}
