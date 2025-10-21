import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .padding(10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
