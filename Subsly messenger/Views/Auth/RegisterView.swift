import SwiftUI
import FirebaseAuth

struct RegisterView: View {
    var prefilledEmail: String? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var errorText: String?
    @State private var isRegistering = false
    @State private var lastAttemptAt: Date?

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
                    attemptRegistration()
                } label: {
                    Text("Create account")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isRegistering)

                Spacer()
            }
            .padding()
            .onAppear { if let e = prefilledEmail { email = e } }
        }
    }

    private func attemptRegistration() {
        guard !isRegistering else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            errorText = "Enter a valid email address."
            return
        }

        guard password == confirm else {
            errorText = "Passwords don’t match."
            return
        }

        guard passwordMeetsStrength(password) else {
            errorText = "Password must be at least 10 characters and include upper, lower, and numeric characters."
            return
        }

        let now = Date()
        if let last = lastAttemptAt, now.timeIntervalSince(last) < 3.0 {
            errorText = "Please wait before trying again."
            return
        }
        lastAttemptAt = now

        isRegistering = true
        errorText = nil

        Task {
            do {
                try await AuthService.shared.signUp(email: trimmedEmail, password: password)
            } catch {
                await MainActor.run {
                    errorText = normalizedMessage(for: error)
                }
            }

            await MainActor.run {
                isRegistering = false
            }
        }
    }

    private func normalizedMessage(for error: Error) -> String {
        if let nsError = error as NSError?, nsError.domain == AuthErrorDomain {
            let authError = AuthErrorCode(_nsError: nsError)
            switch authError.code {
            case .emailAlreadyInUse:
                return "An account with this email already exists."
            case .weakPassword:
                return "Please choose a stronger password before continuing."
            default:
                break
            }
        }
        return "We couldn’t create your account right now. Please try again later."
    }

    private func passwordMeetsStrength(_ password: String) -> Bool {
        guard password.count >= 10 else { return false }
        let uppercase = CharacterSet.uppercaseLetters
        let lowercase = CharacterSet.lowercaseLetters
        let digits = CharacterSet.decimalDigits

        if password.rangeOfCharacter(from: uppercase) == nil { return false }
        if password.rangeOfCharacter(from: lowercase) == nil { return false }
        if password.rangeOfCharacter(from: digits) == nil { return false }

        return true
    }
}
