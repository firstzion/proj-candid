import SwiftUI

struct LogInView: View {
    @State private var email = ""
    @State private var password = ""
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
                    .textContentType(.password)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Log In")
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

            Section {
                NavigationLink("Don't have an account? Sign Up") {
                    SignUpView()
                }
            }
        }
        .navigationTitle("Log In")
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func submit() async {
        isSubmitting = true
        message = nil

        do {
            let result = try await AuthService().signIn(email: email, password: password)
            message = .success("Logged in as \(result.email ?? "unknown").")
        } catch {
            message = .failure(error.localizedDescription)
        }

        isSubmitting = false
    }
}

#Preview {
    NavigationStack {
        LogInView()
    }
}
