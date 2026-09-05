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
///
/// Two keyspaces share that limit: full images under the path, and grid
/// thumbnails under `path#side` (see `thumbnail(for:from:side:)`). A profile
/// grid asks for the second, because a cell about 130 pt wide drawing a
/// 1600 px upload was decoding a bitmap roughly sixteen times the area it
/// draws — a page of twenty filled the whole cache and evicted itself.
final class ImageCache: @unchecked Sendable {
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

    /// The cached thumbnail for `path` at `side`, if it is already here —
    /// synchronous, for the same first-frame reason as `cachedImage`.
    func cachedThumbnail(for path: String, side: CGFloat) -> UIImage? {
        cache.object(forKey: Self.thumbnailKey(path, side) as NSString)
    }

    /// The image for `path` scaled so its *shorter* edge is `side` pixels —
    /// what a square grid cell needs, since the cell clips whatever overflows
    /// it (`contentMode: .fill`). Capping the longer edge instead would hand
    /// the cell an image too small to cover it, and the upscale to fill would
    /// undo the point of thumbnailing.
    ///
    /// The full image is fetched through `image(for:from:)`, so an in-flight
    /// download is shared with whatever else wants that path, and a photo
    /// already on screen at full size costs nothing here. It is then *kept*
    /// alongside the thumbnail rather than dropped: tapping a cell opens
    /// `PostDetailView`, which wants exactly that image, and the cost limit
    /// already evicts under pressure. The two sit under different keys and are
    /// charged separately.
    func thumbnail(for path: String, from url: URL, side: CGFloat) async throws -> UIImage {
        if let cached = cachedThumbnail(for: path, side: side) {
            return cached
        }
        let full = try await image(for: path, from: url)
        let thumbnail = Self.scaledToShorterEdge(full, side: side)
        cache.setObject(
            thumbnail,
            forKey: Self.thumbnailKey(path, side) as NSString,
            cost: Self.cost(of: thumbnail)
        )
        return thumbnail
    }

    /// Thumbnails share one `NSCache` with full images, so the key has to say
    /// which it is and at what size. A storage path is `{uuid}/{uuid}.jpg`
    /// (see `StorageService`), so `#` cannot occur in one and the two
    /// keyspaces cannot collide.
    private static func thumbnailKey(_ path: String, _ side: CGFloat) -> String {
        "\(path)#\(Int(side.rounded()))"
    }

    /// Redraws so the shorter edge is `side` pixels, keeping the aspect ratio.
    ///
    /// The sibling of `StorageService.downscaled`, which caps the *longer*
    /// edge because an upload wants to fit inside a bound; a grid cell wants
    /// to fill one. An image whose shorter edge is already within `side` comes
    /// back untouched — enlarging it would cost memory and add no detail.
    static func scaledToShorterEdge(_ image: UIImage, side: CGFloat) -> UIImage {
        // `size` is in points; multiply by `scale` to reason in real pixels.
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )

        let shorterEdge = min(pixelSize.width, pixelSize.height)
        guard shorterEdge > side else { return image }

        let ratio = side / shorterEdge
        let target = CGSize(
            width: max(1, (pixelSize.width * ratio).rounded()),
            height: max(1, (pixelSize.height * ratio).rounded())
        )

        // scale = 1 so the output is exactly `target` pixels rather than
        // `target` multiplied by the device's screen scale.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
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
