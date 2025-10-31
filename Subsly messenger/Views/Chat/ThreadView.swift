import SwiftUI
import FirebaseFirestore

struct ThreadView: View {
    let currentUser: AppUser
    let otherUID: String

    private let myId: String

    @State private var threadId: String?
    @State private var messages: [MessageModel] = []
    @State private var inputText: String = ""

    @State private var listener: ListenerRegistration?
    @State private var typingListener: ListenerRegistration?
    @State private var isOtherTyping: Bool = false

    // Tap-to-show timestamp & ticks (auto-hide via token)
    @State private var expandedMessageIDs: Set<String> = []
    @State private var expandTokens: [String: Int] = [:]
    private let autoHideAfter: TimeInterval = 2.0

    // Delivery/read receipt tracking (by messageId)
    @State private var deliveredByOther: Set<String> = []
    @State private var readByOther: Set<String> = []
    @State private var receiptListeners: [String: ListenerRegistration] = [:]

    // Pending (sending) for local-outgoing messages
    @State private var pendingOutgoingIDs: Set<String> = []

    @State private var isOpening = false

    init(currentUser: AppUser, otherUID: String) {
        self.currentUser = currentUser
        self.otherUID = otherUID
        self.myId = currentUser.id ?? ""
    }

    private var canSend: Bool {
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
                                isMe: msg.senderId == myId,
                                createdAt: msg.createdAt,
                                isExpanded: expandedMessageIDs.contains(msg.id),
                                status: statusForMessage(msg),
                                onTap: { handleTap(on: msg.id) }
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

                // Keep bottom pinned and wire receipts whenever messages change.
                .onChange(of: messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                    // Wire up receipts + mark my receipts for incoming
                    setupReceiptsIfNeeded()
                    markIncomingAsDelivered()
                    markIncomingAsRead()
                    // Clear pending IDs that no longer exist (server confirmed / replaced)
                    purgeStalePendingIDs()
                }
                .onChange(of: isOtherTyping) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)

            // Bottom bar (composer)
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
                .background(.ultraThinMaterial)
            }

            .task { await openThreadIfNeeded(proxy: proxy) }
            .onAppear {
                // Defensive first pass (in case messages already present)
                markIncomingAsDelivered()
                markIncomingAsRead()
                #if DEBUG
                print("ThreadView appear -> myId=\(myId) otherUID=\(otherUID) threadId=\(threadId ?? "nil")")
                #endif
            }
            .onDisappear {
                listener?.remove(); listener = nil
                typingListener?.remove(); typingListener = nil
                cleanupReceiptListeners()
                if let tid = threadId, !myId.isEmpty {
                    Task { try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false) }
                }
            }
        }
    }

    // MARK: - Status computation

    private func statusForMessage(_ msg: MessageModel) -> DeliveryState? {
        // Only for outgoing
        guard msg.senderId == myId else { return nil }

        if pendingOutgoingIDs.contains(msg.id) {
            return .pending
        }
        if readByOther.contains(msg.id) {
            return .read
        }
        if deliveredByOther.contains(msg.id) {
            return .delivered
        }
        return .sent
    }

    // MARK: - Receipts wiring

    private func setupReceiptsIfNeeded() {
        guard let tid = threadId else { return }
        // Attach a receipts listener for each outgoing message if not already attached.
        for msg in messages where msg.senderId == myId {
            if receiptListeners[msg.id] == nil {
                let l = ReceiptsService.shared.listenReceipts(threadId: tid, messageId: msg.id) { delivered, read in
                    Task { @MainActor in
                        if delivered.contains(self.otherUID) {
                            self.deliveredByOther.insert(msg.id)
                        }
                        if read.contains(self.otherUID) {
                            self.readByOther.insert(msg.id)
                        }
                    }
                }
                receiptListeners[msg.id] = l
            }
        }
    }

    private func cleanupReceiptListeners() {
        for (_, l) in receiptListeners { l.remove() }
        receiptListeners.removeAll()
    }

    /// Mark *incoming* messages as delivered and read (idempotent).
    private func markIncomingAsDelivered() {
        guard let tid = threadId else { return }
        let incoming = messages.filter { $0.senderId != myId }
        guard !incoming.isEmpty else { return }
        for msg in incoming {
            #if DEBUG
            print("MARK DELIVERED tid=\(tid) msg=\(msg.id) to=\(myId)")
            #endif
            Task { await ReceiptsService.shared.markDelivered(threadId: tid, messageId: msg.id, to: myId) }
        }
    }

    private func markIncomingAsRead() {
        guard let tid = threadId else { return }
        let incoming = messages.filter { $0.senderId != myId }
        guard !incoming.isEmpty else { return }
        for msg in incoming {
            #if DEBUG
            print("MARK READ tid=\(tid) msg=\(msg.id) by=\(myId)")
            #endif
            Task { await ReceiptsService.shared.markRead(threadId: tid, messageId: msg.id, by: myId) }
        }
    }

    // MARK: - Tap-to-show timestamp & ticks (auto-hide)

    private func handleTap(on id: String) {
        if expandedMessageIDs.contains(id) {
            // Collapse immediately if already visible
            expandedMessageIDs.remove(id)
            expandTokens[id] = nil
        } else {
            showTemporarily(id)
        }
    }

    private func showTemporarily(_ id: String) {
        let next = (expandTokens[id] ?? 0) + 1
        expandTokens[id] = next
        expandedMessageIDs.insert(id)

        let token = next
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter) {
            if expandTokens[id] == token {
                expandedMessageIDs.remove(id)
                expandTokens[id] = nil
            }
        }
    }

    // MARK: - Sending

    private func send() {
        guard let tid = threadId else { return }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Create a local outgoing message with a unique id and mark as pending.
        let localId = "local-" + UUID().uuidString
        let local = MessageModel(
            id: localId,
            senderId: myId,
            text: trimmed,
            createdAt: Date()
        )
        pendingOutgoingIDs.insert(localId)
        messages.append(local)
        inputText = ""

        // Fire off the real send; when it completes, clear pending for that local id.
        Task {
            try? await ChatService.shared.sendMessage(threadId: tid, from: myId, text: trimmed)
            await MainActor.run {
                pendingOutgoingIDs.remove(localId)
            }
            // The server snapshot will replace the local bubble.
        }

        // Stop typing state
        Task {
            try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false)
        }
    }

    /// Remove pending IDs that no longer exist in the list (server confirmation replaced local message).
    private func purgeStalePendingIDs() {
        let present = Set(messages.map { $0.id })
        pendingOutgoingIDs = pendingOutgoingIDs.intersection(present)
    }

    // MARK: - Thread bootstrap + listeners

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
                #if DEBUG
                print("Opened threadId=\(tid) as myId=\(myId) with otherUID=\(otherUID)")
                #endif
            }
        }
    }

    private func startListening(threadId: String, proxy: ScrollViewProxy) {
        listener?.remove()
        listener = ChatService.shared.listenMessages(threadId: threadId) { list in
            Task { @MainActor in
                self.messages = list
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
                // On every refresh, wire receipts + clean pending.
                self.setupReceiptsIfNeeded()
                self.markIncomingAsDelivered()
                self.markIncomingAsRead()
                self.purgeStalePendingIDs()
                #if DEBUG
                print("Messages updated (\(list.count)) for thread=\(threadId)")
                #endif
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
