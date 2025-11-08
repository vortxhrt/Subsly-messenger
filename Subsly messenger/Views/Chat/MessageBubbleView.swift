import SwiftUI
import UIKit

enum DeliveryState {
    case pending   // sending (show spinner)
    case sent      // on server, not yet delivered
    case delivered // delivered to other device
    case read      // read by other device
}

struct MessageBubbleView: View {
    let text: String
    let media: MessageModel.Media?
    let isMe: Bool
    let createdAt: Date?
    let replyTo: MessageModel.ReplyPreview?
    let isExpanded: Bool
    let status: DeliveryState?       // only used for outgoing (isMe == true)
    let onTap: () -> Void
    var onAttachmentTap: (MessageModel.Media) -> Void = { _ in }
    var onReply: () -> Void = {}
    var onReplyPreviewTap: () -> Void = {}

    // Small margin from the screen edge (messages only)
    private let edgeInset: CGFloat = 10
    private let verticalSpacing: CGFloat = 2

    // ~75% of screen like iMessage
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasText: Bool {
        !trimmedText.isEmpty
    }

    private var hasBubbleContent: Bool {
        hasText || replyTo != nil
    }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
            if let media {
                HStack(spacing: 0) {
                    if isMe { Spacer(minLength: 0) }
                    MediaAttachmentView(media: media)
                        .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
                        .padding(.leading, isMe ? 0 : edgeInset)
                        .padding(.trailing, isMe ? edgeInset : 0)
                        .onTapGesture {
                            onAttachmentTap(media)
                            onTap()
                        }
                    if !isMe { Spacer(minLength: 0) }
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
                Button(action: copyText) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    private var bubbleContainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo {
                replyPreviewView(replyTo)
            }
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
        if let media {
            components.append(media.kind == .video ? "Video" : "Photo")
        }
        if !trimmedText.isEmpty {
            components.append(isMe ? "Your message" : "Message")
        }
        if let replyTo {
            components.append("Reply to \(replyTo.summary)")
        }
        if components.isEmpty {
            components.append(isMe ? "Your message" : "Message")
        }
        var base = components.joined(separator: ", ")
        if let createdAt {
            base += ", sent \(Self.fullAccessLabel.string(from: createdAt))"
        }
        return base
    }

    // MARK: - Formatting (rules specified)

    /// - <24h: time only
    /// - <7d : weekday + time
    /// - same year: day month + time
    /// - else: day month year + time
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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            placeholder
                        case .empty:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
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

            if media.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .padding(10)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay(
                ProgressView()
                    .progressViewStyle(.circular)
            )
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
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .offset(x: -3)
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .offset(x: 3)
            }
            .foregroundStyle(.secondary)
        case .read:
            ZStack {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .offset(x: -3)
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .offset(x: 3)
            }
            .foregroundStyle(Color.blue)
        }
    }
}
