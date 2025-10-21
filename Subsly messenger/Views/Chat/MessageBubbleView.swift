import SwiftUI

struct MessageBubbleView: View {
    let text: String
    let isMe: Bool

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 48) }    // push my messages to the right

            Text(text)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .foregroundStyle(isMe ? .white : .primary)
                .background(isMe ? Color.accentColor : Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading) // bubble max width

            if !isMe { Spacer(minLength: 48) }   // push other messages to the left
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }
}
