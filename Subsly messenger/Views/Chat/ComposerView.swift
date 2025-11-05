import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    var onSend: () -> Void
    var onTyping: (Bool) -> Void = { _ in }   // keep for typing indicator

    @FocusState private var isFocused: Bool

    // Style
    private let sideGap: CGFloat = 10          // same side margin as bubbles
    private let cornerRadius: CGFloat = 18
    private let innerH: CGFloat = 12
    private let innerV: CGFloat = 9
    private let maxLines: Int = 6

    @State private var typingDebounceTask: Task<Void, Never>?

    var body: some View {
        // Content only (no full-width background here so nothing shifts)
        HStack(spacing: 8) {
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
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1.0)
            .accessibilityLabel("Send")
        }
        // Only the composer content gets the side gap; nothing else moves
        .padding(.horizontal, sideGap)
        .padding(.vertical, 8)
    }

    private func sendTapped() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onTyping(false)
        onSend()
        isFocused = true   // keep keyboard up for fast sends
    }
}
