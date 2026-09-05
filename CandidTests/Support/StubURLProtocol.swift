import Foundation

/// Serves canned responses instead of touching the network — what lets
/// `FeedService(client:)` be tested against real PostgREST/Storage response
/// shapes without a live project. `URLProtocol` subclasses are instantiated
/// internally by `URLSession`, one per request, so the handlers and the
/// requests they've seen live in class-level state guarded by a lock; Swift 6
/// can't verify that safety itself, hence `nonisolated(unsafe)`.
///
/// State is keyed by request host, not global: `TestSupabaseClient.make()`
/// gives every test client its own random host, so concurrently-running
/// suites (Swift Testing's default) can never observe or clobber each
/// other's handler or recorded requests. See `TestSupabaseClient.StubbedClient`
/// for the per-client accessors tests actually call.
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

    typealias Handler = @Sendable (URLRequest) -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    /// Every request seen for `host` since it was last reset, in order.
    static func requests(for host: String) -> [URLRequest] {
        lock.withLock { recorded[host] ?? [] }
    }

    static func setHandler(for host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    /// Clears the handler and recorded requests for `host`. Each test calls
    /// `TestSupabaseClient.make()` for a fresh host, so this is only needed
    /// when a single test reuses one client across sub-cases and wants a
    /// clean slate between them.
    static func reset(host: String) {
        lock.withLock {
            handlers[host] = nil
            recorded[host] = []
        }
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
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let handler = Self.lock.withLock {
            Self.recorded[host, default: []].append(request)
            return Self.handlers[host]
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
