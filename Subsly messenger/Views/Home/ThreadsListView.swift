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

    var body: some View {
        NavigationLink {
            ThreadView(currentUser: currentUser, otherUID: otherId)
        } label: {
            HStack(spacing: 12) {
                Circle().frame(width: 36, height: 36).opacity(0.15)

                VStack(alignment: .leading, spacing: 2) {
                    Text(usersStore.name(for: otherId) ?? "User \(otherId.prefix(6))…")
                        .fontWeight(.semibold)

                    Text(previewText(thread.lastMessagePreview))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private func previewText(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No messages yet" : trimmed
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
