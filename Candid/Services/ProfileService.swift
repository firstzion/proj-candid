import Foundation
import Supabase

enum ProfileError: LocalizedError {
    case notSignedIn
    case profileMissing
    case invalidUsername(String)
    case usernameTaken
    case usernameChangeTooSoon(Date?)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .profileMissing:
            return "No profile found for this account."
        case .invalidUsername(let problem):
            // Wording comes from `UsernameRules`, which knows what is wrong.
            return problem
        case .usernameTaken:
            // Also what a name someone else released in the last 90 days
            // says: for that long, it is taken.
            return "That username is taken."
        case .usernameChangeTooSoon(let date):
            if let date {
                return "You can change your username again on \(date.formatted(date: .long, time: .omitted))."
            }
            return "You can change your username once every 30 days."
        case .other(let message):
            return message
        }
    }
}

struct ProfileService {
    let client: SupabaseClient

    /// The signed-in user's id, read fresh for every call that needs it —
    /// `auth.session`, so an expired access token is refreshed before the
    /// request rather than failing under RLS. Tests inject a fixed id, as
    /// with the other services.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            throw Self.mapSessionError(error)
        }
    }

    /// Loads the signed-in user's own `profiles` row.
    func currentProfile() async throws -> Profile {
        let userID = try await sessionUserID()

        do {
            return try await client
                .from("profiles")
                .select()
                .eq("id", value: userID)
                .single()
                .execute()
                .value
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    /// The profile that holds, or used to hold, exactly this username — or
    /// nil if there is none the caller may see.
    ///
    /// Goes through `resolve_username` (SOL-41), so a handle someone gave up
    /// still finds them. Normalises the way sign-up does (lower, trim), so
    /// "Alice " finds alice. A name that could not exist — wrong characters,
    /// wrong length — is answered nil without a request. Nil also covers a
    /// real account whose owner has blocked the caller: the function applies
    /// the rule the profiles read policy applies, and the answer is the same
    /// as for a typo on purpose, because a block is silent to the person on
    /// the other side of it.
    func profile(username: String) async throws -> Profile? {
        let username = UsernameRules.normalized(username)
        guard UsernameRules.validationProblem(username) == nil else { return nil }

        do {
            let rows: [Profile] = try await client
                .rpc("resolve_username", params: ["candidate": username])
                .execute()
                .value
            return rows.first
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    /// Prefix search over current usernames, through `searchable_profiles`
    /// (SOL-39). The view leaves out the caller and the caller's blocks and
    /// runs under the profiles policy, which hides anyone who blocked the
    /// caller — so both directions of a block are excluded without this
    /// method knowing. Two characters or more, and only characters a username
    /// can hold: anything else could match nothing and is answered empty
    /// without a request. `_` is a LIKE wildcard and is escaped so it means
    /// itself. Current names only; `profile(username:)` answers a former
    /// handle typed in full.
    func search(prefix: String, limit: Int = 20) async throws -> [Profile] {
        let prefix = UsernameRules.normalized(prefix)
        guard prefix.count >= 2, UsernameRules.hasOnlyAllowedCharacters(prefix) else { return [] }
        let pattern = prefix.replacingOccurrences(of: "_", with: #"\_"#) + "%"

        do {
            return try await client
                .from("searchable_profiles")
                .select()
                .like("username", pattern: pattern)
                .order("username")
                .limit(limit)
                .execute()
                .value
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    /// Whether `username` can be claimed right now, through
    /// `username_available` — which since SOL-41 also says no to a name
    /// someone else released in the last 90 days, and yes to one the caller
    /// released themselves. Advisory: the trigger has the final word.
    func isUsernameAvailable(_ username: String) async throws -> Bool {
        do {
            return try await client
                .rpc("username_available", params: ["candidate": UsernameRules.normalized(username)])
                .execute()
                .value
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    /// Renames the signed-in user (SOL-41). The format is checked here so the
    /// refusal is a sentence; the database enforces uniqueness and the 90-day
    /// reservation of released names (both arrive as a taken name) and one
    /// change per 30 days (which arrives with the date the next is allowed).
    /// Posts follow the person, not the string: the feed joins `profiles`, so
    /// old posts show the new name at their next refresh.
    func changeUsername(to username: String) async throws {
        let username = UsernameRules.normalized(username)
        if let problem = UsernameRules.validationProblem(username) {
            throw ProfileError.invalidUsername(problem)
        }
        let userID = try await sessionUserID()

        do {
            try await client
                .from("profiles")
                .update(["username": username])
                .eq("id", value: userID)
                .execute()
        } catch {
            throw Self.mapUsernameChangeError(error)
        }
    }

    /// The trigger's two refusals and the unique constraint, in the app's words.
    static func mapUsernameChangeError(_ error: Error) -> ProfileError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }
        switch postgrestError.code {
        case "23505":
            // unique_violation: the name is held — or was released by someone
            // else inside the last 90 days, which the trigger reports the
            // same way on purpose.
            return .usernameTaken
        case "23514":
            // check_violation: the rate limit, carrying the date the next
            // change is allowed; or, were the client-side format check ever
            // bypassed, the CHECK constraint itself.
            if postgrestError.message.contains("changed again") {
                return .usernameChangeTooSoon(Self.nextChangeDate(in: postgrestError.message))
            }
            return .invalidUsername("That username isn't allowed.")
        default:
            return .other(postgrestError.message)
        }
    }

    /// The ISO date in "username can be changed again on 2026-10-04", read as
    /// a calendar date in UTC — the database's clock.
    static func nextChangeDate(in message: String) -> Date? {
        guard let range = message.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: String(message[range]))
    }

    /// How many of `profileID`'s posts the caller can see — which is what a
    /// profile shows (SOL-37). Counted by the server with a HEAD request under
    /// RLS, so it is exact for the author, the followers tier for a one-way
    /// follower and zero for a stranger; the true total is never sent to
    /// anyone else, which is what makes "has no posts" and "has posts you
    /// can't see" the same screen (SOL-40).
    func postCount(for profileID: UUID) async throws -> Int {
        do {
            let response: PostgrestResponse<Void> = try await client
                .from("posts")
                .select("id", head: true, count: .exact)
                .eq("user_id", value: profileID)
                .execute()
            return response.count ?? 0
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    /// Distinguishes "nobody is signed in" from "signed in, but the session
    /// could not be refreshed just now" — typically no network. Both used to
    /// come out as `.notSignedIn`, contradicting the tabs the person was
    /// looking at. Only a genuinely missing session means not signed in; that
    /// includes one the server has revoked, which the SDK reports the same way
    /// after clearing it locally.
    static func mapSessionError(_ error: Error) -> ProfileError {
        if let authError = error as? AuthError, authError.errorCode == .sessionNotFound {
            return .notSignedIn
        }
        return .other(error.localizedDescription)
    }

    static func mapProfileError(_ error: Error) -> ProfileError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }

        // PostgREST returns PGRST116 when `.single()` matches no rows, which
        // here means either the trigger did not provision a profile or RLS
        // hid it.
        if postgrestError.code == "PGRST116" {
            return .profileMissing
        }

        // PostgrestError does not conform to LocalizedError, so its
        // localizedDescription is a generic bridged string with none of the
        // server's detail in it. Use the server's own message.
        return .other(postgrestError.message)
    }

    /// Permanently deletes the signed-in user's account: the `auth.users` row
    /// (and by cascade, `profiles` and every `posts` row it owns), plus every
    /// object in the user's storage folder. Does not sign out — the caller
    /// does that once this returns, the same way `ProfileScreen`'s "Log Out"
    /// already goes through `SessionStore` rather than a service.
    ///
    /// Order matters, and is the reverse of "clean up storage, then delete
    /// the account": the delete policy on `storage.objects`
    /// (20260904160000_guard_referenced_post_images.sql) refuses to remove an
    /// object a `posts` row still references, and every one of this
    /// account's images is still referenced until the RPC below cascades
    /// those rows away. Calling it first, then cleaning up storage, is what
    /// that policy requires. The JWT used for the storage calls stays valid
    /// throughout — PostgREST and Storage verify its signature and expiry,
    /// not a live session row, so it keeps working even after the account
    /// row behind it is gone.
    func deleteAccount() async throws {
        let userID = try await sessionUserID()

        do {
            try await client.rpc("delete_own_account").execute()
        } catch {
            throw Self.mapProfileError(error)
        }

        // The account is already gone at this point, which is what "delete
        // my account" asked for. A failure here leaves orphaned objects in
        // storage — harmless, since nothing references them any more — so
        // it is not worth surfacing as a failure of the request as a whole.
        try? await removeAllStorageObjects(forUserFolder: userID)
    }

    private func removeAllStorageObjects(forUserFolder userID: UUID) async throws {
        let folder = userID.uuidString.lowercased()
        let pageSize = 100
        var offset = 0

        while true {
            let page = try await client.storage
                .from(StorageService.bucket)
                .list(path: folder, options: SearchOptions(limit: pageSize, offset: offset))
            guard !page.isEmpty else { return }

            try await client.storage
                .from(StorageService.bucket)
                .remove(paths: page.map { "\(folder)/\($0.name)" })

            if page.count < pageSize { return }
            offset += pageSize
        }
    }
}
