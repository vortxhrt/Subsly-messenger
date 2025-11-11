import SwiftUI
import FirebaseAuth

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?
    @State private var isSigningIn = false
    @State private var lastAttemptAt: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Subsly")
                    .font(.largeTitle)
                    .bold()

                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.emailAddress)
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
                    attemptSignIn()
                } label: {
                    Group {
                        if isSigningIn {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        } else {
                            Text("Sign In").frame(maxWidth: .infinity).padding()
                        }
                    }
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isSigningIn)

                NavigationLink("Create an account") {
                    RegisterView(prefilledEmail: email)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
    }

    private func attemptSignIn() {
        guard !isSigningIn else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailValidator.isValid(trimmedEmail) else {
            errorText = "Enter a valid email address."
            return
        }

        guard !password.isEmpty else {
            errorText = "Email and password are required."
            return
        }

        let now = Date()
        if let last = lastAttemptAt, now.timeIntervalSince(last) < 2.5 {
            errorText = "Please wait before trying again."
            return
        }
        lastAttemptAt = now

        isSigningIn = true
        errorText = nil

        Task {
            do {
                try await AuthService.shared.signIn(email: trimmedEmail, password: password)
            } catch {
                await MainActor.run {
                    if let serviceError = error as? AuthServiceError {
                        switch serviceError {
                        case .invalidEmail:
                            errorText = "Enter a valid email address."
                        case .missingAuthenticatedUser:
                            errorText = normalizedMessage(for: error)
                        }
                    } else {
                        errorText = normalizedMessage(for: error)
                    }
                }
            }

            await MainActor.run {
                isSigningIn = false
            }
        }
    }

    private func normalizedMessage(for error: Error) -> String {
        // Works across FirebaseAuth versions: use domain + raw numeric code.
        guard let nsError = error as NSError?,
              (nsError.domain == AuthErrorDomain || nsError.domain == "FIRAuthErrorDomain")
        else {
            return "Unable to sign in. Please double-check your details and try again."
        }

        switch nsError.code {
        case 17009, 17004: // wrongPassword, invalidCredential
            return "The email or password you entered is incorrect."
        case 17010: // tooManyRequests
            return "Sign-in is temporarily blocked due to too many attempts. Please try again later."
        case 17008: // invalidEmail
            return "That email address looks invalid."
        case 17005: // userDisabled
            return "This account has been disabled."
        case 17020: // networkError
            return "Network error. Please check your connection and try again."
        default:
            return "Unable to sign in. Please double-check your details and try again."
        }
    }
}
