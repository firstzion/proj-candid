import SwiftUI

/// Rename yourself (SOL-41). The same checks the sign-up form makes —
/// `UsernameRules` for the format, `username_available` for the name — run
/// before the request so a refusal is a sentence; the database has the final
/// word on uniqueness, the 90-day reservation of released names and the
/// one-change-per-30-days limit, and `ProfileService.changeUsername` words
/// those too. On success the caller is told the new name, and the feed is
/// marked stale so old posts show it at their next refresh.
struct EditUsernameSheet: View {
    let currentUsername: String
    let onChanged: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    @State private var username: String
    @State private var isSubmitting = false
    @State private var message: FormMessage?

    init(currentUsername: String, onChanged: @escaping (String) -> Void) {
        self.currentUsername = currentUsername
        self.onChanged = onChanged
        _username = State(initialValue: currentUsername)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    // "30 days" and "90 days" mirror the cooldown and the hold
                    // period in 20260905013141_username_history.sql, which are
                    // where they are enforced — keep the two in sync by hand.
                    // The lengths come from UsernameRules, which the client
                    // does check, so those are interpolated rather than typed.
                    Text("Usernames are \(UsernameRules.minLength)–\(UsernameRules.maxLength) characters: lowercase letters, numbers and underscores. You can change yours once every 30 days. A name you give up is held for you for 90 days, and anyone who knew it can still find you by it.")
                        .foregroundStyle(.candidMuted)
                }

                Section {
                    AsyncSubmitButton("Save", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                        await save()
                    }
                }

                FormMessageSection(message: message)
            }
            .scrollContentBackground(.hidden)
            .background(Color.candidGround)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit Username")
                        .font(.newsreader(19))
                        .foregroundStyle(.candidInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.candidAccent)
                }
            }
            .toolbarBackground(Color.candidGround, for: .navigationBar)
        }
    }

    /// Trims what the service trims, and refuses a no-op rename up front.
    private var canSubmit: Bool {
        let normalized = UsernameRules.normalized(username)
        return !normalized.isEmpty && normalized != currentUsername
    }

    private func save() async {
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }

        let normalized = UsernameRules.normalized(username)
        if let problem = UsernameRules.validationProblem(normalized) {
            message = .failure(problem)
            return
        }

        do {
            guard try await services.profile.isUsernameAvailable(normalized) else {
                message = .failure(ProfileError.usernameTaken.localizedDescription)
                return
            }
            try await services.profile.changeUsername(to: normalized)
            onChanged(normalized)
            dismiss()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    EditUsernameSheet(currentUsername: "alice") { _ in }
        .environment(\.services, AppServices(client: .preview))
}
