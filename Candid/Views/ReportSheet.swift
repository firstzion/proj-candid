import SwiftUI

/// Report a post or a person (SOL-42): a reason, optional details, one
/// button. Silent to the reported account by construction — nothing they can
/// read changes — and capture only: no review surface exists yet (SOL-45), so
/// the caller offers a block afterwards, since the reporter usually wants the
/// content gone from their own view now.
struct ReportSheet: View {
    enum Target: Identifiable {
        case post(FeedPost)
        case profile(Profile)

        var id: String {
            switch self {
            case .post(let post): "post-\(post.id.uuidString)"
            case .profile(let profile): "profile-\(profile.id.uuidString)"
            }
        }

        /// The account the report is about — who a follow-up block targets.
        var reportedProfile: Profile {
            switch self {
            case .post(let post): Profile(id: post.authorID, username: post.username)
            case .profile(let profile): profile
            }
        }
    }

    let target: Target

    /// Called once the report is filed, with the account it was about.
    let onReported: (Profile) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    @State private var reason: ReportReason = .spam
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var message: FormMessage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases, id: \.self) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(prompt)
                }

                Section("Details (optional)") {
                    TextField("What's wrong?", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    AsyncSubmitButton("Report", isSubmitting: isSubmitting) {
                        await submit()
                    }
                } footer: {
                    Text("They won't be told.")
                        .foregroundStyle(.candidMuted)
                }

                FormMessageSection(message: message)
            }
            .scrollContentBackground(.hidden)
            .background(Color.candidGround)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
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

    private var title: String {
        switch target {
        case .post: "Report Post"
        case .profile: "Report Account"
        }
    }

    private var prompt: String {
        switch target {
        case .post(let post): "Why are you reporting this post by @\(post.username)?"
        case .profile(let profile): "Why are you reporting @\(profile.username)?"
        }
    }

    private func submit() async {
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }

        do {
            switch target {
            case .post(let post):
                try await services.report.report(post: post, reason: reason, details: details)
            case .profile(let profile):
                try await services.report.report(profile: profile, reason: reason, details: details)
            }
            onReported(target.reportedProfile)
            dismiss()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    ReportSheet(target: .profile(Profile(id: UUID(), username: "alice"))) { _ in }
        .environment(\.services, AppServices(client: .preview))
}
