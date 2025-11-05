import SwiftUI

struct AvatarView: View {
    let avatarURL: String?
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let components = name
            .split(separator: " ")
            .filter { !$0.isEmpty }
        if components.isEmpty {
            return "?"
        }
        let first = components.first?.prefix(1) ?? "?"
        let last = components.dropFirst().first?.prefix(1)
        if let last, !last.isEmpty {
            return (String(first) + String(last)).uppercased()
        }
        return String(first).uppercased()
    }

    private var remoteURL: URL? {
        guard let avatarURL, let url = URL(string: avatarURL) else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            if let url = remoteURL {
                CachedAsyncImage(url: url) { phase in
                    if let image = phase.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if phase.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color(.systemGray))
            )
    }
}

struct AvatarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            AvatarView(avatarURL: nil, name: "Taylor Swift", size: 48)
            AvatarView(avatarURL: nil, name: "A", size: 48)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
