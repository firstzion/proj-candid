import Foundation

/// The rules `profiles.username` enforces — a CHECK constraint in the schema
/// (`^[a-z0-9_]{3,30}$`) and lower/trim normalisation in the sign-up trigger —
/// mirrored on the client so the form can say precisely what is wrong before
/// a request is made. A CHECK failure inside the trigger only ever reaches the
/// app as GoTrue's sanitised "Database error saving new user", which says
/// nothing about why.
///
/// Storing lowercase only is also what makes usernames case-insensitively
/// unique: the plain unique constraint does the work, so `Alice` and `alice`
/// cannot be two people.
enum UsernameRules {
    static let minLength = 3
    static let maxLength = 30

    /// The character class of the schema's pattern, `[a-z0-9_]`.
    private static let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    /// The canonical form the database stores: trimmed and lowercased, exactly
    /// as the sign-up trigger normalises it.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Nil when `username` — already normalised — is valid; otherwise a
    /// sentence a person can act on. Characters are checked before length so
    /// the message names the real problem: "élodie" hears about the accent,
    /// not the count.
    static func validationProblem(_ username: String) -> String? {
        guard username.unicodeScalars.allSatisfy(allowedScalars.contains) else {
            return "Usernames can only use lowercase letters, numbers and underscores."
        }
        if username.count < minLength {
            return "Usernames need at least \(minLength) characters."
        }
        if username.count > maxLength {
            return "Usernames can be at most \(maxLength) characters."
        }
        return nil
    }
}
