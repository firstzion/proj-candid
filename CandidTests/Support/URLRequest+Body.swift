import Foundation

extension URLRequest {
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
