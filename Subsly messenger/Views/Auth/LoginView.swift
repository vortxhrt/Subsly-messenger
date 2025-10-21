import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Subsly")
                    .font(.largeTitle)
                    .bold()

                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)          // <- fixed here
                    .textContentType(.emailAddress)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let e = errorText {
                    Text(e)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Button {
                    Task {
                        do {
                            try await AuthService.shared.signIn(email: email, password: password)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                NavigationLink("Create an account") {
                    RegisterView(prefilledEmail: email)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
    }
}
