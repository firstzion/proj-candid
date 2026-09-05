import Foundation
import Testing
import UIKit
@testable import Candid

@Suite("Image cache")
struct ImageCacheTests {
    private func image(width: CGFloat = 4, height: CGFloat = 4) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    private let unreachable = URL(string: "https://invalid.invalid/would-fail-if-fetched")!

    @Test("a stored image comes back by path, synchronously")
    func storeAndHit() {
        let cache = ImageCache()
        let stored = image()
        cache.store(stored, for: "user/photo.jpg")
        #expect(cache.cachedImage(for: "user/photo.jpg") === stored)
        #expect(cache.cachedImage(for: "user/other.jpg") == nil)
    }

    /// The whole point of keying on the path: a re-minted URL must not cause a
    /// download when the image is already here. The URL below cannot resolve,
    /// so a fetch would fail the test.
    @Test("a cached path is served without touching the URL")
    func hitSkipsNetwork() async throws {
        let cache = ImageCache()
        let stored = image()
        cache.store(stored, for: "user/photo.jpg")
        let fetched = try await cache.image(for: "user/photo.jpg", from: unreachable)
        #expect(fetched === stored)
    }

    // MARK: - Grid thumbnails (SOL-80)

    /// A square grid cell covers itself by clipping the overflow, so it is the
    /// *shorter* edge that has to reach the cell's size. Capping the longer
    /// edge — what a fit-shaped downscale like `StorageService.downscaled`
    /// does — would hand the cell an image too small and leave it upscaling.
    @Test("a thumbnail is scaled on its shorter edge, keeping aspect ratio")
    func scalesShorterEdge() {
        let landscape = ImageCache.scaledToShorterEdge(image(width: 800, height: 400), side: 100)
        #expect(landscape.size.width == 200)
        #expect(landscape.size.height == 100)

        let portrait = ImageCache.scaledToShorterEdge(image(width: 400, height: 800), side: 100)
        #expect(portrait.size.width == 100)
        #expect(portrait.size.height == 200)
    }

    @Test("an image already smaller than the cell is used as it is, not enlarged")
    func doesNotUpscale() {
        let small = image(width: 50, height: 40)
        #expect(ImageCache.scaledToShorterEdge(small, side: 100) === small)
    }

    /// The thumbnail comes off the full image already in the cache — no second
    /// download — and both stay, so tapping the cell opens `PostDetailView` on
    /// an image that is still warm.
    @Test("a thumbnail is derived from the cached full image and kept under its own key")
    func thumbnailUsesCachedFullImage() async throws {
        let cache = ImageCache()
        let full = image(width: 800, height: 400)
        cache.store(full, for: "user/photo.jpg")

        let thumbnail = try await cache.thumbnail(for: "user/photo.jpg", from: unreachable, side: 100)

        #expect(thumbnail.size.width == 200)
        #expect(thumbnail.size.height == 100)
        #expect(cache.cachedThumbnail(for: "user/photo.jpg", side: 100) === thumbnail)
        #expect(cache.cachedImage(for: "user/photo.jpg") === full)
        // A different size is a different key, not a hit on this one.
        #expect(cache.cachedThumbnail(for: "user/photo.jpg", side: 200) == nil)
    }

    @Test("a cached thumbnail is served without touching the URL or rescaling")
    func thumbnailHitSkipsNetwork() async throws {
        let cache = ImageCache()
        cache.store(image(width: 800, height: 400), for: "user/photo.jpg")

        let first = try await cache.thumbnail(for: "user/photo.jpg", from: unreachable, side: 100)
        let second = try await cache.thumbnail(for: "user/photo.jpg", from: unreachable, side: 100)
        #expect(first === second)
    }

    /// The card's point as one number. A 1600×1200 upload in a cell asking for
    /// 450 becomes 600×450: 270,000 pixels against 1,920,000, so about a
    /// seventh of the bitmap — and a page of twenty grid cells stops being
    /// more than the whole cache can hold.
    @Test("a thumbnail costs a fraction of the full image it came from")
    func thumbnailIsCheaperThanTheFullImage() async throws {
        let cache = ImageCache()
        cache.store(image(width: 1600, height: 1200), for: "user/photo.jpg")

        let thumbnail = try await cache.thumbnail(for: "user/photo.jpg", from: unreachable, side: 450)

        let thumbnailPixels = Int(thumbnail.size.width * thumbnail.size.height)
        #expect(thumbnailPixels * 4 < 1600 * 1200)
    }
}
