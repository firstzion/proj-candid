import Foundation
import Supabase

enum InviteError: LocalizedError {
    case notSignedIn
    case quotaReached
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .quotaReached:
            return "You've used all your invites."
        case .other(let message):
            return message
        }
    }
}

/// Invites, from the signed-in user's side (SOL-60, SOL-63) and from the
/// sign-up form's (SOL-61). Nothing here mints or redeems a code itself:
/// `create_invite()` mints within the server-side quota, and the sign-up
/// trigger redeems inside GoTrue's insert. This type calls the first, lists
/// and revokes the caller's own rows under RLS, and asks `invite_status()`
/// the one question the world may ask.
struct InviteService {
    let client: SupabaseClient

    /// The signed-in user's id, read fresh for every call that needs it;
    /// tests inject a fixed one, as the other services do.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// Upper-cased and trimmed — how the database normalises a code, so one
    /// typed in lowercase from a text message is the same code.
    static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Whether `code` can still admit someone. Callable before sign-in, which
    /// is the point: the sign-up form asks first so each failure gets its
    /// own sentence, since the trigger's refusal reaches the app only as
    /// GoTrue's sanitised database error.
    func status(code: String) async throws -> InviteState {
        do {
            return try await client
                .rpc("invite_status", params: ["p_code": Self.normalized(code)])
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Mints a code for the caller. The server checks the quota — redeemed
    /// plus outstanding unexpired codes — and refuses past it; the invites
    /// screen only says so first.
    func create() async throws -> Invite {
        do {
            return try await client
                .rpc("create_invite")
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Every code the caller has minted, newest first, each with the
    /// username of whoever redeemed it when that profile is readable.
    func mine() async throws -> [Invite] {
        do {
            return try await client
                .from("invites")
                .select("*,redeemer:profiles!invites_redeemed_by_fkey(username)")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Deletes an unredeemed code of the caller's. The delete policy allows
    /// exactly that and nothing else, so a redeemed code — or someone else's
    /// — matches no rows, which is not an error.
    func revoke(code: String) async throws {
        do {
            try await client
                .from("invites")
                .delete()
                .eq("code", value: Self.normalized(code))
                .execute()
        } catch {
            throw Self.mapError(error)
        }
    }

    /// How many invites the caller may have out or redeemed at once — the
    /// `invite_quota` column on their own profile, raisable per account.
    func quota() async throws -> Int {
        let me: UUID
        do {
            me = try await currentUserID()
        } catch {
            throw Self.mapSessionError(error)
        }
        do {
            let row: QuotaRow = try await client
                .from("profiles")
                .select("invite_quota")
                .eq("id", value: me)
                .single()
                .execute()
                .value
            return row.inviteQuota
        } catch {
            throw Self.mapError(error)
        }
    }

    static func mapSessionError(_ error: Error) -> InviteError {
        if let authError = error as? AuthError, authError.errorCode == .sessionNotFound {
            return .notSignedIn
        }
        return .other(error.localizedDescription)
    }

    static func mapError(_ error: Error) -> InviteError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }
        // create_invite() raises check_violation with this exact message.
        if postgrestError.code == "23514" && postgrestError.message.contains("invite quota reached") {
            return .quotaReached
        }
        if postgrestError.message == "not signed in" {
            return .notSignedIn
        }
        // PostgrestError is a plain Error; its localizedDescription is
        // boilerplate. Use the server's message.
        return .other(postgrestError.message)
    }
}

private struct QuotaRow: Decodable {
    let inviteQuota: Int

    enum CodingKeys: String, CodingKey {
        case inviteQuota = "invite_quota"
    }
}
