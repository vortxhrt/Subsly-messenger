import SwiftUI
import FirebaseAuth

struct EmailVerificationView: View {
    let email: String

    @EnvironmentObject private var session: SessionStore

    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isSending = false
    @State private var isRefreshing = false
    @State private var isSigningOut = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.accentColor)

                    Text("Verify your email")
                        .font(.title2)
                        .bold()

                    Text("We sent a verification link to \(emailDescription). Please verify your address to continue using Subsly Messenger.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button {
                        resendVerification()
                    } label: {
                        if isSending {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Resend verification email")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || !session.canResendVerificationEmail)

                    Button {
                        refreshStatus()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("I’ve verified my email")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)

                    Button {
                        signOut()
                    } label: {
                        if isSigningOut {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Use a different email")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSigningOut)
                }

                if let message = statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Email Verification")
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { EmptyView() } }
        }
    }

    private func resendVerification() {
        guard session.canResendVerificationEmail else {
            statusMessage = "Please wait a bit before requesting another verification email."
            statusIsError = true
            return
        }

        isSending = true
        statusMessage = nil
        statusIsError = false

        Task {
            do {
                try await AuthService.shared.sendVerificationEmail()
                await MainActor.run {
                    statusMessage = "A new verification email was sent to \(emailDescription)."
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "We couldn’t send the verification email. Please try again."
                    statusIsError = true
                }
            }

            await MainActor.run {
                isSending = false
            }
        }
    }

    private func refreshStatus() {
        isRefreshing = true
        statusMessage = nil
        statusIsError = false

        Task {
            do {
                try await AuthService.shared.reloadCurrentUser()
                await session.refreshAuthUser()

                let verified = Auth.auth().currentUser?.isEmailVerified == true

                await MainActor.run {
                    if verified {
                        statusMessage = "Verified! You’re good to go."
                        statusIsError = false
                    } else {
                        statusMessage = "Still not verified. Tap the link in the email, then try again."
                        statusIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = "We couldn’t refresh your status. Please try again."
                    statusIsError = true
                }
            }

            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }

        isSigningOut = true
        statusMessage = nil
        statusIsError = false

        Task {
            do {
                try await AuthService.shared.signOut()
            } catch {
                await MainActor.run {
                    statusMessage = "We couldn’t sign you out. Please try again."
                    statusIsError = true
                    isSigningOut = false
                }
                return
            }

            await MainActor.run {
                isSigningOut = false
            }
        }
    }

    private var emailDescription: String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your email address" : trimmed
    }
}
