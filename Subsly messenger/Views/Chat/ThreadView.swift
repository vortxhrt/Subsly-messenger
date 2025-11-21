import SwiftUI
import FirebaseFirestore
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import UIKit
import Combine

struct ThreadView: View {
    // We now use ChatStore for messages to get automatic decryption
    @StateObject private var chatStore = ChatStore()
    @EnvironmentObject private var threadsStore: ThreadsStore
    @EnvironmentObject private var usersStore: UsersStore
    
    let currentUser: AppUser
    let otherUID: String

    private let myId: String

    @State private var threadId: String?
    @State private var inputText: String = ""

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
    // Pending local messages (before they hit server/store)
    @State private var pendingLocalMessages: [MessageModel] = []

    @State private var isOpening = false
    
    // Constants
    private let attachmentLimit: Int = 20
    
    // View State
    @State private var hasPerformedInitialScroll = false
    @State private var showingProfile = false

    @State private var replyPreview: MessageModel.ReplyPreview?

    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var isProcessingAttachment = false
    @State private var attachmentTask: Task<Void, Never>?
    @State private var attachmentErrorMessage: String?
    @State private var showingAttachmentError = false
    @State private var sendErrorMessage: String?
    @State private var showingSendError = false
    @State private var mediaViewer: MediaViewerPayload?

    @State private var composerHeight: CGFloat = 72
    @State private var showingVoiceRecorder = false

    init(currentUser: AppUser, otherUID: String) {
        self.currentUser = currentUser
        self.otherUID = otherUID
        self.myId = currentUser.id ?? ""
    }

