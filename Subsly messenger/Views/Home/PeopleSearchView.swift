import SwiftUI
import FirebaseFirestore

struct PeopleSearchView: View {
    let currentUser: AppUser

    @State private var query = ""
    @State private var results: [AppUser] = []
    @State private var isSearching = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("Search handle…", text: $query)
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button("Go") { Task { await search() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()

                if isSearching { ProgressView() }

                List {
                    ForEach(results) { user in
                        NavigationLink {
                            ThreadView(currentUser: currentUser, otherUID: user.id ?? "")
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    avatarURL: user.avatarURL,
                                    name: displayName(for: user),
                                    size: 40,
                                    showPresenceIndicator: true,
                                    isOnline: user.isVisiblyOnline
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@\(user.handle)").bold()
                                    Text(displayName(for: user))
                                        .foregroundStyle(.secondary)
                                    Text(statusLine(for: user))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)

                if let e = errorText {
                    Text(e).foregroundStyle(.red).padding(.bottom)
                }
            }
            .navigationTitle("Find People")
        }
        .onSubmit { Task { await search() } }
    }

    private func displayName(for user: AppUser) -> String {
        let trimmed = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.handle : trimmed
    }

    private func statusLine(for user: AppUser) -> String {
        if user.isStatusHidden { return "Offline" }
        if user.isVisiblyOnline { return "Online" }
        if let lastSeen = formattedLastSeen(for: user) {
            return "Last seen \(lastSeen)"
        }
        return "Offline"
    }

    private func formattedLastSeen(for user: AppUser) -> String? {
        guard let description = user.lastSeenDescription() else { return nil }
        let normalized = description.lowercased()
        if normalized.contains("0 seconds") {
            return "just now"
        }
        return description
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        errorText = nil

        do {
            let db = Firestore.firestore()
            let usersCol = db.collection("users")

            let start = q.lowercased()
            let end = start + "\u{f8ff}"

            let snap = try await usersCol
                .whereField("handleLower", isGreaterThanOrEqualTo: start)
                .whereField("handleLower", isLessThanOrEqualTo: end)
                .limit(to: 20)
                .getDocuments()

            var list: [AppUser] = []
            for doc in snap.documents {
                let data = doc.data()
                let handle = data["handle"] as? String ?? ""
                let display = data["displayName"] as? String ?? handle
                let avatar = data["avatarURL"] as? String
                let ts = data["createdAt"] as? Timestamp
                let bio = data["bio"] as? String
                let isOnline = data["isOnline"] as? Bool ?? false
                let lastActive = (data["lastActiveAt"] as? Timestamp)?.dateValue()
                let isStatusHidden = data["isStatusHidden"] as? Bool ?? false
                let u = AppUser(
                    id: doc.documentID,
                    handle: handle,
                    displayName: display,
                    avatarURL: avatar,
                    bio: bio,
                    createdAt: ts?.dateValue(),
                    isOnline: isOnline,
                    lastActiveAt: lastActive,
                    isStatusHidden: isStatusHidden
                )
                if u.id != currentUser.id { list.append(u) }
            }

            await MainActor.run { results = list }
        } catch {
            await MainActor.run { errorText = error.localizedDescription }
        }

        isSearching = false
    }
}
