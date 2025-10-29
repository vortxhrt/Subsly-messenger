import SwiftUI

enum DeliveryState {
    case pending   // sending (show spinner)
    case sent      // on server, not yet delivered
    case delivered // delivered to other device
    case read      // read by other device
}

struct MessageBubbleView: View {
    let text: String
    let isMe: Bool
    let createdAt: Date?
    let isExpanded: Bool
    let status: DeliveryState?       // only used for outgoing (isMe == true)
    let onTap: () -> Void

    // Small margin from the screen edge (messages only)
    private let edgeInset: CGFloat = 10
    private let verticalSpacing: CGFloat = 2

    // ~75% of screen like iMessage
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 0) {
                if isMe {
                    Spacer(minLength: 0)

                    Text(text)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .foregroundStyle(.white)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
                        .padding(.trailing, edgeInset)   // small right gap
                } else {
                    Text(text)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .foregroundStyle(.primary)
                        .background(Color(.secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                        .padding(.leading, edgeInset)    // small left gap

                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            // Timestamp + ticks shown only when expanded, then auto-hide (controlled by parent).
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
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var base = isMe ? "Your message" : "Message"
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
