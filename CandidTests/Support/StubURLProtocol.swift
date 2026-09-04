import Foundation

/// Serves canned responses instead of touching the network — what lets
/// `FeedService(client:)` be tested against real PostgREST/Storage response
/// shapes without a live project. `URLProtocol` subclasses are instantiated
/// internally by `URLSession`, one per request, so the handler and the
/// requests it has seen live in class-level state guarded by a lock; Swift 6
/// can't verify that safety itself, hence `nonisolated(unsafe)`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    /// Every request seen since the last `reset()`, in order.
    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// Clears both the handler and the recorded requests. Call before each
    /// test that installs its own handler, so one test's stub can't leak
    /// into the next.
    static func reset() {
        lock.withLock {
            handler = nil
            recordedRequests = []
        }
    }

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { Self.handler = handler }
    }

    /// A `URLSession` that routes every request through this protocol,
    /// suitable for `SupabaseClientOptions.GlobalOptions.session`.
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.handler
        }

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let response = handler(request)
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
