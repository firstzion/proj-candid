import Foundation

/// A row from the `profiles` table.
///
/// The table also has `created_at`. It is deliberately not decoded here: an
/// unused field can still fail decoding and break the whole screen, so it gets
/// added when something actually displays it.
///
/// `Hashable` so a profile can be a navigation destination value — tapping a
/// username in the feed, or finding one on the Profile tab, pushes
/// `ProfileScreen` with it.
struct Profile: Identifiable, Decodable, Hashable {
    let id: UUID
    let username: String
}
