import Foundation

/// A row from the `profiles` table.
struct Profile: Identifiable, Decodable, Equatable {
    let id: UUID
    let username: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case createdAt = "created_at"
    }
}
