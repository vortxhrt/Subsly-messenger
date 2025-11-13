import Foundation
import SwiftUI
import FirebaseFirestore

struct ThreadView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var threadsStore: ThreadsStore
    @EnvironmentObject private var usersStore: UsersStore
    @Environment(\.dismiss) private var dismiss
    let currentUser: AppUser
    let otherUID: String

    @State private var myId: String

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
    @State private var loggedVoiceNoteIDs: Set<String> = []

    @State private var isOpening = false
    @State private var messageLimit: Int = 20
    private let pageSize: Int = 20
    @State private var hasMoreHistory: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var restoreScrollToId: String?
    @State private var hasPerformedInitialScroll = false
    @State private var showingProfile = false

    private let bottomContentPadding: CGFloat = 80

    init(currentUser: AppUser, otherUID: String) {
        self.currentUser = currentUser
        self.otherUID = otherUID
        _myId = State(initialValue: currentUser.id ?? "")
    }

    private var canSend: Bool {
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if hasMoreHistory {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    if hasPerformedInitialScroll && !isLoadingMore {
                                        loadMoreHistory()
                                    }
                                }
                        }

                        if hasMoreHistory && isLoadingMore {
                            ProgressView()
                                .scaleEffect(0.85)
                                .padding(.bottom, 6)
                        }

                        ForEach(messages, id: \.id) { msg in
                            MessageBubbleView(
                                text: msg.text,
                                isMe: msg.senderId == myId,
                                createdAt: msg.createdAt,
                                isExpanded: expandedMessageIDs.contains(msg.id),
                                status: statusForMessage(msg),
                                onTap: { handleMessageTap(msg) }
                            )
                        }

                        if isOtherTyping {
                            TypingIndicatorView()
                        }

                        Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                    }
                    .padding(.top, 8)
                    .padding(.bottom, bottomContentPadding)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemGroupedBackground))

                // Keep bottom pinned and wire receipts whenever messages change.
                .onChange(of: messages) { _ in
                    hasMoreHistory = messages.count >= messageLimit
                    if isLoadingMore {
                        if let restoreId = restoreScrollToId {
                            DispatchQueue.main.async {
                                proxy.scrollTo(restoreId, anchor: .top)
                            }
                        }
                        restoreScrollToId = nil
                        isLoadingMore = false
                    } else {
                        if messages.isEmpty {
                            // Nothing to scroll yet
                        } else if hasPerformedInitialScroll {
                            scrollToBottom(proxy: proxy, animated: true)
                        } else {
                            DispatchQueue.main.async {
                                scrollToBottom(proxy: proxy, animated: false)
                                hasPerformedInitialScroll = true
                            }
                        }
                    }
                    // Wire up receipts + mark my receipts for incoming
                    setupReceiptsIfNeeded()
                    markIncomingAsDelivered()
                    markIncomingAsRead()
                    // Clear pending IDs that no longer exist (server confirmed / replaced)
                    purgeStalePendingIDs()
                    loggedVoiceNoteIDs = loggedVoiceNoteIDs.intersection(Set(messages.map { $0.id }))
                    logVoiceNotesInSnapshot(context: "messages_change")
                }
                .onChange(of: isOtherTyping) { _ in
                    guard !isLoadingMore else { return }
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .imageScale(.medium)
                            .font(.headline)
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .principal) {
                    profileHeader
                }
            }
            // FIX: use SwiftUI's Visibility + inferred placement
            .toolbar(.hidden, for: .tabBar)

            // Bottom bar (composer)
            // FIX: use the matching overload without spacing param confusion
            .safeAreaInset(edge: .bottom) {
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

            .task { await openThreadIfNeeded() }
            .task { await usersStore.ensure(uid: otherUID) }
            .onAppear {
                // Defensive first pass (in case messages already present)
                markIncomingAsDelivered()
                markIncomingAsRead()
                logVoiceNotesInSnapshot(context: "onAppear")
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
            .navigationDestination(isPresented: $showingProfile) {
                UserProfileView(userId: otherUID)
            }
        }
        .onAppear(perform: syncMyIdFromSession)
        .onChange(of: session.currentUser?.id) { _ in syncMyIdFromSession() }
        .onChange(of: myId) { _ in
            Task { await openThreadIfNeeded() }
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
        guard let tid = threadId, !myId.isEmpty else { return }
        let otherId = otherUID
        let myIdCopy = myId
        let messageIds = messages
            .filter { $0.senderId == otherId }
            .map { $0.id }
        guard !messageIds.isEmpty else { return }

        let threadIdCopy = tid
        Task.detached(priority: .utility) {
            for messageId in messageIds {
                #if DEBUG
                print("MARK DELIVERED tid=\(threadIdCopy) msg=\(messageId) to=\(myIdCopy)")
                #endif
                await ReceiptsService.shared.markDelivered(threadId: threadIdCopy,
                                                            messageId: messageId,
                                                            to: myIdCopy)
            }
        }
    }

    private func markIncomingAsRead() {
        guard let tid = threadId, !myId.isEmpty else { return }
        let otherId = otherUID
        let myIdCopy = myId
        let messageIds = messages
            .filter { $0.senderId == otherId }
            .map { $0.id }
        guard !messageIds.isEmpty else { return }

        let threadIdCopy = tid
        Task.detached(priority: .utility) {
            for messageId in messageIds {
                #if DEBUG
                print("MARK READ tid=\(threadIdCopy) msg=\(messageId) by=\(myIdCopy)")
                #endif
                await ReceiptsService.shared.markRead(threadId: threadIdCopy,
                                                       messageId: messageId,
                                                       by: myIdCopy)
            }
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

    private func handleMessageTap(_ message: MessageModel) {
        var extras: [String: String] = [:]
        if pendingOutgoingIDs.contains(message.id) { extras["pending"] = "true" }
        if deliveredByOther.contains(message.id) { extras["delivered"] = "true" }
        if readByOther.contains(message.id) { extras["read"] = "true" }
        logVoiceNote(event: "playback_tapped", message: message, extras: extras)
        handleTap(on: message.id)
    }

    // MARK: - Sending

    private func send() {
        guard let tid = threadId, !myId.isEmpty else { return }

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

        if voiceNoteDetails(from: local.text) != nil {
            logVoiceNote(event: "outgoing_local_prepared", message: local, extras: [
                "threadId": tid,
                "pending": "true"
            ])
            loggedVoiceNoteIDs.insert(localId)
        }

        // Fire off the real send; when it completes, clear pending for that local id.
        Task {
            logVoiceNote(event: "send_requested", messageId: localId, senderId: myId, text: trimmed, extras: [
                "threadId": tid
            ])
            do {
                try await ChatService.shared.sendMessage(threadId: tid, from: myId, text: trimmed)
                logVoiceNote(event: "send_succeeded", messageId: localId, senderId: myId, text: trimmed, extras: [
                    "threadId": tid
                ])
            } catch {
                logVoiceNote(event: "send_failed", messageId: localId, senderId: myId, text: trimmed, extras: [
                    "threadId": tid,
                    "error": error.localizedDescription
                ])
            }
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

    private func openThreadIfNeeded() async {
        guard !isOpening else { return }
        guard threadId == nil else { return }
        guard !myId.isEmpty else { return }
        isOpening = true
        defer { isOpening = false }

        if let t = try? await ChatService.shared.ensureThread(currentUID: myId, otherUID: otherUID),
           let tid = t.id, !tid.isEmpty {
            await MainActor.run {
                self.threadId = tid
                messageLimit = pageSize
                hasMoreHistory = false
                isLoadingMore = false
                restoreScrollToId = nil
                hasPerformedInitialScroll = false
                startListening(threadId: tid, limit: messageLimit)
                startTypingListener(threadId: tid)
                #if DEBUG
                print("Opened threadId=\(tid) as myId=\(myId) with otherUID=\(otherUID)")
                #endif
            }
        }
    }

    private func startListening(threadId: String, limit: Int) {
        listener?.remove()
        listener = ChatService.shared.listenMessages(threadId: threadId, limit: limit) { list in
            Task { @MainActor in
                self.messages = filteredMessages(list, threadId: threadId)
                self.logVoiceNotesInSnapshot(context: "listener_update")
                #if DEBUG
                print("Messages updated (\(list.count)) for thread=\(threadId)")
                #endif
            }
        }
    }

    private func filteredMessages(_ list: [MessageModel], threadId: String) -> [MessageModel] {
        guard let cutoff = threadsStore.deletionCutoff(for: threadId) else { return list }
        return list.filter { message in
            guard let created = message.createdAt else { return false }
            return created > cutoff
        }
    }

    private func loadMoreHistory() {
        guard hasMoreHistory, !isLoadingMore, let tid = threadId else { return }
        restoreScrollToId = messages.first?.id
        isLoadingMore = true
        messageLimit += pageSize
        startListening(threadId: tid, limit: messageLimit)
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

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let targetId = messages.last?.id ?? "BOTTOM_ANCHOR"
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(targetId, anchor: .bottom)
        }
    }

    private var otherUser: AppUser? { usersStore.user(for: otherUID) }

    private var otherDisplayName: String {
        guard let user = otherUser else { return "" }
        let trimmed = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.handle : trimmed
    }

    private var otherHandleText: String {
        if let user = otherUser {
            return "@\(user.handle)"
        }
        return "@\(otherUID.prefix(6))"
    }

    private var otherAvatarURL: String? { otherUser?.avatarURL }

    private var otherAvatarLabel: String {
        if let user = otherUser {
            let trimmed = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? user.handle : trimmed
        }
        return "User \(otherUID.prefix(6))"
    }

    private var otherStatusText: String? {
        guard let user = otherUser else { return nil }
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

    private var profileHeader: some View {
        Button(action: { showingProfile = true }) {
            HStack(spacing: 12) {
                AvatarView(avatarURL: otherAvatarURL,
                           name: otherAvatarLabel,
                           size: 32,
                           showPresenceIndicator: true,
                           isOnline: otherUser?.isVisiblyOnline ?? false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(otherDisplayName.isEmpty ? "Chat" : otherDisplayName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(otherHandleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let status = otherStatusText {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel("View profile for \(otherDisplayName.isEmpty ? "this conversation" : otherDisplayName)")
        .accessibilityHint("Opens profile details")
    }
}

// MARK: - Helpers

private extension ThreadView {
    func syncMyIdFromSession() {
        guard let sessionId = session.currentUser?.id, !sessionId.isEmpty else { return }
        if myId != sessionId {
            myId = sessionId
        }
    }

    func logVoiceNotesInSnapshot(context: String) {
        for message in messages {
            guard voiceNoteDetails(from: message.text) != nil else { continue }
            guard !loggedVoiceNoteIDs.contains(message.id) else { continue }
            var extras: [String: String] = ["context": context]
            if pendingOutgoingIDs.contains(message.id) { extras["pending"] = "true" }
            if deliveredByOther.contains(message.id) { extras["delivered"] = "true" }
            if readByOther.contains(message.id) { extras["read"] = "true" }
            logVoiceNote(event: "snapshot_seen", message: message, extras: extras)
            loggedVoiceNoteIDs.insert(message.id)
        }
    }

    func logVoiceNote(event: String, message: MessageModel, extras: [String: String] = [:]) {
        var combined = extras
        if let created = message.createdAt {
            combined["createdAt"] = Self.logDateFormatter.string(from: created)
        }
        logVoiceNote(event: event,
                     messageId: message.id,
                     senderId: message.senderId,
                     text: message.text,
                     extras: combined)
    }

    func logVoiceNote(event: String, messageId: String, senderId: String, text: String, extras: [String: String] = [:]) {
        guard let details = voiceNoteDetails(from: text) else { return }
        var components: [String] = [
            "[VoiceNote]",
            event,
            "messageId=\(messageId)",
            "senderId=\(senderId)",
            "direction=\(senderId == myId ? "outgoing" : "incoming")"
        ]

        var mergedFields = details.fields
        for (key, value) in extras {
            mergedFields[key] = value
        }

        for (key, value) in mergedFields.sorted(by: { $0.key < $1.key }) {
            components.append("\(key)=\(value)")
        }

        components.append("payload=\(details.summary)")
        print(components.joined(separator: " | "))
    }

    func voiceNoteDetails(from text: String) -> VoiceNoteDetails? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var lowered: [String: Any] = [:]
            for (key, value) in json {
                let loweredKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                lowered[loweredKey] = value
            }

            let typeCandidates = ["type", "messagetype", "kind", "category", "mediatype"]
            let typeValue = firstString(for: typeCandidates, in: lowered)
            let audioURL = firstString(for: ["audiourl", "voiceurl", "voicenoteurl", "url", "remoteurl", "downloadurl", "mediaurl"], in: lowered)
            let localRef = firstString(for: ["localpath", "localurl", "localreference", "file", "filepath"], in: lowered)
            let duration = firstNumericString(for: ["duration", "durationseconds", "length", "lengthseconds", "audiolength"], in: lowered)
            let fileSize = firstNumericString(for: ["filesize", "size", "filesizebytes"], in: lowered)
            let waveformCount = waveformDescription(from: lowered)
            let codec = firstString(for: ["mimetype", "codec", "audiocodec", "contenttype"], in: lowered)
            let voiceFlag = isTruthy(lowered["isvoice"]) || isTruthy(lowered["voice"]) || isTruthy(lowered["voicenote"]) || isTruthy(lowered["isvoicenote"])

            let looksLikeVoice = voiceFlag || typeValue?.lowercased().contains("voice") == true
            let looksLikeAudio = typeValue?.lowercased().contains("audio") == true
            if looksLikeVoice || audioURL != nil || localRef != nil || looksLikeAudio {
                var fields: [String: String] = [:]
                if let typeValue { fields["type"] = typeValue }
                if let audioURL { fields["audioURL"] = audioURL }
                if let localRef { fields["local"] = localRef }
                if let duration { fields["duration"] = duration }
                if let fileSize { fields["fileSize"] = fileSize }
                if let waveformCount { fields["waveform"] = waveformCount }
                if let codec { fields["codec"] = codec }

                let summary: String
                if let compact = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                   let string = String(data: compact, encoding: .utf8) {
                    summary = truncated(string)
                } else {
                    summary = truncated(trimmed)
                }

                return VoiceNoteDetails(summary: summary, fields: fields)
            }
        }

        let lower = trimmed.lowercased()
        let keywords = ["voice_note", "voice-note", "voicenote", "\"voice\"", "\"audio\""]
        let extensions = [".m4a", ".aac", ".mp3", ".wav", ".caf", ".ogg"]
        let containsKeyword = keywords.contains { lower.contains($0) }
        let containsExtension = extensions.contains { lower.contains($0) }

        if containsKeyword || containsExtension {
            return VoiceNoteDetails(summary: truncated(trimmed), fields: [:])
        }

        return nil
    }

    func firstString(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return nil
    }

    func firstNumericString(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = dictionary[key], let numeric = numericString(from: value) {
                return numeric
            }
        }
        return nil
    }

    func waveformDescription(from dictionary: [String: Any]) -> String? {
        let waveformKeys = ["waveform", "waveformpoints", "samples"]
        for key in waveformKeys {
            if let value = dictionary[key] {
                if let array = value as? [Any] {
                    return "count=\(array.count)"
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
                if let string = value as? String, !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    func numericString(from value: Any) -> String? {
        switch value {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if Double(trimmed) != nil {
                return trimmed
            }
            return nil
        default:
            return nil
        }
    }

    func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["true", "1", "yes", "y"].contains(trimmed)
        default:
            return false
        }
    }

    func truncated(_ text: String, limit: Int = 400) -> String {
        if text.count <= limit {
            return text
        }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return "\(text[..<endIndex])…(+\(text.count - limit) chars)"
    }

    private struct VoiceNoteDetails {
        let summary: String
        let fields: [String: String]
    }

    static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