    private var canSend: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachment = !pendingAttachments.isEmpty
        return (!trimmed.isEmpty || hasAttachment) && !isProcessingAttachment
    }
    
    // Merge Server Messages (Decrypted from Store) + Local Pending Messages
    private var displayMessages: [MessageModel] {
        var combined = chatStore.messages
        
        if !pendingLocalMessages.isEmpty {
            // Filter out pending messages that have been confirmed by server
            // (Server message usually has clientMessageId matching local id)
            let serverClientIds = Set(combined.compactMap { $0.clientMessageId })
            let filteredPending = pendingLocalMessages.filter { !serverClientIds.contains($0.id) }
            
            let sortedPending = filteredPending.sorted { (lhs, rhs) -> Bool in
                let lhsDate = lhs.createdAt ?? Date()
                let rhsDate = rhs.createdAt ?? Date()
                return lhsDate < rhsDate
            }
            combined.append(contentsOf: sortedPending)
        }
        
        return combined
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        // Padding for top
                        Color.clear.frame(height: 1)

                        ForEach(displayMessages, id: \.id) { msg in
                            let isMe = msg.senderId == myId
                            let metadata = senderMetadata(for: msg)

                            MessageRowView(
                                isMe: isMe,
                                avatarURL: metadata.avatarURL,
                                avatarLabel: metadata.displayName
                            ) {
                                MessageBubbleView(
                                    text: msg.text,
                                    media: msg.media,
                                    isMe: isMe,
                                    createdAt: msg.createdAt,
                                    replyTo: enrichedReplyPreview(for: msg),
                                    isSending: pendingOutgoingIDs.contains(msg.id),
                                    isExpanded: expandedMessageIDs.contains(msg.id),
                                    status: statusForMessage(msg),
                                    onTap: { handleTap(on: msg.id) },
                                    onAttachmentTap: { media in
                                        mediaViewer = MediaViewerPayload(media: media)
                                    },
                                    onReply: { startReply(with: msg) },
                                    onReplyPreviewTap: {
                                        if let replyId = msg.replyTo?.messageId {
                                            scrollToMessage(withId: replyId, proxy: proxy)
                                        }
                                    }
                                )
                            }
                        }

                        if isOtherTyping {
                            TypingIndicatorView()
                        }

                        Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemGroupedBackground))

                // Scroll logic
                .onChange(of: chatStore.messages) { _ in
                    handleMessagesChange(proxy: proxy)
                }
                .onChange(of: pendingLocalMessages.count) { _ in
                     // Scroll to bottom when sending new message locally
                     if !pendingLocalMessages.isEmpty {
                         scheduleBottomScroll(proxy: proxy, animated: true)
                     }
                }
                .onChange(of: isOtherTyping) { _ in
                    scheduleBottomScroll(proxy: proxy, animated: true)
                }
                .onChange(of: composerHeight) { _ in
                    guard hasPerformedInitialScroll else { return }
                    scheduleBottomScroll(proxy: proxy, animated: false)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    profileHeader
                }
            }
            .toolbar(.hidden, for: .tabBar)

            // Bottom bar (composer)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider().opacity(0.08)
                    ComposerView(
                        text: $inputText,
                        attachments: $pendingAttachments,
                        replyPreview: $replyPreview,
                        canSend: canSend,
                        isProcessingAttachment: isProcessingAttachment,
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
                        },
                        onPickAttachments: { items in
                            handleAttachmentSelection(items)
                        },
                        onRemoveAttachment: { attachment in
                            removePendingAttachment(attachment)
                        },
                        onRecordVoice: {
                            if pendingAttachments.count >= attachmentLimit {
                                attachmentErrorMessage = "You can attach up to \(attachmentLimit) items per message."
                                showingAttachmentError = true
                            } else {
                                showingVoiceRecorder = true
                            }
                        },
                        onCancelReply: {
                            replyPreview = nil
                        }
                    )
                }
                .background(.ultraThinMaterial)
                .background(ComposerHeightReader())
            }
            .sheet(isPresented: $showingVoiceRecorder) {
                VoiceRecorderSheet { attachment in
                    if pendingAttachments.count >= attachmentLimit {
                        attachmentErrorMessage = "You can attach up to \(attachmentLimit) items per message."
                        showingAttachmentError = true
                        return
                    }
                    pendingAttachments.append(attachment)
                }
            }

            .task { await openThreadIfNeeded() }
            .task { await usersStore.ensure(uid: otherUID) }
            .onAppear {
                scheduleBottomScroll(proxy: proxy, animated: false, delay: 0.05)
                // Defensive first pass (in case messages already present)
                setupReceiptsIfNeeded()
                markIncomingAsDelivered()
                markIncomingAsRead()
            }
            .onDisappear {
                chatStore.stop()
                typingListener?.remove(); typingListener = nil
                cleanupReceiptListeners()
                for attachment in pendingAttachments {
                    if let url = attachment.fileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                pendingAttachments.removeAll()
                pendingLocalMessages.removeAll()
                pendingOutgoingIDs.removeAll()
                
                attachmentTask?.cancel(); attachmentTask = nil
                if let tid = threadId, !myId.isEmpty {
                    Task { try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false) }
                }
            }
            .navigationDestination(isPresented: $showingProfile) {
                UserProfileView(userId: otherUID)
            }
            .alert("Attachment Error", isPresented: $showingAttachmentError, presenting: attachmentErrorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .alert("Message Not Sent", isPresented: $showingSendError, presenting: sendErrorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .fullScreenCover(item: $mediaViewer) { payload in
                MediaViewerView(media: payload.media)
            }
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { newValue in
            let clamped = max(newValue, 52)
            if abs(composerHeight - clamped) > 0.5 {
                composerHeight = clamped
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
        let readSet = Set(msg.readBy).union(readByOther.contains(msg.id) ? [otherUID] : [])
        if readSet.contains(otherUID) {
            return .read
        }
        let deliveredSet = Set(msg.deliveredTo).union(deliveredByOther.contains(msg.id) ? [otherUID] : [])
        if deliveredSet.contains(otherUID) {
            return .delivered
        }
        return .sent
    }

    // MARK: - Receipts wiring

    private func setupReceiptsIfNeeded() {
        guard let tid = threadId else { return }

        var activeMessageIDs: Set<String> = []
        // Use displayMessages to include both server and local (though local won't have receipts yet)
        for msg in displayMessages where msg.senderId == myId {
            if msg.id.hasPrefix("local-") { continue }
            activeMessageIDs.insert(msg.id)

            if msg.deliveredTo.contains(otherUID) {
                deliveredByOther.insert(msg.id)
            } else {
                deliveredByOther.remove(msg.id)
            }

            if msg.readBy.contains(otherUID) {
                readByOther.insert(msg.id)
            } else {
                readByOther.remove(msg.id)
            }

            if receiptListeners[msg.id] == nil {
                let listener = ReceiptsService.shared.listenReceipts(threadId: tid, messageId: msg.id) { delivered, read in
                    Task { @MainActor in
                        if delivered.contains(self.otherUID) {
                            self.deliveredByOther.insert(msg.id)
                        } else {
                            self.deliveredByOther.remove(msg.id)
                        }

                        if read.contains(self.otherUID) {
                            self.readByOther.insert(msg.id)
                        } else {
                            self.readByOther.remove(msg.id)
                        }
                    }
                }
                receiptListeners[msg.id] = listener
            }
        }

        for (id, listener) in receiptListeners where !activeMessageIDs.contains(id) {
            listener.remove()
            receiptListeners.removeValue(forKey: id)
            deliveredByOther.remove(id)
            readByOther.remove(id)
        }
    }

    private func cleanupReceiptListeners() {
        for (_, listener) in receiptListeners {
            listener.remove()
        }
        receiptListeners.removeAll()
        deliveredByOther.removeAll()
        readByOther.removeAll()
    }

    /// Mark *incoming* messages as delivered and read (idempotent).
    private func markIncomingAsDelivered() {
        guard let tid = threadId else { return }
        let otherId = otherUID
        let myIdCopy = myId
        // Filter from server messages only
        let messageIds = chatStore.messages
            .filter { $0.senderId == otherId }
            .map { $0.id }
        guard !messageIds.isEmpty else { return }

        let threadIdCopy = tid
        Task.detached(priority: .utility) {
            for messageId in messageIds {
                await ReceiptsService.shared.markDelivered(threadId: threadIdCopy,
                                                            messageId: messageId,
                                                            to: myIdCopy)
            }
        }
    }

    private func markIncomingAsRead() {
        guard let tid = threadId else { return }
        let otherId = otherUID
        let myIdCopy = myId
        // Filter from server messages only
        let messageIds = chatStore.messages
            .filter { $0.senderId == otherId }
            .map { $0.id }
        guard !messageIds.isEmpty else { return }

        let threadIdCopy = tid
        Task.detached(priority: .utility) {
            for messageId in messageIds {
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

    // MARK: - Sending

    private func send() {
        guard let tid = threadId else { return }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }

        let replyContext = replyPreview

        let localId = "local-" + UUID().uuidString
        let localMessage = MessageModel(
            id: localId,
            clientMessageId: localId,
            senderId: myId,
            text: trimmed,
            createdAt: Date(),
            media: pendingAttachments.map { $0.asMessageMedia() },
            deliveredTo: [],
            readBy: [],
            replyTo: replyContext
        )
        pendingOutgoingIDs.insert(localId)
        pendingLocalMessages.append(localMessage)
        // UI update happens automatically via displayMessages
        
        inputText = ""
        let attachmentsCopy = pendingAttachments
        pendingAttachments.removeAll()
        replyPreview = nil

        Task {
            do {
                try await ChatService.shared.sendMessage(
                    threadId: tid,
                    from: myId,
                    text: trimmed,
                    clientMessageId: localId,
                    attachments: attachmentsCopy,
                    reply: replyContext
                )
            } catch {
                for attachment in attachmentsCopy {
                    if let url = attachment.fileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                await MainActor.run {
                    if let chatError = error as? ChatServiceError {
                        sendErrorMessage = chatError.localizedDescription
                    } else {
                        sendErrorMessage = "We couldn’t send your message. Please try again."
                    }
                    showingSendError = true
                }
                await MainActor.run {
                    self.pendingOutgoingIDs.remove(localId)
                    self.pendingLocalMessages.removeAll { $0.id == localId }
                }
            }
        }

        Task {
            try? await TypingService.shared.setTyping(threadId: tid, userId: myId, isTyping: false)
        }
    }

    // MARK: - Updates

    private func handleMessagesChange(proxy: ScrollViewProxy) {
        if !chatStore.messages.isEmpty {
            if hasPerformedInitialScroll {
                scheduleBottomScroll(proxy: proxy, animated: true)
            } else {
                scheduleBottomScroll(proxy: proxy, animated: false)
                scheduleBottomScroll(proxy: proxy, animated: false, delay: 0.08)
                scheduleBottomScroll(proxy: proxy, animated: false, delay: 0.18)
                hasPerformedInitialScroll = true
            }
        }
        
        // Cleanup pending messages that have arrived from server
        let serverClientIds = Set(chatStore.messages.compactMap { $0.clientMessageId })
        pendingLocalMessages.removeAll { msg in
            if let cid = msg.clientMessageId, serverClientIds.contains(cid) {
                pendingOutgoingIDs.remove(msg.id)
                return true
            }
            return false
        }

        setupReceiptsIfNeeded()
        markIncomingAsDelivered()
        markIncomingAsRead()
    }

    private func removePendingAttachment(_ attachment: PendingAttachment) {
        if let url = attachment.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - Reply handling

    private func startReply(with message: MessageModel) {
        // Note: When replying, we use the decrypted text from the model if available
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewText = trimmed.isEmpty ? nil : trimmed
        let name = resolvedDisplayName(for: message.senderId)
        replyPreview = MessageModel.ReplyPreview(
            messageId: message.id,
            senderId: message.senderId,
            senderName: name,
            text: previewText,
            mediaKind: message.media.first?.kind
        )

        Task { await usersStore.ensure(uid: message.senderId) }
    }

    private func enrichedReplyPreview(for message: MessageModel) -> MessageModel.ReplyPreview? {
        guard let preview = message.replyTo else { return nil }
        if preview.senderName != nil {
            return preview
        }
        guard let senderId = preview.senderId else { return preview }
        let name = resolvedDisplayName(for: senderId)
        return preview.withSenderName(name)
    }

    private func resolvedDisplayName(for uid: String) -> String {
        if uid == myId {
            let trimmed = currentUser.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            let handleTrimmed = currentUser.handle.trimmingCharacters(in: .whitespacesAndNewlines)
            return handleTrimmed.isEmpty ? "You" : handleTrimmed
        }
        if let name = usersStore.displayName(for: uid) {
            return name
        }
        return "User \(uid.prefix(6))"
    }

    private func handleAttachmentSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        if pendingAttachments.count >= attachmentLimit {
            attachmentErrorMessage = "You can attach up to \(attachmentLimit) items per message."
            showingAttachmentError = true
            return
        }
        attachmentTask?.cancel()
        isProcessingAttachment = true
        attachmentTask = Task {
            var prepared: [PendingAttachment] = []
            var hitLimit = false
            do {
                for item in items {
                    try Task.checkCancellation()
                    let currentCount = await MainActor.run { self.pendingAttachments.count }
                    if currentCount + prepared.count >= attachmentLimit {
                        hitLimit = true
                        break
                    }
                    let attachment = try await prepareAttachment(from: item)
                    prepared.append(attachment)
                }

                if !prepared.isEmpty {
                    await MainActor.run {
                        self.pendingAttachments.append(contentsOf: prepared)
                    }
                }

                if hitLimit {
                    await MainActor.run {
                        self.attachmentErrorMessage = "You can attach up to \(attachmentLimit) items per message."
                        self.showingAttachmentError = true
                    }
                }

                await MainActor.run {
                    self.isProcessingAttachment = false
                }
            } catch {
                if !prepared.isEmpty {
                    await MainActor.run {
                        self.pendingAttachments.append(contentsOf: prepared)
                    }
                }
                await MainActor.run {
                    self.isProcessingAttachment = false
                    self.attachmentErrorMessage = "We couldn’t process one of the selected items. Please try again."
                    self.showingAttachmentError = true
                }
            }

            await MainActor.run {
                self.attachmentTask = nil
            }
        }
    }

    private func prepareAttachment(from item: PhotosPickerItem) async throws -> PendingAttachment {
        if let data = try await item.loadTransferable(type: Data.self) {
            if let image = UIImage(data: data) {
                let maxDimension: CGFloat = 1600
                let resized = image.resizedMaintainingAspect(maxDimension: maxDimension)
                guard let jpegData = resized.jpegData(compressionQuality: 0.75) else {
                    throw AttachmentPreparationError.imageEncodingFailed
                }
                return PendingAttachment(kind: .image(
                    data: jpegData,
                    width: Int(resized.size.width),
                    height: Int(resized.size.height)
                ))
            }
        }

        if let video = try await item.loadTransferable(type: PickedVideo.self) {
            let compressedURL = try await compressVideo(at: video.url)
            try? FileManager.default.removeItem(at: video.url)
            let asset = AVAsset(url: compressedURL)
            let dimensions = videoDimensions(for: asset)
            let thumbnail = try generateThumbnail(for: asset)
            guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.7) else {
                throw AttachmentPreparationError.thumbnailFailed
            }
            let duration = CMTimeGetSeconds(asset.duration)
            return PendingAttachment(kind: .video(
                fileURL: compressedURL,
                thumbnailData: thumbnailData,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                duration: duration
            ))
        }

        throw AttachmentPreparationError.unsupported
    }

    private func compressVideo(at url: URL) async throws -> URL {
        let asset = AVAsset(url: url)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw AttachmentPreparationError.videoEncodingFailed
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    let error = exportSession.error ?? AttachmentPreparationError.videoEncodingFailed
                    continuation.resume(throwing: error)
                default:
                    let error = exportSession.error ?? AttachmentPreparationError.videoEncodingFailed
                    continuation.resume(throwing: error)
                }
            }
        }

        return outputURL
    }

    private func videoDimensions(for asset: AVAsset) -> CGSize {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return CGSize(width: 720, height: 1280)
        }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func generateThumbnail(for asset: AVAsset) throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.1)
        let captureSeconds = min(max(durationSeconds / 3.0, 0.1), durationSeconds)
        let captureTime = CMTime(seconds: captureSeconds, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Thread bootstrap + listeners

    private func openThreadIfNeeded() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        guard !myId.isEmpty else { return }

        if let t = try? await ChatService.shared.ensureThread(currentUID: myId, otherUID: otherUID),
           let tid = t.id, !tid.isEmpty {
            await MainActor.run {
                self.threadId = tid
                hasPerformedInitialScroll = false
                // E2EE: Start ChatStore instead of raw listener
                chatStore.start(threadId: tid, otherUserId: otherUID)
                
                startTypingListener(threadId: tid)
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

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let targetId = displayMessages.last?.id ?? "BOTTOM_ANCHOR"
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(targetId, anchor: .bottom)
        }
    }

    private func scheduleBottomScroll(proxy: ScrollViewProxy, animated: Bool, delay: Double = 0) {
        let work = {
            scrollToBottom(proxy: proxy, animated: animated)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func scrollToMessage(withId id: String, proxy: ScrollViewProxy) {
        guard chatStore.messages.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(id, anchor: .center)
        }
        showTemporarily(id)
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

    private var otherStatus: AvatarView.OnlineStatus? {
        guard let user = otherUser else { return nil }
        return AvatarView.OnlineStatus(isOnline: user.isOnline, isVisible: user.shareOnlineStatus)
    }

    private func senderMetadata(for message: MessageModel) -> (avatarURL: String?, displayName: String) {
        let senderId = message.senderId

        if senderId == myId {
            let name = resolvedDisplayName(for: myId)
            return (currentUser.avatarURL, name)
        }

        if let cached = usersStore.user(for: senderId) {
            let name = cached.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferred = name.isEmpty ? cached.handle : name
            return (cached.avatarURL, preferred)
        }

        let fallback = resolvedDisplayName(for: senderId)
        return (nil, fallback)
    }

    private var profileHeader: some View {
        Button(action: { showingProfile = true }) {
            HStack(spacing: 12) {
                AvatarView(avatarURL: otherAvatarURL, name: otherAvatarLabel, size: 32, status: otherStatus)
                VStack(alignment: .leading, spacing: 2) {
                    Text(otherDisplayName.isEmpty ? "Chat" : otherDisplayName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(otherHandleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel("View profile for \(otherDisplayName.isEmpty ? "this conversation" : otherDisplayName)")
        .accessibilityHint("Opens profile details")
    }
}

// MARK: - Media viewer support

private struct MediaViewerPayload: Identifiable {
    let id = UUID()
    let media: MessageModel.Media
}

private struct MessageRowView<Content: View>: View {
    let isMe: Bool
    let avatarURL: String?
    let avatarLabel: String
    private let content: () -> Content

    private let avatarSize: CGFloat = 28
    private let horizontalInset: CGFloat = 8

    init(isMe: Bool,
         avatarURL: String?,
         avatarLabel: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.isMe = isMe
        self.avatarURL = avatarURL
        self.avatarLabel = avatarLabel
        self.content = content
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer(minLength: 0)
                content()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                AvatarView(avatarURL: avatarURL, name: avatarLabel, size: avatarSize)
                    .accessibilityLabel(avatarLabel)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, horizontalInset)
    }
}

private struct MediaViewerView: View {
    let media: MessageModel.Media
    @Environment(\.dismiss) private var dismiss
    @StateObject private var videoController = VideoPlayerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .padding()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
            .accessibilityLabel("Close media viewer")
        }
        .onDisappear {
            videoController.reset()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch media.kind {
        case .image:
            ZoomableImageContainer(
                localImage: resolvedImage(),
                remoteURL: resolvedImageURL()
            )

        case .video:
            if let url = resolvedVideoURL() {
                VideoPlayer(player: videoController.player)
                    .ignoresSafeArea()
                    .onAppear {
                        videoController.configure(with: url)
                        videoController.play()
                    }
                    .onDisappear {
                        videoController.pause()
                    }
            } else if let image = resolvedImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
            }

        case .audio:
            AudioPlayerViewer(media: media)
        }
    }

    private func resolvedImage() -> UIImage? {
        if let data = media.localData, let image = UIImage(data: data) {
            return image
        }
        if let data = media.localThumbnailData, let image = UIImage(data: data) {
            return image
        }
        return nil
    }

    private func resolvedImageURL() -> URL? {
        if media.kind == .image, let urlString = media.url {
            return URL(string: urlString)
        }
        if media.kind == .video, let thumb = media.thumbnailURL ?? media.url {
            return URL(string: thumb)
        }
        return nil
    }

    private func resolvedVideoURL() -> URL? {
        guard media.kind == .video, let urlString = media.url else {
            return nil
        }
        return URL(string: urlString)
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Loading media…")
                .foregroundColor(.white.opacity(0.7))
                .font(.callout)
        }
    }
}

private struct ZoomableImageContainer: View {
    let localImage: UIImage?
    let remoteURL: URL?

    @State private var remoteImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image = localImage ?? remoteImage {
                ZoomableImageView(image: image)
            } else if loadFailed {
                errorView
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: remoteURL) {
            guard remoteImage == nil, localImage == nil, let url = remoteURL else { return }
            await loadRemoteImage(url)
        }
    }

    private func loadRemoteImage(_ url: URL) async {
        await MainActor.run {
            isLoading = true
            loadFailed = false
        }
        do {
            let data = try await MediaCache.shared.data(for: url)
            if Task.isCancelled { return }
            if let image = UIImage(data: data) {
                await MainActor.run {
                    remoteImage = image
                    isLoading = false
                    loadFailed = false
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                }
            }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run {
                isLoading = false
                loadFailed = true
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text(isLoading ? "Loading image…" : "Preparing image…")
                .foregroundColor(.white.opacity(0.7))
                .font(.callout)
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
            Text("Image failed to load")
                .foregroundColor(.white.opacity(0.7))
                .font(.callout)
        }
    }
}

private struct ZoomableImageView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(dragGesture(containerSize: size))
                .simultaneousGesture(magnificationGesture(containerSize: size))
                .onTapGesture(count: 2) {
                    toggleZoom(containerSize: size)
                }
                .animation(.easeOut(duration: 0.2), value: scale)
        }
        .clipped()
    }

    private func magnificationGesture(containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                var newScale = scale * delta
                newScale = min(max(newScale, 1), 4)
                scale = newScale
                lastScale = value
                clampOffset(in: containerSize, animated: false)
            }
            .onEnded { _ in
                lastScale = 1
                if scale <= 1.01 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                } else {
                    clampOffset(in: containerSize, animated: true)
                }
            }
    }

    private func dragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                let translation = value.translation
                offset = CGSize(
                    width: lastOffset.width + translation.width,
                    height: lastOffset.height + translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                lastOffset = offset
                clampOffset(in: containerSize, animated: true)
            }
    }

    private func toggleZoom(containerSize: CGSize) {
        if scale > 1.01 {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = 1
                offset = .zero
                lastOffset = .zero
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = 2
                offset = .zero
                lastOffset = .zero
            }
            clampOffset(in: containerSize, animated: true)
        }
    }

    private func clampOffset(in containerSize: CGSize, animated: Bool) {
        guard scale > 1 else {
            let update = {
                offset = .zero
                lastOffset = .zero
            }
            if animated {
                withAnimation(.easeOut(duration: 0.2), update)
            } else {
                update()
            }
            return
        }

        let fitted = fittedSize(in: containerSize)
        let scaledWidth = fitted.width * scale
        let scaledHeight = fitted.height * scale

        let horizontalLimit = max((scaledWidth - containerSize.width) / 2, 0)
        let verticalLimit = max((scaledHeight - containerSize.height) / 2, 0)

        let clampedX = min(max(offset.width, -horizontalLimit), horizontalLimit)
        let clampedY = min(max(offset.height, -verticalLimit), verticalLimit)

        let update = {
            offset = CGSize(width: clampedX, height: clampedY)
            lastOffset = offset
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2), update)
        } else {
            update()
        }
    }

    private func fittedSize(in containerSize: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return containerSize
        }
        let aspect = imageSize.width / imageSize.height
        var width = containerSize.width
        var height = width / aspect
        if height > containerSize.height {
            height = containerSize.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }
}

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 72

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ComposerHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: ComposerHeightPreferenceKey.self, value: proxy.size.height)
        }
    }
}

