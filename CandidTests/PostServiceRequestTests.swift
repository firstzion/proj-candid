import Foundation
import Testing
import Supabase
import UIKit
@testable import Candid

/// `PostService.createPost` against stubbed Storage and PostgREST endpoints.
/// What is pinned is the order of the two calls — upload, then row — and the
/// shape of the row, in particular that the chosen visibility travels with
/// it: a post whose tier silently fell back to the default would reach the
/// wrong audience, and nothing else would ever notice.
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct PostServiceRequestTests {
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The insert payload as PostgREST receives it.
    private struct InsertedRow: Decodable {
        let userID: UUID
        let imagePath: String
        let caption: String?
        let visibility: PostVisibility

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case imagePath = "image_path"
            case caption
            case visibility
        }
    }

    @Test("createPost uploads first, then inserts a row carrying the chosen visibility")
    func insertCarriesVisibility() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler(Self.happyPath)

        let service = PostService(client: TestSupabaseClient.make(), currentUserID: { Self.me })
        try await service.createPost(image: Self.image(), caption: "  hello  ", visibility: .mutuals)

        // Upload before row, so a failed upload can never leave a row behind.
        let paths = StubURLProtocol.requests.compactMap { $0.url?.path }
        let uploadIndex = try #require(paths.firstIndex { $0.hasPrefix(Self.uploadPrefix) })
        let insertIndex = try #require(paths.firstIndex { $0 == "/rest/v1/posts" })
        #expect(uploadIndex < insertIndex)

        let insert = try #require(StubURLProtocol.requests.first { $0.url?.path == "/rest/v1/posts" })
        #expect(insert.httpMethod == "POST")

        let row = try JSONDecoder().decode(InsertedRow.self, from: try #require(insert.drainedBody))
        #expect(row.userID == Self.me)
        #expect(row.visibility == .mutuals)
        #expect(row.caption == "hello")
        // The object lives in the caller's own folder — what the storage and
        // posts policies both require.
        #expect(row.imagePath.hasPrefix("\(Self.me.uuidString.lowercased())/"))
        #expect(row.imagePath.hasSuffix(".jpg"))
    }

    /// The column default is `followers` too, but the row carries the tier
    /// explicitly either way, so what was posted records the person's choice
    /// rather than whatever the default happens to be on the day.
    @Test("visibility is followers when the caller does not choose, and is still sent")
    func defaultVisibility() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler(Self.happyPath)

        let service = PostService(client: TestSupabaseClient.make(), currentUserID: { Self.me })
        try await service.createPost(image: Self.image(), caption: "   ")

        let insert = try #require(StubURLProtocol.requests.first { $0.url?.path == "/rest/v1/posts" })
        let row = try JSONDecoder().decode(InsertedRow.self, from: try #require(insert.drainedBody))
        #expect(row.visibility == .followers)
        // A blank caption is stored as NULL, not "".
        #expect(row.caption == nil)
    }

    // MARK: - Fixtures

    private static let uploadPrefix = "/storage/v1/object/post-images/"

    /// Answers the upload with Storage's real response shape (`Key` and `Id`)
    /// and the insert with an empty 201, the way PostgREST does when no
    /// representation is asked for.
    private static func happyPath(_ request: URLRequest) -> StubURLProtocol.Response {
        guard let path = request.url?.path else {
            return .init(statusCode: 400, body: Data())
        }
        if path.hasPrefix(uploadPrefix) {
            let objectPath = String(path.dropFirst(uploadPrefix.count))
            return .init(body: Data(#"{"Key":"post-images/\#(objectPath)","Id":"\#(UUID().uuidString)"}"#.utf8))
        }
        if path == "/rest/v1/posts" {
            return .init(statusCode: 201, body: Data())
        }
        return .init(statusCode: 404, body: Data())
    }

    private static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
    }
}
