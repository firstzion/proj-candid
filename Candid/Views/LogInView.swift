import SwiftUI

struct LogInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false

    /// Only failures are shown. A successful log in emits on the SDK's
    /// auth-state stream, `RootView` swaps to the main tabs, and this view is
    /// torn down — so a success message here would never be read.
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            Section {
                AsyncSubmitButton("Log In", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                    await submit()
                }
            }

            FormMessageSection(message: errorMessage)

            Section {
                NavigationLink("Don't have an account? Sign Up") {
                    SignUpView()
                }
            }
        }
        .navigationTitle("Log In")
    }

    /// Trims what `AuthService` trims, so the button and the request agree on
    /// what counts as blank.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil

        do {
            try await AuthService().signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}

#Preview {
    NavigationStack {
        LogInView()
    }
}
