import SwiftUI
import PhotosUI
import UIKit

struct ComposerView: View {
    @Binding var text: String
    @Binding var attachment: PendingAttachment?
    var canSend: Bool
    var isProcessingAttachment: Bool
    var onSend: () -> Void
    var onTyping: (Bool) -> Void = { _ in }   // keep for typing indicator
    var onPickAttachment: (PhotosPickerItem) -> Void
    var onRemoveAttachment: () -> Void

    @FocusState private var isFocused: Bool

    // Style
    private let sideGap: CGFloat = 10          // same side margin as bubbles
    private let cornerRadius: CGFloat = 18
    private let innerH: CGFloat = 12
    private let innerV: CGFloat = 9
    private let maxLines: Int = 6

    @State private var typingDebounceTask: Task<Void, Never>?
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachment {
                AttachmentPreviewView(
                    attachment: attachment,
                    isProcessing: isProcessingAttachment,
                    onRemove: onRemoveAttachment
                )
                .padding(.horizontal, sideGap)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
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
                .disabled(isProcessingAttachment)
                .onChange(of: pickerItem) { _, newValue in
                    guard let newValue else { return }
                    onPickAttachment(newValue)
                    pickerItem = nil
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
    let isProcessing: Bool
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
                if isProcessing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Processing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
            .disabled(isProcessing)
            .opacity(isProcessing ? 0.5 : 1.0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
    }
}
