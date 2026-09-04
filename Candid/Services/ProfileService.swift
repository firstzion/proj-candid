import Foundation
import Supabase

enum ProfileError: LocalizedError {
    case notSignedIn
    case profileMissing
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .profileMissing:
            return "No profile found for this account."
        case .other(let message):
            return message
        }
    }
}

struct ProfileService {
    let client: SupabaseClient

    /// Loads the signed-in user's own `profiles` row.
    ///
    /// Reads `auth.session` rather than `currentSession` so an expired access
    /// token is refreshed before the query, instead of failing under RLS.
    func currentProfile() async throws -> Profile {
        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            throw Self.mapSessionError(error)
        }

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

    /// The profile with exactly this username, or nil if there is none the
    /// caller may see.
    ///
    /// Normalises the way sign-up does (lower, trim), so "Alice " finds
    /// alice. A name that could not exist — wrong characters, wrong length —
    /// is answered nil without a request. Nil also covers a real account
    /// whose owner has blocked the caller: the profiles read policy hides it,
    /// and the answer is the same as for a typo on purpose, because a block
    /// is silent to the person on the other side of it. The smallest path
    /// from "signed up" to "following someone" until search exists (SOL-39).
    func profile(username: String) async throws -> Profile? {
        let username = UsernameRules.normalized(username)
        guard UsernameRules.validationProblem(username) == nil else { return nil }

        do {
            let rows: [Profile] = try await client
                .from("profiles")
                .select()
                .eq("username", value: username)
                .limit(1)
                .execute()
                .value
            return rows.first
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
    /// does that once this returns, the same way `ProfileView`'s "Log Out"
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
        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            throw Self.mapSessionError(error)
        }

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
