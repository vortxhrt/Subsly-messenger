import SwiftUI

struct AvatarView: View {
    struct OnlineStatus {
        let isOnline: Bool
        let isVisible: Bool
    }

    struct StatusIndicatorStyle {
        let scale: CGFloat
        let minimumSize: CGFloat
        let strokeRatio: CGFloat

        static let standard = StatusIndicatorStyle(scale: 0.32, minimumSize: 12, strokeRatio: 0.15)
        static let compact = StatusIndicatorStyle(scale: 0.16, minimumSize: 6, strokeRatio: 0.2)
    }

    let avatarURL: String?
    let name: String
    var size: CGFloat = 40
    var status: OnlineStatus? = nil
    var statusIndicatorStyle: StatusIndicatorStyle = .standard

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

    private var indicatorSize: CGFloat {
        max(statusIndicatorStyle.minimumSize, size * statusIndicatorStyle.scale)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarContent
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color.black.opacity(0.04), lineWidth: 1)
                )
                .accessibilityHidden(true)

            if let status, status.isVisible, status.isOnline {
                Circle()
                    .fill(Color.green)
                    .frame(width: indicatorSize, height: indicatorSize)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: max(1, indicatorSize * statusIndicatorStyle.strokeRatio))
                    )
                    .offset(x: indicatorSize * statusIndicatorStyle.strokeRatio, y: indicatorSize * statusIndicatorStyle.strokeRatio)
                    .accessibilityLabel("Online")
            }
        }
    }

    private var avatarContent: some View {
        Group {
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
            AvatarView(avatarURL: nil, name: "Taylor Swift", size: 48, status: .init(isOnline: true, isVisible: true))
            AvatarView(avatarURL: nil, name: "A", size: 48, status: .init(isOnline: false, isVisible: true))
            AvatarView(avatarURL: "https://example.com/avatar.png", name: "Sam Sample", size: 48, status: nil)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
