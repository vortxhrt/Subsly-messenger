import SwiftUI

struct AvatarView: View {
    let avatarURL: String?
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let components = name
            .split(separator: " ")
            .filter { !$0.isEmpty }

        guard let firstComponent = components.first else {
            return "?"
        }

        let firstInitial = String(firstComponent.prefix(1)).uppercased()

        guard let secondComponent = components.dropFirst().first else {
            return firstInitial
        }

        let secondInitial = String(secondComponent.prefix(1)).uppercased()
        return firstInitial + secondInitial
    }

    private var remoteURL: URL? {
        guard let avatarURL = avatarURL,
              let url = URL(string: avatarURL),
              !avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return url
    }

    var body: some View {
        ZStack {
            if let url = remoteURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    case .loading:
                        ProgressView()
                            .progressViewStyle(.circular)
                    case .failure, .empty:
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
                    .foregroundColor(Color(.systemGray))
            )
    }
}

struct AvatarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            AvatarView(avatarURL: nil, name: "Taylor Swift", size: 48)
            AvatarView(avatarURL: nil, name: "A", size: 48)
            AvatarView(avatarURL: "https://example.com/avatar.png", name: "Sam Sample", size: 48)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
