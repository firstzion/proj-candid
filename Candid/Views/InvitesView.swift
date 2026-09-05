import SwiftUI

/// Your invites (SOL-63): how many you have left, the codes you have out, and
/// who used the ones that were used. Deliberately plain — a list, a button
/// and a share sheet; no streaks, no nudges. Reached from your own profile,
/// and from the People tab once it exists (SOL-39).
///
/// Nothing here enforces anything. `create_invite()` checks the quota on the
/// server and the delete policy decides what can be revoked; this screen says
/// so first, so the limit reads as a limit rather than as a bug. The count it
/// shows is the server's own arithmetic — redeemed plus outstanding
/// unexpired — so a revoked or expired code visibly gives its slot back.
struct InvitesView: View {
    @Environment(\.services) private var services

    @State private var invites: [Invite]?
    @State private var quota: Int?
    @State private var loadError: String?
    @State private var isCreating = false
    @State private var message: FormMessage?

    /// Redeemed plus outstanding unexpired, exactly as `create_invite()` counts.
    private var used: Int {
        (invites ?? []).filter { $0.state() != .expired }.count
    }

    private var remaining: Int? {
        quota.map { max(0, $0 - used) }
    }

    var body: some View {
        List {
            Section {
                quotaLine
                AsyncSubmitButton("Generate Invite", isSubmitting: isCreating, isEnabled: (remaining ?? 0) > 0) {
                    await create()
                }
            } footer: {
                Text("A code admits one person and expires after 30 days if nobody uses it. Swipe an unused code to take it back.")
            }

            if let invites {
                let open = invites.filter { $0.state() == .unredeemed }
                let redeemed = invites.filter { $0.state() == .redeemed }
                let expired = invites.filter { $0.state() == .expired }

                if !open.isEmpty {
                    Section("Ready to share") {
                        ForEach(open) { invite in
                            openRow(invite)
                                .swipeActions {
                                    Button("Revoke", role: .destructive) { Task { await revoke(invite) } }
                                }
                        }
                    }
                }
                if !redeemed.isEmpty {
                    Section("Used") {
                        ForEach(redeemed) { invite in
                            redeemedRow(invite)
                        }
                    }
                }
                if !expired.isEmpty {
                    Section("Expired") {
                        ForEach(expired) { invite in
                            expiredRow(invite)
                                .swipeActions {
                                    Button("Remove", role: .destructive) { Task { await revoke(invite) } }
                                }
                        }
                    }
                }
            }

            FormMessageSection(message: message)
        }
        .navigationTitle("Invites")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var quotaLine: some View {
        if let remaining, let quota {
            if remaining == 0 {
                Text("You've used all \(quota) invites.")
            } else {
                Text("\(remaining) of \(quota) invites left")
            }
        } else if let loadError {
            Text(loadError)
                .foregroundStyle(.red)
            Button("Try Again") { Task { await load() } }
        } else {
            ProgressView()
        }
    }

    /// The code, when it runs out, and the share sheet — with the deep link
    /// and the code in plain text, since a custom-scheme link is dead on a
    /// phone without the app.
    private func openRow(_ invite: Invite) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.code)
                    .font(.body.monospaced())
                if let expiresAt = invite.expiresAt {
                    Text("Expires \(expiresAt, format: .dateTime.month().day())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ShareLink(item: invite.shareMessage, subject: Text("Your invite to Candid")) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Share code \(invite.code)")
        }
    }

    /// Who and when. "Someone" when the redeemer's profile is not readable —
    /// they have blocked you, or deleted their account.
    private func redeemedRow(_ invite: Invite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(invite.code)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            if let redeemedAt = invite.redeemedAt {
                Text("Used by \(invite.redeemer.map { "@\($0.username)" } ?? "someone") · \(redeemedAt, format: .dateTime.month().day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func expiredRow(_ invite: Invite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(invite.code)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            if let expiresAt = invite.expiresAt {
                Text("Expired \(expiresAt, format: .dateTime.month().day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            quota = try await services.invite.quota()
            invites = try await services.invite.mine()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The server enforces the quota; a refusal here means the count above
    /// was stale, and reloading shows the real one.
    private func create() async {
        isCreating = true
        message = nil
        defer { isCreating = false }
        do {
            let invite = try await services.invite.create()
            invites = [invite] + (invites ?? [])
        } catch {
            message = .failure(error.localizedDescription)
            await load()
        }
    }

    /// Deletes an unredeemed code; the policy refuses anything else, and a
    /// refusal matches no rows rather than failing.
    private func revoke(_ invite: Invite) async {
        message = nil
        do {
            try await services.invite.revoke(code: invite.code)
            invites?.removeAll { $0.id == invite.id }
        } catch {
            message = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        InvitesView()
    }
    .environment(\.services, AppServices(client: .preview))
}
