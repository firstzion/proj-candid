import Foundation
import Testing
import UIKit
@testable import Candid

@Suite("Image cache")
struct ImageCacheTests {
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
    }

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
        let unreachable = URL(string: "https://invalid.invalid/would-fail-if-fetched")!
        let fetched = try await cache.image(for: "user/photo.jpg", from: unreachable)
        #expect(fetched === stored)
    }
}
