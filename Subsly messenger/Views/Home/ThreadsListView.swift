import SwiftUI

struct ThreadsListView: View {
    @EnvironmentObject var threadsStore: ThreadsStore
    @EnvironmentObject var usersStore: UsersStore
    let currentUser: AppUser
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                if threadsStore.pinnedThreads.isEmpty && threadsStore.unpinnedThreads.isEmpty {
                    Section {
                        Text("No conversations yet. Find someone in **Search** to start chatting.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !threadsStore.pinnedThreads.isEmpty {
                        Section("Pinned") {
                            ForEach(threadsStore.pinnedThreads) { thread in
                                if let otherId = otherParticipant(in: thread) {
                                    ThreadRow(
                                        otherId: otherId,
                                        currentUser: currentUser,
                                        thread: thread,
                                        isPinned: true,
                                        canPin: true,
                                        onTogglePin: { threadsStore.togglePin(thread) },
                                        onDelete: { threadsStore.softDelete(thread) }
                                    )
                                    .task { await usersStore.ensure(uid: otherId) }
                                }
                            }
                            .onMove { indices, newOffset in
                                threadsStore.movePinned(from: indices, to: newOffset)
                            }
                        }
                    }

                    if !threadsStore.unpinnedThreads.isEmpty {
                        Section("Chats") {
                            ForEach(threadsStore.unpinnedThreads) { thread in
                                if let otherId = otherParticipant(in: thread) {
                                    ThreadRow(
                                        otherId: otherId,
                                        currentUser: currentUser,
                                        thread: thread,
                                        isPinned: false,
                                        canPin: threadsStore.canPin(thread),
                                        onTogglePin: { threadsStore.togglePin(thread) },
                                        onDelete: { threadsStore.softDelete(thread) }
                                    )
                                    .task { await usersStore.ensure(uid: otherId) }
                                }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Your Chats")
            .toolbar {
                if threadsStore.pinnedThreads.count > 1 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }

    private func otherParticipant(in thread: ThreadModel) -> String? {
        let currentId = currentUser.id ?? ""
        return thread.members.first { $0 != currentId }
    }
}

private struct ThreadRow: View {
    @EnvironmentObject var usersStore: UsersStore
    let otherId: String
    let currentUser: AppUser
    let thread: ThreadModel
    let isPinned: Bool
    let canPin: Bool
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

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

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                        .accessibilityLabel("Pinned chat")
                }
            }
        }
        .contextMenu {
            Button(action: onTogglePin) {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
            .disabled(!isPinned && !canPin)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can start a new conversation later, but this will hide the current chat history for you.")
        }
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
