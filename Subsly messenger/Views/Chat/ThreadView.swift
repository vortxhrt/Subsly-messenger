import SwiftUI
import FirebaseFirestore

struct ThreadView: View {
    // Inputs
    let currentUser: AppUser
    let otherUID: String

    // Make myId a concrete String once; no more optional warnings
    private let myId: String

    @State private var threadId: String?
    @State private var messages: [MessageModel] = []
    @State private var inputText: String = ""
    @State private var listener: ListenerRegistration?
    @State private var isOpening = false

    // MARK: - Init
    init(currentUser: AppUser, otherUID: String) {
        self.currentUser = currentUser
        self.otherUID = otherUID
        self.myId = currentUser.id ?? ""
    }

    private var canSend: Bool {
        guard threadId != nil, !myId.isEmpty else { return false }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - UI
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages, id: \.id) { msg in
                            MessageBubbleView(text: msg.text, isMe: msg.senderId == myId)
                        }
                        Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(text: $inputText) { send() }
            }
            .task { await openThreadIfNeeded(proxy: proxy) }
            .onDisappear { listener?.remove(); listener = nil }
        }
    }

    // MARK: - Actions

    private func send() {
        guard canSend, let tid = threadId else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // optimistic UI
        let local = MessageModel(id: UUID().uuidString,
                                 senderId: myId,
                                 text: trimmed,
                                 createdAt: Date())
        messages.append(local)
        inputText = ""

        Task {
            try? await ChatService.shared.sendMessage(threadId: tid, from: myId, text: trimmed)
        }
    }

    private func openThreadIfNeeded(proxy: ScrollViewProxy) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard !myId.isEmpty else { return }

        if let t = try? await ChatService.shared.ensureThread(currentUID: myId, otherUID: otherUID) {
            // t.id is optional in your model — unwrap safely
            guard let tid = t.id, !tid.isEmpty else { return }
            await MainActor.run {
                self.threadId = tid
                startListening(threadId: tid, proxy: proxy)
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
}
