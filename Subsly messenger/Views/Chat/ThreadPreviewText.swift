import SwiftUI
import FirebaseFirestore

/// Displays either the last message preview for a thread
/// or a live typing indicator if the other user is currently typing.
struct ThreadPreviewText: View {
    /// The thread whose preview should be displayed.
    let thread: ThreadModel
    /// The UID of the other participant in the thread.
    let otherUserId: String
    /// The UID of the current user. Used to compute the deterministic thread ID if needed.
    let currentUserId: String

    @State private var isOtherTyping = false
    @State private var typingListener: ListenerRegistration?

    var body: some View {
        Group {
            if isOtherTyping {
                // Show a typing indication rather than the last message
                HStack(spacing: 4) {
                    TypingIndicatorDots()
                    Text("Typing…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(previewText(thread.lastMessagePreview))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .onAppear {
            // Only attach the listener once
            if typingListener == nil {
                attachListener()
            }
        }
        .onDisappear {
            // Remove listener when the row leaves the list
            typingListener?.remove()
            typingListener = nil
        }
    }

    /// Subscribes to the other participant’s typing state in Firestore.
    private func attachListener() {
        // Determine the thread ID. If the model already has an ID use it;
        // otherwise compute it using the deterministic thread ID helper.
        let tid = thread.id ?? ChatService.shared.threadId(for: currentUserId, otherUserId)
        typingListener = TypingService.shared.listenOtherTyping(
            threadId: tid,
            otherUserId: otherUserId
        ) { typing in
            // Update UI on the main thread
            Task { @MainActor in
                isOtherTyping = typing
            }
        }
    }

    /// Returns a nicely formatted preview string. Falls back to a default when empty.
    private func previewText(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No messages yet" : trimmed
    }
}

/// A lightweight version of the in-chat typing dots animation.
/// Because the main in-chat TypingIndicatorView is full-width and left-aligned,
/// this adaptation keeps the same animation but without forcing a bubble background.
private struct TypingIndicatorDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(animate ? 1.0 : 0.35)
                    .scaleEffect(animate ? 1.0 : 0.75)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
