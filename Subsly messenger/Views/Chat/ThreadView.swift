import SwiftUI
import FirebaseFirestore

struct ThreadView: View {
    // Inputs
    let currentUser: AppUser
    let otherUID: String

    private let myId: String

    @State private var threadId: String?
    @State private var messages: [MessageModel] = []
    @State private var inputText: String = ""

    @State private var listener: ListenerRegistration?
    @State private var typingListener: ListenerRegistration?
    @State private var isOtherTyping: Bool = false

    @State private var isOpening = false

    init(currentUser: AppUser, otherUID: String) {
        self.currentUser = currentUser
        self.otherUID = otherUID
        self.myId = currentUser.id ?? ""
    }

    private var canSend: Bool {
        guard threadId != nil, !myId.isEmpty else { return false }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages, id: \.id) { msg in
                            MessageBubbleView(
                                text: msg.text,
                                isMe: msg.senderId == myId
                            )
                        }

                        if isOtherTyping {
                            TypingIndicatorView()
                        }

                        Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                    }
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemGroupedBackground))
                .onChange(of: messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
                .onChange(of: isOtherTyping) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)

            // Bottom bar: background handled OUTSIDE the composer so nothing shifts.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider().opacity(0.08)
                    ComposerView(
                        text: $inputText,
                        onSend: send,
                        onTyping: { typing in
                            guard let tid = threadId, !myId.isEmpty else { return }
                            Task {
                                try? await TypingService.shared.setTyping(
                                    threadId: tid,
                                    userId: myId,
                                    isTyping: typing
                                )
                            }
                        }
                    )
                }
                .background(.ultraThinMaterial) // full-width bar, composer keeps side gaps
            }

            .task { await openThreadIfNeeded(proxy: proxy) }
            .onDisappear {
                listener?.remove(); listener = nil
                typingListener?.remove(); typingListener = nil
                if let tid = threadId, !myId.isEmpty {
                    Task { try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false) }
                }
            }
        }
    }

    // MARK: - Actions

    private func send() {
        guard canSend, let tid = threadId else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let local = MessageModel(
            id: UUID().uuidString,
            senderId: myId,
            text: trimmed,
            createdAt: Date()
        )
        messages.append(local)
        inputText = ""

        Task {
            try? await ChatService.shared.sendMessage(threadId: tid, from: myId, text: trimmed)
            try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false)
        }
    }

    private func openThreadIfNeeded(proxy: ScrollViewProxy) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard !myId.isEmpty else { return }

        if let t = try? await ChatService.shared.ensureThread(currentUID: myId, otherUID: otherUID),
           let tid = t.id, !tid.isEmpty {
            await MainActor.run {
                self.threadId = tid
                startListening(threadId: tid, proxy: proxy)
                startTypingListener(threadId: tid)
            }
        }
    }

    private func startListening(threadId: String, proxy: ScrollViewProxy) {
        listener?.remove()
        listener = ChatService.shared.listenMessages(threadId: threadId, limit: 100) { models in
            Task { @MainActor in
                self.messages = models
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }
        }
    }

    private func startTypingListener(threadId: String) {
        typingListener?.remove()
        typingListener = TypingService.shared.listenOtherTyping(
            threadId: threadId,
            otherUserId: otherUID
        ) { isTyping in
            Task { @MainActor in
                self.isOtherTyping = isTyping
            }
        }
    }
}
