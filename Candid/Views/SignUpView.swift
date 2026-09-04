import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var isSubmitting = false

    /// Never a success. A sign-up that returns a session emits on the SDK's
    /// auth-state stream, `RootView` swaps to the main tabs, and this view is
    /// torn down before any success message could be read. The one
    /// non-failure outcome worth reporting is a sign-up that succeeds *without*
    /// a session, which happens only if email confirmation is re-enabled on the
    /// project — shown as a notice.
    @State private var message: FormMessage?

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
            } footer: {
                Text("Usernames are \(UsernameRules.minLength)–\(UsernameRules.maxLength) characters: lowercase letters, numbers and underscores.")
            }

            Section {
                AsyncSubmitButton("Sign Up", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                    await submit()
                }
            }

            FormMessageSection(message: message)

            Section {
                Button("Already have an account? Log In") {
                    dismiss()
                }
            }
        }
        .navigationTitle("Sign Up")
    }

    /// Trims what `AuthService` trims, so the button and the request agree on
    /// what counts as blank.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        message = nil

        do {
            let result = try await AuthService().signUp(
                email: email,
                password: password,
                username: username
            )
            // On success with a session, RootView takes over and this is moot.
            message = result.hasActiveSession
                ? nil
                : .notice("Account created. Confirm your email address before logging in.")
        } catch {
            message = .failure(error.localizedDescription)
        }

        isSubmitting = false
    }
}

#Preview {
    NavigationStack {
        SignUpView()
    }
}
