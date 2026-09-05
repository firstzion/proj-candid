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
/// `deletePost` is pinned the other way round: row first, then object, the
/// order the storage delete policy forces — and by `id` alone, since RLS
/// scopes the delete to the author.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
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

    private static func makeService() -> (PostService, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        return (PostService(client: stub.client, imageCache: ImageCache(), currentUserID: { Self.me }), stub)
    }

    @Test("createPost uploads first, then inserts a row carrying the chosen visibility")
    func insertCarriesVisibility() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler(Self.happyPath)

        try await service.createPost(image: Self.image(), caption: "  hello  ", visibility: .mutuals)

        // Upload before row, so a failed upload can never leave a row behind.
        let paths = stub.requests.compactMap { $0.url?.path }
        let uploadIndex = try #require(paths.firstIndex { $0.hasPrefix(Self.uploadPrefix) })
        let insertIndex = try #require(paths.firstIndex { $0 == "/rest/v1/posts" })
        #expect(uploadIndex < insertIndex)

        let insert = try #require(stub.requests.first { $0.url?.path == "/rest/v1/posts" })
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
        let (service, stub) = Self.makeService()
        stub.setHandler(Self.happyPath)

        try await service.createPost(image: Self.image(), caption: "   ")

        let insert = try #require(stub.requests.first { $0.url?.path == "/rest/v1/posts" })
        let row = try JSONDecoder().decode(InsertedRow.self, from: try #require(insert.drainedBody))
        #expect(row.visibility == .followers)
        // A blank caption is stored as NULL, not "".
        #expect(row.caption == nil)
    }

    /// Row first, then object: the storage policy refuses an object a row
    /// still references, so the other order fails loudly. And by `id` alone —
    /// the `posts` delete policy scopes the statement to the author's own
    /// rows, so the client sends no `user_id` filter.
    @Test("deletePost removes the row by id alone, then the object")
    func deleteRowThenObject() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler(Self.deleteHappyPath)

        let postID = UUID()
        let imagePath = "\(Self.me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await service.deletePost(id: postID, imagePath: imagePath)

        let requests = stub.requests
        #expect(requests.count == 2)

        let row = try #require(requests.first)
        #expect(row.httpMethod == "DELETE")
        #expect(row.url?.path == "/rest/v1/posts")
        let query = row.queryParameters
        #expect(query["id"] == "eq.\(postID.uuidString)")
        #expect(query["user_id"] == nil)

        let object = try #require(requests.last)
        #expect(object.httpMethod == "DELETE")
        #expect(object.url?.path == Self.removePath)
        struct RemoveBody: Decodable { let prefixes: [String] }
        let body = try JSONDecoder().decode(RemoveBody.self, from: try #require(object.drainedBody))
        #expect(body.prefixes == [imagePath])
    }

    /// The post is out of every feed the moment the row is; a leftover object
    /// is readable by its owner alone and costs storage, not privacy. So a
    /// failed object delete is logged, not reported as a failed delete.
    @Test("a failed object delete after the row is gone is not surfaced")
    func objectDeleteFailureIsNotAnError() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { request in
            if request.url?.path == "/rest/v1/posts" {
                return .init(statusCode: 204, body: Data())
            }
            return .init(
                statusCode: 400,
                body: Data(#"{"statusCode":"400","error":"Bad Request","message":"Object not found"}"#.utf8)
            )
        }

        try await service.deletePost(id: UUID(), imagePath: Self.ownImagePath())
        #expect(stub.requests.count == 2)
    }

    /// A row that could not be deleted is a live post, and its object must
    /// stay exactly where it is.
    @Test("a refused row delete throws and never touches the object")
    func rowDeleteFailureStopsThere() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in
            .init(statusCode: 401, body: Data(#"{"code":"42501","message":"permission denied for table posts"}"#.utf8))
        }

        await #expect(throws: PostError.self) {
            try await service.deletePost(id: UUID(), imagePath: Self.ownImagePath())
        }
        #expect(stub.requests.count == 1)
        #expect(stub.requests.first?.url?.path == "/rest/v1/posts")
    }

    // MARK: - Fixtures

    private static let uploadPrefix = "/storage/v1/object/post-images/"

    /// Storage's bulk remove endpoint: `DELETE object/<bucket>` with the
    /// paths in the body.
    private static let removePath = "/storage/v1/object/post-images"

    private static func ownImagePath() -> String {
        "\(me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
    }

    /// Answers the row delete with PostgREST's empty 204 and the object
    /// remove with Storage's list of removed objects.
    private static func deleteHappyPath(_ request: URLRequest) -> StubURLProtocol.Response {
        switch request.url?.path {
        case "/rest/v1/posts":
            return .init(statusCode: 204, body: Data())
        case removePath:
            return .init(body: Data("[]".utf8))
        default:
            return .init(statusCode: 404, body: Data())
        }
    }

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
