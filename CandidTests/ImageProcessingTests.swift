import Foundation
import Testing
import UIKit
@testable import Candid

/// `downscaled` decides what actually goes over the wire on every post, so its
/// arithmetic is worth pinning down.
@Suite("Image downscaling")
struct ImageProcessingTests {
    private func image(width: CGFloat, height: CGFloat, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                UIColor.systemPink.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    @Test("a landscape image is capped on its longest edge, keeping aspect ratio")
    func landscapeIsCapped() {
        let result = StorageService.downscaled(image(width: 3000, height: 2000))
        #expect(result.size.width == 1600)
        // 2000 * (1600/3000) = 1066.67, rounded to 1067.
        #expect(result.size.height == 1067)
    }

    @Test("a portrait image is capped on its height")
    func portraitIsCapped() {
        let result = StorageService.downscaled(image(width: 2000, height: 3000))
        #expect(result.size.height == 1600)
        #expect(result.size.width == 1067)
    }

    @Test("a square image stays square")
    func squareStaysSquare() {
        let result = StorageService.downscaled(image(width: 2400, height: 2400))
        #expect(result.size.width == 1600)
        #expect(result.size.height == 1600)
    }

    @Test("an image already within the cap is not enlarged")
    func smallImageIsNotUpscaled() {
        let result = StorageService.downscaled(image(width: 800, height: 600))
        #expect(result.size.width == 800)
        #expect(result.size.height == 600)
    }

    /// `size` is in points, so a 2x image is twice as many pixels as its size
    /// suggests. Downscaling has to reason in pixels or retina photos come out
    /// at double the intended resolution.
    @Test("scale is accounted for, so points are not mistaken for pixels")
    func retinaImageIsMeasuredInPixels() {
        // 1000pt x 1000pt at 2x = 2000x2000 pixels, so it must be downscaled.
        let result = StorageService.downscaled(image(width: 1000, height: 1000, scale: 2))
        #expect(result.size.width == 1600)
        #expect(result.size.height == 1600)
    }

    @Test("output is exactly the requested pixel size, not multiplied by screen scale")
    func outputScaleIsOne() {
        let result = StorageService.downscaled(image(width: 3000, height: 2000))
        #expect(result.scale == 1)
    }

    @Test("encoding produces JPEG data")
    func encodesToJPEG() throws {
        let data = try #require(StorageService.jpegData(for: image(width: 3000, height: 2000)))
        #expect(!data.isEmpty)
        // JPEG files start with the SOI marker FF D8 FF.
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }
}
