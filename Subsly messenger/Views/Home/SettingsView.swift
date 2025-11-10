import SwiftUI
import PhotosUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var usersStore: UsersStore

    let currentUser: AppUser
    private let onBackToChats: (() -> Void)?

    @State private var workingUser: AppUser
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var isSavingProfile = false
    @State private var isUpdatingPresence = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var bioText: String
    @State private var shareOnlineStatus: Bool

    init(currentUser: AppUser, onBackToChats: (() -> Void)? = nil) {
        self.currentUser = currentUser
        self.onBackToChats = onBackToChats
        _workingUser = State(initialValue: currentUser)
        _bioText = State(initialValue: currentUser.bio ?? "")
        _shareOnlineStatus = State(initialValue: currentUser.shareOnlineStatus)
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                presenceSection
                aboutSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .toolbar {
                if let onBackToChats {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            onBackToChats()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.backward")
                                Text("Chats")
                            }
                        }
                        .accessibilityLabel("Back to Chats")
                    }
                }
            }
        }
        .onChange(of: session.currentUser) { _, newValue in
            if let updated = newValue {
                workingUser = updated
                bioText = updated.bio ?? ""
                shareOnlineStatus = updated.shareOnlineStatus
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await processSelection(newItem) }
        }
        .onChange(of: bioText) { _, newValue in
            enforceBioLimit(for: newValue)
        }
        .onChange(of: shareOnlineStatus) { _, newValue in
            guard workingUser.shareOnlineStatus != newValue else { return }
            Task { await updatePresencePreference(to: newValue) }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            VStack(spacing: 16) {
                AvatarView(
                    avatarURL: workingUser.avatarURL,
                    name: displayName,
                    size: 96,
                    status: AvatarView.OnlineStatus(
                        isOnline: workingUser.isOnline,
                        isVisible: workingUser.shareOnlineStatus
                    )
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

    private var presenceSection: some View {
        Section("Presence") {
            Toggle(isOn: $shareOnlineStatus) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share Online Status")
                    Text("Allow others to see when you're online.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .disabled(isUpdatingPresence)

            if isUpdatingPresence {
                ProgressView("Updating status…")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bio")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Share a few words about yourself")
                            .foregroundStyle(Color.secondary)
                            .padding(.top, 8)
                            .padding(.horizontal, 6)
                    }

                    TextEditor(text: $bioText)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.quaternaryLabel))
                        )
                        .padding(.horizontal, -4)
                        .padding(.vertical, -4)
                }

                HStack {
                    Spacer()
                    Text("\(bioText.count)/\(bioLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: { Task { await saveProfile() } }) {
                    if isSavingProfile {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Save Profile")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!profileHasChanges || isSavingProfile)
            }
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

    private var bioLimit: Int { 160 }

    private var profileHasChanges: Bool {
        let trimmedBio = bioText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBio = workingUser.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedBio != currentBio
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

    private func enforceBioLimit(for value: String) {
        if value.count > bioLimit {
            bioText = String(value.prefix(bioLimit))
        }
    }

    private func saveProfile() async {
        let uid: String
        if let current = session.currentUser, let id = current.id {
            uid = id
        } else if let id = workingUser.id {
            uid = id
        } else {
            return
        }

        let trimmedBio = bioText.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
            isSavingProfile = true
            statusMessage = nil
            statusIsError = false
        }

        do {
            try await UserService.shared.updateProfile(
                uid: uid,
                displayName: workingUser.displayName,
                bio: trimmedBio.isEmpty ? nil : trimmedBio
            )

            await MainActor.run {
                workingUser.bio = trimmedBio.isEmpty ? nil : trimmedBio
                bioText = trimmedBio
                var updatedUser = workingUser
                updatedUser.id = uid
                session.currentUser = updatedUser
                usersStore.upsert(updatedUser)
                statusMessage = "Profile updated."
                statusIsError = false
            }
        } catch {
            await MainActor.run {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }

        await MainActor.run { isSavingProfile = false }
    }

    private func updatePresencePreference(to newValue: Bool) async {
        let uid: String
        if let current = session.currentUser, let id = current.id {
            uid = id
        } else if let id = workingUser.id {
            uid = id
        } else {
            return
        }

        await MainActor.run {
            isUpdatingPresence = true
            statusMessage = nil
            statusIsError = false
        }

        do {
            try await UserService.shared.setShareOnlineStatus(uid: uid, isEnabled: newValue)
            if newValue {
                await session.setPresence(isOnline: true)
            }

            await MainActor.run {
                workingUser.shareOnlineStatus = newValue
                if !newValue {
                    workingUser.isOnline = false
                } else {
                    workingUser.isOnline = session.currentUser?.isOnline ?? true
                }
                shareOnlineStatus = newValue
                var updated = workingUser
                updated.id = uid
                session.currentUser = updated
                usersStore.upsert(updated)
                statusMessage = newValue ? "Online status sharing enabled." : "Online status sharing disabled."
                statusIsError = false
            }
        } catch {
            await MainActor.run {
                statusMessage = error.localizedDescription
                statusIsError = true
                shareOnlineStatus = workingUser.shareOnlineStatus
            }
        }

        await MainActor.run { isUpdatingPresence = false }
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
