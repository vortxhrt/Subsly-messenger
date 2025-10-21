import SwiftUI

struct MessageBubbleView: View {
    let text: String
    let isMe: Bool

    // Small margin from the screen edge (messages only)
    private let edgeInset: CGFloat = 10
    private let verticalSpacing: CGFloat = 2

    // ~75% of screen like iMessage
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.75
    }

    var body: some View {
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
                    .padding(.trailing, edgeInset)   // <-- small right gap

            } else {
                Text(text)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .padding(.leading, edgeInset)    // <-- small left gap

                Spacer(minLength: 0)
            }
        }
        // No horizontal padding here; margins are per-side above.
        .padding(.vertical, verticalSpacing)
    }
}
