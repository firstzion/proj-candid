import SwiftUI

struct SignUpView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var isSubmitting = false
    @State private var message: Message?

    private enum Message {
        case success(String)
        case failure(String)
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
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Sign Up")
                    }
                }
                .disabled(!canSubmit)
            }

            if let message {
                Section {
                    switch message {
                    case .success(let text):
                        Text(text).foregroundStyle(.green)
                    case .failure(let text):
                        Text(text).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Sign Up")
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
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
            message = .success(
                result.hasActiveSession
                    ? "Signed up and logged in."
                    : "Account created, but no session — email confirmation is still enabled on the project."
            )
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
