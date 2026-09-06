import SwiftUI

struct LogInView: View {
    @Environment(\.services) private var services
    @Environment(PendingInvite.self) private var pendingInvite

    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false

    /// Pushed by the Sign Up button — and by an invite link arriving, so the
    /// person lands in the form with their code already in it (SOL-61).
    /// `pendingInvite.code` is only ever set while this view is the one on
    /// screen, i.e. while signed out (SOL-76) — a link tapped while signed
    /// in never reaches here, and one left over from an earlier tap is
    /// cleared at sign-in rather than surfacing at the next sign-out.
    @State private var isShowingSignUp = false

    /// Only failures are shown. A successful log in emits on the SDK's
    /// auth-state stream, `RootView` swaps to the main tabs, and this view is
    /// torn down — so a success message here would never be read.
    @State private var message: FormMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome back")
                    .font(.newsreader(36))
                    .foregroundStyle(.candidInk)
                    .padding(.top, 20)

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
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit {
                                guard canSubmit else { return }
                                Task { await submit() }
                            }
                    }
                    Rectangle().fill(Color.candidDivider).frame(height: 0.5)
                }
                .padding(.top, 28)

                AsyncSubmitButton("Log in", isSubmitting: isSubmitting, isEnabled: canSubmit) {
                    await submit()
                }
                .padding(.top, 26)

                FormMessageSection(message: message)
                    .padding(.top, message == nil ? 0 : 12)

                Button {
                    isShowingSignUp = true
                } label: {
                    (Text("New here? ").foregroundStyle(.candidMuted)
                        + Text("Create an account").foregroundStyle(.candidAccent).fontWeight(.medium))
                        .font(.system(size: 15))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.candidGround)
        .navigationDestination(isPresented: $isShowingSignUp) {
            SignUpView()
        }
        .task { if pendingInvite.code != nil { isShowingSignUp = true } }
        .onChange(of: pendingInvite.code) { if pendingInvite.code != nil { isShowingSignUp = true } }
    }

    /// Trims what `AuthService` trims, so the button and the request agree on
    /// what counts as blank.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func submit() async {
        isSubmitting = true
        message = nil

        do {
            // `services` is set once, at the app root, before `RootView` (and
            // therefore this view) ever renders — see `CandidApp`.
            try await services.auth.signIn(email: email, password: password)
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
    .environment(\.services, AppServices(client: .preview))
    .environment(PendingInvite())
}
