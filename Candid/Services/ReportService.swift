import Foundation
import Supabase

/// Why a post or a person is being reported — the `report_reason` enum, whose
/// raw values are the Postgres labels.
enum ReportReason: String, Codable, CaseIterable, Sendable {
    case spam
    case harassment
    case hate
    case nudity
    case violence
    case impersonation
    case other

    var title: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate"
        case .nudity: "Nudity or sexual content"
        case .violence: "Violence"
        case .impersonation: "Impersonation"
        case .other: "Something else"
        }
    }
}

enum ReportError: LocalizedError {
    case notSignedIn
    case detailsTooLong
    case cannotReportSelf
    case notPermitted
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .detailsTooLong:
            return "Details can be at most \(ReportService.maxDetailsLength) characters."
        case .cannotReportSelf:
            return "You can't report yourself."
        case .notPermitted:
            // Deliberately vague: a post the caller cannot see is refused by
            // the policy, and saying so would confirm the post exists.
            return "Couldn't send that report right now."
        case .other(let message):
            return message
        }
    }
}

/// Reports (SOL-42): capture only. Files a row the reporter can never read
/// back and the reported account never learns of; a repeat report is treated
/// as success, since the thing asked for already holds. Nothing here decides
/// what may be reported — the insert policy refuses a post the reporter
/// cannot see — and nothing reviews anything yet (SOL-45).
struct ReportService {
    let client: SupabaseClient

    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// The `details` CHECK in the schema, mirrored so the refusal is a
    /// sentence and happens before the request.
    static let maxDetailsLength = 500

    /// Reports one post. The person is the post's author; the trigger fills
    /// it from the row regardless, so the report outlives the post.
    func report(post: FeedPost, reason: ReportReason, details: String?) async throws {
        try await file(NewReport(
            reporterID: try await sessionUserID(),
            reportedProfileID: post.authorID,
            reportedPostID: post.id,
            reason: reason,
            details: try Self.preparedDetails(details)
        ))
    }

    /// Reports a person, with no particular post.
    func report(profile: Profile, reason: ReportReason, details: String?) async throws {
        try await file(NewReport(
            reporterID: try await sessionUserID(),
            reportedProfileID: profile.id,
            reportedPostID: nil,
            reason: reason,
            details: try Self.preparedDetails(details)
        ))
    }

    /// Trimmed, with a blank stored as NULL, and measured in Unicode scalars
    /// the way `char_length` measures.
    static func preparedDetails(_ raw: String?) throws -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count <= maxDetailsLength else { throw ReportError.detailsTooLong }
        return trimmed
    }

    private func file(_ report: NewReport) async throws {
        do {
            // No `Prefer: return=representation` — reports has no select
            // policy to answer one with, and this insert only needs to know
            // whether it succeeded (SOL-68).
            try await client.from("reports").insert(report).execute()
        } catch {
            if Self.isRepeat(error) { return }
            throw Self.mapReportError(error)
        }
    }

    /// unique_violation from one of the partial unique indexes: this reporter
    /// has already reported this post or this person.
    static func isRepeat(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    static func mapReportError(_ error: Error) -> ReportError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }
        switch postgrestError.code ?? "" {
        case "23514":
            // reports_not_self; the details CHECK is caught before the request.
            return .cannotReportSelf
        case "42501":
            return .notPermitted
        default:
            if postgrestError.message.lowercased().contains("row-level security") {
                return .notPermitted
            }
            return .other(postgrestError.message)
        }
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            if let authError = error as? AuthError, authError.errorCode == .sessionNotFound {
                throw ReportError.notSignedIn
            }
            throw ReportError.other(error.localizedDescription)
        }
    }
}

/// The insert payload. A nil post is left out of the JSON, so the row takes
/// the column default; `about_post` and `status` are the database's.
private struct NewReport: Encodable {
    let reporterID: UUID
    let reportedProfileID: UUID
    let reportedPostID: UUID?
    let reason: ReportReason
    let details: String?

    enum CodingKeys: String, CodingKey {
        case reporterID = "reporter_id"
        case reportedProfileID = "reported_profile_id"
        case reportedPostID = "reported_post_id"
        case reason
        case details
    }
}
