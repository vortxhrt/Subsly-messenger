import SwiftUI

enum HomeTab: Hashable {
    case chats
    case search
    case settings
}

struct HomeView: View {
    let currentUser: AppUser
    @State private var selectedTab: HomeTab = .chats

    var body: some View {
        TabView(selection: $selectedTab) {
            ThreadsListView(currentUser: currentUser)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(HomeTab.chats)

            PeopleSearchView(currentUser: currentUser)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(HomeTab.search)

            SettingsView(currentUser: currentUser) {
                selectedTab = .chats
            }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(HomeTab.settings)
        }
    }
}
