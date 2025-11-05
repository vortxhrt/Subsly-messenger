import SwiftUI

struct ThreadsListView: View {
    @EnvironmentObject var threadsStore: ThreadsStore
    @EnvironmentObject var usersStore: UsersStore
    let currentUser: AppUser

    var body: some View {
        NavigationStack {
            List {
                if threadsStore.threads.isEmpty {
                    Section {
                        Text("No conversations yet. Find someone in **Search** to start chatting.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(threadsStore.threads) { thread in
                        if let otherId = thread.members.first(where: { $0 != (currentUser.id ?? "") }) {
                            ThreadRow(otherId: otherId,
                                      currentUser: currentUser,
                                      thread: thread)
                                .task { await usersStore.ensure(uid: otherId) }
                        }
                    }
                }
            }
            .navigationTitle("Your Chats")
        }
    }
}

private struct ThreadRow: View {
    @EnvironmentObject var usersStore: UsersStore
    let otherId: String
    let currentUser: AppUser
    let thread: ThreadModel

    private var otherUser: AppUser? { usersStore.user(for: otherId) }

    private var otherName: String {
        if let user = otherUser {
            let preferred = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return preferred.isEmpty ? "@\(user.handle)" : preferred
        }
        return "User \(otherId.prefix(6))"
    }

    private var avatarLabel: String {
        if let user = otherUser {
            let preferred = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return preferred.isEmpty ? user.handle : preferred
        }
        return "User \(otherId.prefix(6))"
    }

    var body: some View {
        NavigationLink {
            ThreadView(currentUser: currentUser, otherUID: otherId)
        } label: {
            HStack(spacing: 12) {
                AvatarView(avatarURL: otherUser?.avatarURL,
                           name: avatarLabel,
                           size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(otherName)
                        .fontWeight(.semibold)

                    // Live preview: typing or last message text
                    ThreadPreviewText(
                        thread: thread,
                        otherUserId: otherId,
                        currentUserId: currentUser.id ?? ""
                    )
                }

                Spacer()

                if let updated = thread.updatedAt {
                    Text(Self.relative(updated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
