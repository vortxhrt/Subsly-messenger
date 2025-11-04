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
                                    size: 40
                                )

                                VStack(alignment: .leading) {
                                    Text("@\(user.handle)").bold()
                                    Text(displayName(for: user))
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
                let u = AppUser(
                    id: doc.documentID,
                    handle: handle,
                    displayName: display,
                    avatarURL: avatar,
                    bio: bio,
                    createdAt: ts?.dateValue()
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
