import SwiftUI
import PhotosUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var usersStore: UsersStore

    let currentUser: AppUser

    @State private var workingUser: AppUser
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    init(currentUser: AppUser) {
        self.currentUser = currentUser
        _workingUser = State(initialValue: currentUser)
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
        .onChange(of: session.currentUser) { _, newValue in
            if let updated = newValue { workingUser = updated }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await processSelection(newItem) }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            VStack(spacing: 16) {
                AvatarView(
                    avatarURL: workingUser.avatarURL,
                    name: displayName,
                    size: 96
                )
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.headline)
                    Text("@\(workingUser.handle)")
                        .foregroundStyle(.secondary)
                }

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Change Photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isUploading)

                if isUploading {
                    ProgressView("Updating photo…")
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.vertical, 4)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                do {
                    try AuthService.shared.signOut()
                } catch {
                    print("Sign out failed:", error)
                }
            } label: {
                Text("Sign Out")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var displayName: String {
        let trimmed = workingUser.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? workingUser.handle : trimmed
    }

    private func processSelection(_ item: PhotosPickerItem) async {
        let uid: String
        if let current = session.currentUser, let id = current.id {
            uid = id
        } else if let id = workingUser.id {
            uid = id
        } else {
            return
        }
        isUploading = true
        statusMessage = nil
        statusIsError = false

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw AvatarServiceError.imageEncodingFailed
            }

            let prepared = resizedImage(from: image)
            let urlString = try await AvatarService.shared.upload(image: prepared, for: uid)
            try await UserService.shared.updateAvatarURL(uid: uid, urlString: urlString)

            await MainActor.run {
                workingUser.avatarURL = urlString
                var updatedUser = workingUser
                updatedUser.id = uid
                session.currentUser = updatedUser
                usersStore.upsert(updatedUser)
                statusMessage = "Profile photo updated."
                statusIsError = false
            }
        } catch {
            await MainActor.run {
                if let avatarError = error as? AvatarServiceError {
                    statusMessage = "Couldn't process the selected image."
                } else {
                    statusMessage = error.localizedDescription
                }
                statusIsError = true
            }
        }

        await MainActor.run {
            isUploading = false
            pickerItem = nil
        }
    }

    private func resizedImage(from image: UIImage, maxDimension: CGFloat = 720) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
