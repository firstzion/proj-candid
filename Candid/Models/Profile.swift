import Foundation

/// A row from the `profiles` table.
///
/// The table also has `created_at`. It is deliberately not decoded here: an
/// unused field can still fail decoding and break the whole screen, so it gets
/// added when something actually displays it.
struct Profile: Identifiable, Decodable, Equatable {
    let id: UUID
    let username: String
}
