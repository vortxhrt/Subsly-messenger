import SwiftUI
import UIKit
import AVFoundation
import Combine

enum DeliveryState {
    case pending   // sending (show spinner)
    case sent      // on server, not yet delivered
    case delivered // delivered to other device
    case read      // read by other device
}

struct MessageBubbleView: View {
    let text: String
    let media: [MessageModel.Media]
    let isMe: Bool
    let createdAt: Date?
    let replyTo: MessageModel.ReplyPreview?
    let isSending: Bool
    let isExpanded: Bool
    let status: DeliveryState?       // only used for outgoing (isMe == true)
    let onTap: () -> Void
    var onAttachmentTap: (MessageModel.Media) -> Void = { _ in }
    var onReply: () -> Void = {}
    var onReplyPreviewTap: () -> Void = {}

    private let edgeInset: CGFloat = 10
    private let verticalSpacing: CGFloat = 2

    private var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.75 }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasText: Bool { !trimmedText.isEmpty }
    private var hasBubbleContent: Bool { hasText || replyTo != nil }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
            if !media.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(media.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 0) {
                            if isMe { Spacer(minLength: 0) }
                            attachmentView(for: item)
                                .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
                                .padding(.leading, isMe ? 0 : edgeInset)
                                .padding(.trailing, isMe ? edgeInset : 0)
                            if !isMe { Spacer(minLength: 0) }
                        }
                    }
                }
            }

            if hasBubbleContent {
                HStack(spacing: 0) {
                    if isMe { Spacer(minLength: 0) }
                    bubbleContainer
                        .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
                        .padding(.trailing, isMe ? edgeInset : 0)
                        .padding(.leading, isMe ? 0 : edgeInset)
                    if !isMe { Spacer(minLength: 0) }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            }

            if isExpanded {
                HStack(spacing: 6) {
                    if let createdAt {
                        Text(Self.formatted(createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isMe, let status {
                        StatusIconView(state: status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                .padding(.horizontal, edgeInset)
                .padding(.leading,  isMe ? 0 : edgeInset)
                .padding(.trailing, isMe ? edgeInset : 0)
                .transition(.opacity.combined(with: .move(edge: isMe ? .trailing : .leading)))
            }
        }
        .padding(.vertical, verticalSpacing)
        .contextMenu {
            if hasText {
                Button(action: copyText) { Label("Copy", systemImage: "doc.on.doc") }
            }
            Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func attachmentView(for media: MessageModel.Media) -> some View {
        switch media.kind {
        case .audio:
            AudioAttachmentView(media: media,
                                isPending: isMe && isSending,
                                isOutgoing: isMe)
                .allowsHitTesting(!(isMe && isSending))
        case .image, .video:
            MediaAttachmentView(media: media, isPending: isMe && isSending)
                .onTapGesture {
                    guard !(isMe && isSending) else { return }
                    onAttachmentTap(media)
                    onTap()
                }
                .allowsHitTesting(!(isMe && isSending))
        }
    }

    private var bubbleContainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo { replyPreviewView(replyTo) }
            if hasText {
                Text(text)
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(isMe ? Color.accentColor : Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func replyPreviewView(_ preview: MessageModel.ReplyPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(isMe ? Color.white.opacity(0.75) : Color.secondary)
            Text(preview.summary)
                .font(.subheadline)
                .foregroundStyle(isMe ? Color.white : Color.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isMe ? Color.white.opacity(0.18) : Color(.tertiarySystemFill))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onReplyPreviewTap)
    }

    private func copyText() {
        let value = trimmedText.isEmpty ? text : trimmedText
        UIPasteboard.general.string = value
    }

    private var accessibilityLabel: String {
        var components: [String] = []
        if !media.isEmpty {
            let counts = media.reduce(into: [MessageModel.Media.Kind: Int]()) { partial, item in
                partial[item.kind, default: 0] += 1
            }
            let descriptions = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, count in
                let label: String
                switch kind {
                case .image: label = "Photo"
                case .video: label = "Video"
                case .audio: label = "Voice message"
                }
                return count > 1 ? "\(count) \(label)s" : label
            }
            components.append(descriptions.joined(separator: ", "))
        }
        if !trimmedText.isEmpty { components.append(isMe ? "Your message" : "Message") }
        if let replyTo { components.append("Reply to \(replyTo.summary)") }
        if components.isEmpty { components.append(isMe ? "Your message" : "Message") }
        var base = components.joined(separator: ", ")
        if let createdAt { base += ", sent \(Self.fullAccessLabel.string(from: createdAt))" }
        return base
    }

    // MARK: - Formatting

    static func formatted(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)

        if seconds < 24 * 3600 {
            return timeOnly.string(from: date)
        } else if seconds < 7 * 24 * 3600 {
            return weekdayTime.string(from: date)
        } else if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDayTime.string(from: date)
        } else {
            return fullDateTime.string(from: date)
        }
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE, jm")
        return f
    }()

    private static let monthDayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("d MMM, jm")
        return f
    }()

    private static let fullDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy, jm")
        return f
    }()

    private static let fullAccessLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()
}

private struct MediaAttachmentView: View {
    let media: MessageModel.Media
    let isPending: Bool

    @State private var remoteImage: UIImage?
    @State private var isLoadingRemote = false
    @State private var remoteLoadFailed = false

    private var displaySize: CGSize {
        let maxDimension: CGFloat = 250
        guard
            let width = media.width,
            let height = media.height,
            width > 0,
            height > 0
        else {
            return CGSize(width: maxDimension, height: maxDimension)
        }

        var displayWidth = min(maxDimension, CGFloat(width))
        let ratio = CGFloat(height / width)
        var displayHeight = displayWidth * ratio

        if displayHeight > maxDimension {
            displayHeight = maxDimension
            displayWidth = displayHeight / ratio
        }

        return CGSize(width: max(displayWidth, 120), height: max(displayHeight, 120))
    }

    private var imageData: Data? {
        if let data = media.localData { return data }
        if let data = media.localThumbnailData { return data }
        return nil
    }

    private var imageURL: URL? {
        if media.kind == .image, let urlString = media.url {
            return URL(string: urlString)
        }
        if media.kind == .video, let urlString = media.thumbnailURL ?? media.url {
            return URL(string: urlString)
        }
        return nil
    }

    private var resolvedImage: UIImage? {
        if let data = imageData, let localImage = UIImage(data: data) {
            return localImage
        }
        return remoteImage
    }

    var body: some View {
        ZStack {
            attachmentSurface

            if isPending {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .task(id: imageURL) {
            await loadRemoteImage()
        }
    }

    private var attachmentSurface: some View {
        ZStack(alignment: .bottomTrailing) {
            baseImage

            if media.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .padding(10)
            }
        }
    }

    private var baseImage: some View {
        Group {
            if let image = resolvedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay(
                Group {
                    if isLoadingRemote {
                        ProgressView().progressViewStyle(.circular)
                    } else if remoteLoadFailed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
            )
    }

    private func loadRemoteImage() async {
        if imageData != nil {
            await MainActor.run {
                remoteImage = nil
                isLoadingRemote = false
                remoteLoadFailed = false
            }
            return
        }

        guard let url = imageURL else {
            await MainActor.run {
                remoteImage = nil
                isLoadingRemote = false
                remoteLoadFailed = false
            }
            return
        }

        if let cached = await AttachmentDataLoader.shared.cachedData(for: url), !Task.isCancelled {
            if let image = UIImage(data: cached) {
                await MainActor.run {
                    remoteImage = image
                    isLoadingRemote = false
                    remoteLoadFailed = false
                }
                return
            }
        }

        await MainActor.run {
            isLoadingRemote = true
            remoteLoadFailed = false
        }

        do {
            let data = try await AttachmentDataLoader.shared.data(for: url)
            if Task.isCancelled { return }
            if let image = UIImage(data: data) {
                await MainActor.run {
                    remoteImage = image
                    isLoadingRemote = false
                    remoteLoadFailed = false
                }
            } else {
                await MainActor.run {
                    remoteLoadFailed = true
                    isLoadingRemote = false
                }
            }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run {
                remoteLoadFailed = true
                isLoadingRemote = false
            }
        }
    }
}

private struct AudioAttachmentView: View {
    let media: MessageModel.Media
    let isPending: Bool
    let isOutgoing: Bool

    @StateObject private var player = AudioAttachmentPlayer()

    private var backgroundColor: Color { isOutgoing ? Color.accentColor : Color(.secondarySystemFill) }
    private var primaryTextColor: Color { isOutgoing ? Color.white : Color.primary }
    private var secondaryTextColor: Color { isOutgoing ? Color.white.opacity(0.75) : Color.secondary }
    private var controlBackground: Color { isOutgoing ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.15) }

    private var identifier: String {
        if let path = media.localFilePath { return "path:\(path)" }
        if let url = media.url { return "url:\(url)" }
        if let data = media.localData { return "data:\(data.count)-\(media.duration ?? 0)" }
        return "audio:\(UUID().uuidString)"
    }

    private var durationText: String {
        guard player.duration > 0 else { return "--:--" }
        return Self.format(player.duration)
    }

    private var progressText: String {
        guard player.duration > 0 else { return "--:--" }
        let current = min(max(player.currentTime, 0), player.duration)
        return Self.format(current)
    }

    private var statusText: String {
        if let error = player.error { return error }
        if player.isLoading { return "Loading…" }
        if player.duration > 0 { return player.isPlaying ? "\(progressText) / \(durationText)" : durationText }
        return "Voice message"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: player.togglePlayback) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(primaryTextColor)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(controlBackground))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPending || player.isLoading || player.error != nil)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice message")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(primaryTextColor)

                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(player.error == nil ? secondaryTextColor : Color.red)
                    }

                    Spacer()

                    if player.isLoading {
                        ProgressView().progressViewStyle(.circular).tint(primaryTextColor)
                    } else if player.error == nil {
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(primaryTextColor.opacity(isOutgoing ? 0.8 : 0.6))
                    }
                }

                if player.error == nil {
                    ProgressView(value: player.duration > 0 ? player.progress : 0)
                        .progressViewStyle(.linear)
                        .tint(isOutgoing ? Color.white.opacity(0.85) : Color.accentColor)
                        .background(Color.white.opacity(isOutgoing ? 0.18 : 0.05))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)

            if isPending {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                ProgressView().progressViewStyle(.circular).tint(.white)
            }
        }
        .task(id: identifier) { player.configure(with: media, identifier: identifier) }
        .onDisappear { player.teardown() }
    }

    private static func format(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(round(value)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
private final class AudioAttachmentPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var identifier: String?

    func configure(with media: MessageModel.Media, identifier: String) {
        if identifier == self.identifier { return }
        self.identifier = identifier
        cancelLoading()
        stopPlayback(releaseSession: true)
        error = nil
        progress = 0
        currentTime = 0
        duration = media.duration ?? 0
        isLoading = true

        loadTask = Task {
            if let data = media.localData, !data.isEmpty {
                await MainActor.run { self.setupPlayer(with: data, hintDuration: media.duration) }
                return
            }

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

            guard let urlString = media.url, let url = URL(string: urlString) else {
                await MainActor.run {
                    self.isLoading = false
                    self.error = "Audio unavailable."
                }
                return
            }

            do {
                let data = try await AttachmentDataLoader.shared.data(for: url)
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

    func teardown() {
        cancelLoading()
        stopPlayback(releaseSession: true)
        identifier = nil
    }

    // MARK: - Internal helpers

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
        if !isLoading {
            currentTime = 0
            progress = 0
        }
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

/// Spinner / ticks (shown only when expanded)
private struct StatusIconView: View {
    let state: DeliveryState

    var body: some View {
        switch state {
        case .pending:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .delivered:
            ZStack {
                Image(systemName: "checkmark").font(.caption2).offset(x: -3)
                Image(systemName: "checkmark").font(.caption2).offset(x: 3)
            }
            .foregroundStyle(.secondary)
        case .read:
            ZStack {
                Image(systemName: "checkmark").font(.caption2).offset(x: -3)
                Image(systemName: "checkmark").font(.caption2).offset(x: 3)
            }
            .foregroundStyle(Color.blue)
        }
    }
}

// MARK: - Lightweight cache for remote media

private actor AttachmentDataLoader {
    static let shared = AttachmentDataLoader()
    private var cache: [URL: Data] = [:]

    func cachedData(for url: URL) -> Data? { cache[url] }

    func data(for url: URL) async throws -> Data {
        if let cached = cache[url] { return cached }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 50 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        cache[url] = data
        return data
    }
}
