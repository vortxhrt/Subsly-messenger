import SwiftUI

struct UserProfileView: View {
    @EnvironmentObject private var usersStore: UsersStore
    let userId: String

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let profile = profile {
                    AvatarView(avatarURL: profile.avatarURL,
                               name: profileDisplayName,
                               size: 120,
                               showPresenceIndicator: true,
                               isOnline: profile.isVisiblyOnline)
                        .padding(.top, 24)

                    VStack(spacing: 4) {
                        Text(profileDisplayName)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("@\(profile.handle)")
                            .foregroundStyle(.secondary)
                        Text(statusLine(for: profile))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bio")
                            .font(.headline)

                        if let bio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                            Text(bio)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("This user hasn't added a bio yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                    Spacer(minLength: 0)
                } else {
                    ProgressView()
                        .padding(.top, 64)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(profileDisplayName.isEmpty ? "Profile" : profileDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await usersStore.ensure(uid: userId) }
    }

    private var profile: AppUser? {
        usersStore.user(for: userId)
    }

    private var profileDisplayName: String {
        if let profile {
            let trimmed = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? profile.handle : trimmed
        }
        return "User \(userId.prefix(6))"
    }

    private func statusLine(for user: AppUser) -> String {
        if user.isStatusHidden { return "Offline" }
        if user.isVisiblyOnline { return "Online" }
        if let lastSeen = formattedLastSeen(for: user) {
            return "Last seen \(lastSeen)"
        }
        return "Offline"
    }

    private func formattedLastSeen(for user: AppUser) -> String? {
        guard let description = user.lastSeenDescription() else { return nil }
        let normalized = description.lowercased()
        if normalized.contains("0 seconds") {
            return "just now"
        }
        return description
    }
}

#Preview {
    let store = UsersStore()
    let sample = AppUser(id: "demo", handle: "demoUser", displayName: "Demo User", avatarURL: nil, bio: "Building the next big thing.")
    store.upsert(sample)
    return NavigationStack {
        UserProfileView(userId: "demo")
            .environmentObject(store)
    }
}
