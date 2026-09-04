import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var isSubmitting = false
    @State private var outcome: Outcome?

    /// There is no success case. A sign-up that returns a session emits on the
    /// SDK's auth-state stream, `RootView` swaps to the main tabs, and this
    /// view is torn down before any success message could be read. The one
    /// non-failure outcome worth reporting is a sign-up that succeeds *without*
    /// a session, which happens only if email confirmation is re-enabled on the
    /// project.
    private enum Outcome {
        case awaitingEmailConfirmation
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.newPassword)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                AsyncSubmitButton("Sign Up", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                    await submit()
                }
            }

            if let outcome {
                Section {
                    switch outcome {
                    case .awaitingEmailConfirmation:
                        Text("Account created. Confirm your email address before logging in.")
                            .foregroundStyle(.orange)
                    case .failed(let text):
                        Text(text).foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button("Already have an account? Log In") {
                    dismiss()
                }
            }
        }
        .navigationTitle("Sign Up")
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        outcome = nil

        do {
            let result = try await AuthService().signUp(
                email: email,
                password: password,
                username: username
            )
            // On success with a session, RootView takes over and this is moot.
            outcome = result.hasActiveSession ? nil : .awaitingEmailConfirmation
        } catch {
            outcome = .failed(error.localizedDescription)
        }

        isSubmitting = false
    }
}

#Preview {
    NavigationStack {
        SignUpView()
    }
}