@MainActor
private final class VideoPlayerController: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let player = AVPlayer()
    private var currentURL: URL?

    func configure(with url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        objectWillChange.send()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func reset() {
        pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        objectWillChange.send()
    }
}

// MARK: - Fullscreen audio viewer

private struct AudioPlayerViewer: View {
    let media: MessageModel.Media
    @StateObject private var controller = AudioViewerController()

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            // Big play/pause
            Button(action: controller.togglePlayback) {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 84, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(controller.isLoading || controller.error != nil)

            // Progress + times
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { controller.duration > 0 ? controller.progress : 0 },
                    set: { controller.seek(toProgress: $0) }
                ))
                .tint(.white)
                .disabled(controller.duration <= 0)

                HStack {
                    Text(Self.format(controller.currentTime))
                    Spacer()
                    Text(Self.format(controller.duration))
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal)

            if controller.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else if let err = controller.error {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                // filename / hint
                Text("Voice message")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.callout)
            }

            Spacer(minLength: 0)
        }
        .task(id: controller.identityKey(for: media)) {
            controller.configure(with: media)
        }
    }

    private static func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(round(value)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

@MainActor
private final class AudioViewerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?

    func identityKey(for media: MessageModel.Media) -> String {
        if let path = media.localFilePath { return "path:\(path)" }
        if let url = media.url { return "url:\(url)" }
        if let data = media.localData { return "data:\(data.count)-\(media.duration ?? 0)" }
        return UUID().uuidString
    }

    func configure(with media: MessageModel.Media) {
        cancelLoading()
        stopPlayback(releaseSession: true)
        error = nil
        progress = 0
        currentTime = 0
        duration = media.duration ?? 0
        isLoading = true

        loadTask = Task {
            // Prefer local data
            if let data = media.localData, !data.isEmpty {
                await MainActor.run { self.setupPlayer(with: data, hintDuration: media.duration) }
                return
            }

            // Or local file path
            if let path = media.localFilePath, FileManager.default.fileExists(atPath: path) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    try Task.checkCancellation()
                    await MainActor.run { self.setupPlayer(with: data, hintDuration: media.duration) }
                    return
                } catch {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }

            // Remote URL
            guard let urlString = media.url, let url = URL(string: urlString) else {
                await MainActor.run {
                    self.isLoading = false
                    self.error = "Audio unavailable."
                }
                return
            }

            do {
                let data = try await MediaCache.shared.data(for: url)
                try Task.checkCancellation()
                await MainActor.run { self.setupPlayer(with: data, hintDuration: media.duration) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isLoading = false
                    self.error = "We couldn’t load this audio."
                }
            }
        }
    }

    func togglePlayback() {
        guard error == nil, !isLoading else { return }
        isPlaying ? pause() : play()
    }

    func seek(toProgress newValue: Double) {
        guard let player, duration > 0 else { return }
        let clamped = max(0, min(1, newValue))
        let target = duration * clamped
        player.currentTime = target
        currentTime = target
        progress = clamped
        if isPlaying {
            // ensure timer keeps running
            startTimer()
        }
    }

    // MARK: - Internals

    private func setupPlayer(with data: Data, hintDuration: Double?) {
        stopPlayback(releaseSession: true)
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.duration = hintDuration ?? player.duration
            self.currentTime = 0
            self.progress = 0
            self.isLoading = false
        } catch {
            self.player = nil
            self.isLoading = false
            self.error = "We couldn’t load this audio."
        }
    }

    private func play() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: [])
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            self.error = "Playback unavailable."
            stopPlayback(releaseSession: true)
        }
    }

    private func pause() {
        guard let player else { return }
        player.pause()
        currentTime = player.currentTime
        progress = duration > 0 ? player.currentTime / duration : 0
        isPlaying = false
        stopTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopPlayback(releaseSession: Bool) {
        if let player {
            player.stop()
            self.player = nil
        }
        isPlaying = false
        stopTimer()
        if releaseSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        currentTime = 0
        progress = 0
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if self.duration > 0 {
                self.progress = max(0, min(1, player.currentTime / self.duration))
            } else {
                self.progress = 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = duration
        progress = duration > 0 ? 1 : 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private enum AttachmentPreparationError: LocalizedError {
    case unsupported
    case imageEncodingFailed
    case videoEncodingFailed
    case thumbnailFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "The selected item cannot be shared as a message."
        case .imageEncodingFailed:
            return "We couldn't process that image. Try a different photo."
        case .videoEncodingFailed:
            return "We couldn't process that video. Try again with a different clip."
        case .thumbnailFailed:
            return "The video thumbnail failed to generate."
        }
    }
}

private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let originalExtension = received.file.pathExtension
            let resolvedExtension: String
            if !originalExtension.isEmpty {
                resolvedExtension = originalExtension
            } else if let fallback = UTType.movie.preferredFilenameExtension {
                resolvedExtension = fallback
            } else {
                resolvedExtension = "mov"
            }

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(resolvedExtension)
            try FileManager.default.copyItem(at: received.file, to: temporaryURL)
            return PickedVideo(url: temporaryURL)
        }
    }
}
