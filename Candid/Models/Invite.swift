import Foundation

/// One row of `invites`, as `InviteService` reads it: a code this account
/// minted, and whether anyone has used it yet. `redeemer` is the profile at
/// the other end when there is one and the caller may read it — someone who
/// has since blocked the inviter, or deleted their account, shows as redeemed
/// by nobody in particular rather than as unredeemed.
struct Invite: Identifiable, Decodable, Hashable {
    let code: String
    let inviterID: UUID
    let redeemedBy: UUID?
    let redeemedAt: Date?
    let createdAt: Date
    let expiresAt: Date?
    let redeemer: Redeemer?

    struct Redeemer: Decodable, Hashable {
        let username: String
    }

    var id: String { code }

    enum State: Hashable {
        case unredeemed
        case redeemed
        case expired
    }

    /// Redeemed beats expired: a code someone used before it ran out is a
    /// redemption and holds its quota slot; an expired, unused code has given
    /// its slot back.
    func state(at now: Date = .now) -> State {
        if redeemedAt != nil { return .redeemed }
        if let expiresAt, expiresAt <= now { return .expired }
        return .unredeemed
    }

    /// The invite link, `candid://invite/<code>` — see `PendingInvite`.
    var deepLink: URL {
        URL(string: "candid://invite/\(code)")!
    }

    enum CodingKeys: String, CodingKey {
        case code
        case inviterID = "inviter_id"
        case redeemedBy = "redeemed_by"
        case redeemedAt = "redeemed_at"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case redeemer
    }
}

/// What `invite_status(code)` answers — the one thing about an invite the
/// world may learn, and the only invite call the sign-up form makes before
/// an account exists. Raw values are the Postgres enum labels.
enum InviteState: String, Decodable, Sendable {
    case valid
    case notFound = "not_found"
    case redeemed
    case expired
}
