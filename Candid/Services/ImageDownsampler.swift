import ImageIO
import UIKit

/// Decodes a photo straight to the size the app needs, without ever building
/// the full-size bitmap.
///
/// `UIImage(data:)` is cheap to create but decodes to the photo's full pixel
/// dimensions the moment it is drawn — for a 48-megapixel HEIC that is roughly
/// 200 MB, held for as long as the preview is on screen. ImageIO can instead
/// produce a thumbnail of a bounded size *while* decoding, subsampling as it
/// goes, so the peak is the output size: at 1600 px on the longest edge, about
/// 10 MB. `StorageService.downscaled` still runs at upload time as the safety
/// net that normalises whatever it is handed, but by then the image is already
/// small.
enum ImageDownsampler {
    /// An image whose longest edge is at most `maxPixelSize`, upright (EXIF
    /// orientation is applied during decode, so the result's orientation is
    /// `.up`) and at scale 1 — or nil if `data` is not a decodable image. A
    /// photo already within the limit is decoded at its own size, never
    /// enlarged.
    static func image(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            // From the full image, not any embedded thumbnail, which is
            // typically far smaller than the limit.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
