import Foundation

extension URLRequest {
    /// The query string as PostgREST will read it — percent-decoded, so an
    /// `or=` filter's parentheses and commas compare as written. A repeated
    /// name keeps its first value.
    var queryParameters: [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// The request body as data, whichever way `URLSession` chose to carry it.
    ///
    /// `URLSession` converts a request's `httpBody` into `httpBodyStream`
    /// before handing it to a `URLProtocol`, so `httpBody` alone is nil by the
    /// time `startLoading()` sees a POST — the body has to be drained from the
    /// stream instead.
    var drainedBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
