import SwiftUI

/// Left-aligned bubble showing a 3-dot typing animation (like incoming message)
struct TypingIndicatorView: View {
    private let edgeInset: CGFloat = 10
    private let cornerRadius: CGFloat = 18

    @State private var animate = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 8, height: 8)
                        .opacity(animate ? 1.0 : 0.35)
                        .scaleEffect(animate ? 1.0 : 0.75)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.15),
                            value: animate
                        )
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemFill))
            )

            Spacer(minLength: 0)
        }
        .padding(.leading, edgeInset) // small gap like incoming messages
        .padding(.vertical, 2)
        .onAppear { animate = true }
    }
}
