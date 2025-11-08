import SwiftUI
import PhotosUI
import UIKit

struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [PendingAttachment]
    @Binding var replyPreview: MessageModel.ReplyPreview?
    var canSend: Bool
    var isProcessingAttachment: Bool
    var onSend: () -> Void
    var onTyping: (Bool) -> Void = { _ in }   // keep for typing indicator
    var onPickAttachments: ([PhotosPickerItem]) -> Void
    var onRemoveAttachment: (PendingAttachment) -> Void
    var onCancelReply: () -> Void = {}

    @FocusState private var isFocused: Bool

    // Style
    private let sideGap: CGFloat = 10          // same side margin as bubbles
    private let cornerRadius: CGFloat = 18
    private let innerH: CGFloat = 12
    private let innerV: CGFloat = 9
    private let maxLines: Int = 6
    private let attachmentLimit: Int = 20

    @State private var typingDebounceTask: Task<Void, Never>?
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyPreview {
                ReplyComposerPreview(preview: replyPreview, onCancel: onCancelReply)
                    .padding(.horizontal, sideGap)
            }

            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentPreviewView(
                            attachment: attachment,
                            onRemove: { onRemoveAttachment(attachment) }
                        )
                    }

                    HStack {
                        Text("\(attachments.count) / \(attachmentLimit) attachments selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isProcessingAttachment {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Processing…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, sideGap)
            } else if isProcessingAttachment {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Processing attachments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, sideGap)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: attachmentLimit,
                             matching: .any(of: [.images, .videos])) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .padding(.horizontal, innerH)
                        .padding(.vertical, innerV)
                        .background(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color(.secondarySystemFill))
                        )
                }
                .disabled(isProcessingAttachment || attachments.count >= attachmentLimit)
                .onChange(of: pickerItems) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    onPickAttachments(newValue)
                    pickerItems = []
                }

                TextField("Message...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...maxLines)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(false)
                    .focused($isFocused)
                    // inner padding prevents any corner clipping
                    .padding(.vertical, innerV)
                    .padding(.horizontal, innerH)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(.secondarySystemFill))
                    )
                    // typing signal with debounce
                    .onChange(of: text) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        onTyping(!trimmed.isEmpty)

                        typingDebounceTask?.cancel()
                        typingDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000) // ~1.2s idle
                            if Task.isCancelled { return }
                            onTyping(false)
                        }
                    }

                Button(action: sendTapped) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .padding(.horizontal, innerH)
                        .padding(.vertical, innerV)
                        .background(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .disabled(!canSend)
                .opacity(canSend ? 1.0 : 0.4)
                .accessibilityLabel("Send")
            }
            // Only the composer content gets the side gap; nothing else moves
            .padding(.horizontal, sideGap)
            .padding(.vertical, 8)
        }
    }

    private func sendTapped() {
        guard canSend else { return }
        onTyping(false)
        onSend()
        isFocused = true   // keep keyboard up for fast sends
    }
}

private struct AttachmentPreviewView: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    private var previewImage: UIImage? {
        guard let data = attachment.previewData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let image = previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08))
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
                }

                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.isVideo ? "Video" : "Photo")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
    }
}

private struct ReplyComposerPreview: View {
    let preview: MessageModel.ReplyPreview
    let onCancel: () -> Void

    private var iconName: String? {
        guard preview.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return nil
        }
        switch preview.mediaKind {
        case .some(.image):
            return "photo"
        case .some(.video):
            return "video"
        default:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(preview.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if let iconName {
                    Label(preview.summary, systemImage: iconName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(2)
                } else {
                    Text(preview.summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
