import Foundation
import UIKit

/// Decoded feed images, kept in memory and keyed by storage path.
///
/// `AsyncImage` and `URLCache` can only key on the URL, and a signed URL
/// carries a fresh token every time it is minted — so every feed refresh
/// re-downloaded every image, and a row scrolled off and back reloaded on its
/// way in. The object *path* is the durable identity of an image (see
/// `StorageService`), so it is the key here; the URL is just how the bytes are
/// fetched this time.
///
/// Concurrent requests for the same path share one download. A failed load is
/// not remembered, so the next appearance retries. `NSCache` evicts under
/// memory pressure on its own; the cost limit keeps a long scroll from holding
/// every decoded image at once.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    enum LoadError: Error {
        case badResponse
        case undecodable
    }

    private let session: URLSession
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    /// - Parameter totalCostLimit: in bytes of decoded bitmap. 100 MB is
    ///   roughly thirteen 1600×1200 images.
    init(session: URLSession = .shared, totalCostLimit: Int = 100 * 1024 * 1024) {
        self.session = session
        cache.totalCostLimit = totalCostLimit
    }

    /// The decoded image for `path` if it is already cached — synchronous, so
    /// a row can render it in its very first frame instead of showing a
    /// spinner for one tick.
    func cachedImage(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    /// Seeds the cache — e.g. with a photo that was just uploaded: the feed
    /// will show it next, and the image is already here.
    func store(_ image: UIImage, for path: String) {
        cache.setObject(image, forKey: path as NSString, cost: Self.cost(of: image))
    }

    /// The image for `path`: from the cache, or else downloaded from `url`,
    /// decoded and cached. Joins an in-flight download for the same path
    /// rather than starting another.
    func image(for path: String, from url: URL) async throws -> UIImage {
        if let cached = cachedImage(for: path) {
            return cached
        }
        return try await loadTask(for: path, from: url).value
    }

    private func loadTask(for path: String, from url: URL) -> Task<UIImage, Error> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = inFlight[path] {
            return existing
        }

        let task = Task<UIImage, Error> {
            defer { self.finish(path) }

            let (data, response) = try await self.session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LoadError.badResponse
            }
            guard let image = UIImage(data: data) else {
                throw LoadError.undecodable
            }

            // Decode now, off the main thread, rather than on first draw in a
            // scrolling list.
            let prepared = await image.byPreparingForDisplay() ?? image
            self.store(prepared, for: path)
            return prepared
        }
        inFlight[path] = task
        return task
    }

    private func finish(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight[path] = nil
    }

    private static func cost(of image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return pixelWidth * pixelHeight * 4
    }
}
