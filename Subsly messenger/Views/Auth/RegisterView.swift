import SwiftUI

struct RegisterView: View {
    var prefilledEmail: String? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Create account").font(.title).bold()

                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureField("Confirm password", text: $confirm)
                    .textContentType(.newPassword)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let e = errorText {
                    Text(e).foregroundStyle(.red).font(.footnote)
                }

                Button {
                    Task {
                        guard password == confirm else {
                            errorText = "Passwords don’t match"; return
                        }
                        do {
                            try await AuthService.shared.signUp(email: email, password: password)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Text("Create account")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer()
            }
            .padding()
            .onAppear { if let e = prefilledEmail { email = e } }
        }
    }
}
