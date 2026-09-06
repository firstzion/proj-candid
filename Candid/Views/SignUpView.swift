import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @Environment(PendingInvite.self) private var pendingInvite

    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var inviteCode = ""
    @State private var isSubmitting = false

    /// Never a success. A sign-up that returns a session emits on the SDK's
    /// auth-state stream, `RootView` swaps to the main tabs, and this view is
    /// torn down before any success message could be read. The one
    /// non-failure outcome worth reporting is a sign-up that succeeds
    /// *without* a session — the normal result with email confirmations on
    /// (`supabase/config.toml`), shown as a notice. GoTrue answers the same
    /// way, on purpose, for an address that already has an account, so
    /// nobody can use this form to learn which addresses are registered
    /// (SOL-84) — the notice's wording has to stay true for both.
    @State private var message: FormMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Create your account")
                    .font(.newsreader(36))
                    .foregroundStyle(.candidInk)
                    .padding(.top, 8)

                Text("Three things, then you are in.")
                    .font(.newsreader(17))
                    .foregroundStyle(.candidMuted)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    HairlineField(label: "Email") {
                        TextField("", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HairlineField(label: "Password") {
                        SecureField("", text: $password)
                            .textContentType(.newPassword)
                    }
                    HairlineField(label: "Username") {
                        TextField("", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    // Sign-up is invite-only (SOL-61). Pre-filled from an
                    // invite link when there is one; typed from the message
                    // otherwise.
                    HairlineField(label: "Invite code") {
                        TextField("", text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Rectangle().fill(Color.candidDivider).frame(height: 0.5)
                }
                .padding(.top, 34)

                // "10" mirrors minimum_password_length in
                // supabase/config.toml, not a client-enforced rule — keep the
                // two in sync by hand.
                Text("Candid is invite-only: you need a code from someone who is already here. Passwords must be at least 10 characters. Usernames are \(UsernameRules.minLength)–\(UsernameRules.maxLength) characters: lowercase letters, numbers and underscores.")
                    .font(.system(size: 13))
                    .foregroundStyle(.candidMuted)
                    .padding(.top, 12)

                AsyncSubmitButton("Create account", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                    await submit()
                }
                .padding(.top, 40)

                FormMessageSection(message: message)
                    .padding(.top, message == nil ? 0 : 12)

                Button {
                    dismiss()
                } label: {
                    (Text("Already have an account? ").foregroundStyle(.candidMuted)
                        + Text("Log in").foregroundStyle(.candidAccent).fontWeight(.medium))
                        .font(.system(size: 15))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.candidGround)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 17))
                    }
                    .foregroundStyle(.candidAccent)
                }
            }
        }
        .toolbarBackground(Color.candidGround, for: .navigationBar)
        .task { takePendingInvite() }
        .onChange(of: pendingInvite.code) { takePendingInvite() }
    }

    /// Moves a code that arrived by deep link into the field, once.
    private func takePendingInvite() {
        guard let code = pendingInvite.code else { return }
        inviteCode = code
        pendingInvite.code = nil
    }

    /// Trims what `AuthService` trims, so the button and the request agree on
    /// what counts as blank.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !InviteService.normalized(inviteCode).isEmpty
    }

    private func submit() async {
        isSubmitting = true
        message = nil

        do {
            let result = try await services.auth.signUp(
                email: email,
                password: password,
                username: username,
                inviteCode: inviteCode
            )
            // On success with a session, RootView takes over and this is moot.
            // The wording below has to be true whether this address is new
            // or already has an account — GoTrue answers both the same way
            // (SOL-84), and revealing which one happened here would defeat
            // the point.
            message = result.hasActiveSession
                ? nil
                : .notice("Check your email. If that address is new to Candid, we've sent you a confirmation link. If it already has an account, just log in.")
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
    .environment(\.services, AppServices(client: .preview))
    .environment(PendingInvite())
}
