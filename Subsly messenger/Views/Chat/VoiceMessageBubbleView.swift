import SwiftUI

@MainActor
struct VoiceMessageBubbleView: View {
    let messageId: String
    let isMe: Bool
    let createdAt: Date?
    let isExpanded: Bool
    let status: DeliveryState?
    let onTap: () -> Void
    let audioURL: URL?
    let duration: TimeInterval?
    let waveform: [Double]

    @StateObject private var playback = VoiceMessagePlaybackController()

    private let edgeInset: CGFloat = 10
    private let verticalSpacing: CGFloat = 2

    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 0) {
                if isMe { Spacer(minLength: 0) }

                bubble
                    .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
                    .padding(.trailing, isMe ? edgeInset : 0)
                    .padding(.leading, isMe ? 0 : edgeInset)

                if !isMe { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            if isExpanded {
                HStack(spacing: 6) {
                    if let createdAt {
                        Text(MessageBubbleView.formatted(createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isMe, let status {
                        StatusIconView(state: status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                .padding(.horizontal, edgeInset)
                .padding(.leading, isMe ? 0 : edgeInset)
                .padding(.trailing, isMe ? edgeInset : 0)
                .transition(.opacity.combined(with: .move(edge: isMe ? .trailing : .leading)))
            }
        }
        .padding(.vertical, verticalSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Tap to show message timestamp. Use the play button to listen or pause.")
        .accessibilityAddTraits(.isButton)
        .onDisappear { playback.stop() }
    }

    @ViewBuilder
    private var bubble: some View {
        if let audioURL {
            bubbleBody(url: audioURL)
        } else {
            fallbackBubble
        }
    }

    private var fallbackBubble: some View {
        Text("Playback unavailable")
            .font(.subheadline)
            .foregroundStyle(isMe ? Color.white.opacity(0.8) : Color.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func bubbleBody(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: { togglePlayback(url: url) }) {
                    ZStack {
                        Circle()
                            .fill(controlBackground)
                            .frame(width: 44, height: 44)
                        if playback.isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(controlTint)
                        } else {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(controlTint)
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    waveformView
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(isMe ? Color.white.opacity(0.85) : .secondary)
                }
            }
            if let error = playback.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(isMe ? Color.white.opacity(0.85) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var bubbleBackground: Color {
        isMe ? Color.accentColor : Color(.secondarySystemFill)
    }

    private var controlBackground: Color {
        isMe ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.14)
    }

    private var controlTint: Color {
        isMe ? .white : .accentColor
    }

    private var progressTrackColor: Color {
        isMe ? Color.white.opacity(0.25) : Color.primary.opacity(0.12)
    }

    private var progressFillColor: Color {
        isMe ? Color.white : Color.accentColor
    }

    private var waveformView: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(progressTrackColor)
                Capsule()
                    .fill(progressFillColor)
                    .frame(width: proxy.size.width * playback.progress)
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.12), value: playback.progress)
        .accessibilityHidden(true)
    }

    private func togglePlayback(url: URL) {
        playback.togglePlayback(for: url, cacheKey: messageId, expectedDuration: duration)
    }

    private var timeLabel: String {
        if playback.isPlaying || playback.isPaused {
            return "\(playback.displayCurrentTime) / \(playback.displayDuration)"
        }
        if playback.duration > 0 {
            return playback.displayDuration
        }
        return formatted(duration)
    }

    private func formatted(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, !value.isNaN else { return "0:00" }
        let total = Int(round(value))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var accessibilityLabel: String {
        var base = isMe ? "Your voice message" : "Voice message"
        if let createdAt {
            base += ", sent \(MessageBubbleView.formatted(createdAt))"
        }
        base += ". Duration \(timeLabel)."
        if playback.errorMessage != nil {
            base += " Playback unavailable."
        }
        return base
    }
}
