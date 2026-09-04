import Foundation
import Supabase
import UIKit

enum StorageServiceError: LocalizedError {
    case imageEncodingFailed
    case notPermitted(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "That image couldn't be prepared for upload."
        case .notPermitted(let message):
            return "Upload rejected: \(message)"
        case .other(let message):
            return message
        }
    }
}

/// Uploads post images to the private `post-images` bucket.
///
/// The bucket is private, so reads go through time-limited signed URLs rather
/// than permanent public ones. That means the durable identifier for an image
/// is its object *path*, and a URL is minted on demand at read time — see
/// `signedURLs(for:)`, which the feed uses.
struct StorageService {
    let client: SupabaseClient

    static let bucket = "post-images"

    /// Longest edge in pixels after downscaling.
    static let maxDimension: CGFloat = 1600
    static let jpegCompressionQuality: CGFloat = 0.8

    /// How long minted URLs stay valid. An hour is comfortably longer than a
    /// feed session while still expiring if one leaks.
    static let signedURLLifetime = 60 * 60

    /// Uploads the image and returns its object path, `{user_id}/{uuid}.jpg` —
    /// the value `posts.image_path` stores. Nothing needs a URL at upload time:
    /// the feed mints them when it reads. This used to mint one anyway, which
    /// was a wasted round trip with its own way to fail *after* the object was
    /// already up — and a retry then uploaded a second, orphaned copy.
    func uploadPostImage(_ image: UIImage, userId: UUID) async throws -> String {
        guard let data = Self.jpegData(for: image) else {
            throw StorageServiceError.imageEncodingFailed
        }

        // The storage policy requires the first path segment to equal the
        // caller's auth.uid(), so this layout is what makes "you can only write
        // to your own folder" enforceable server-side.
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"

        do {
            try await client.storage
                .from(Self.bucket)
                .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        } catch {
            throw Self.mapStorageError(error)
        }

        return path
    }

    /// Removes the object at `path`. Used to take back an upload whose post
    /// row could not be written; the storage policy allows deleting only
    /// within the caller's own folder.
    func deletePostImage(at path: String) async throws {
        do {
            try await client.storage
                .from(Self.bucket)
                .remove(paths: [path])
        } catch {
            throw Self.mapStorageError(error)
        }
    }

    /// Mints signed URLs for several objects in one request — what the feed
    /// (SOL-13) uses instead of one round trip per post.
    ///
    /// A path that fails to sign (e.g. the object went missing) is simply
    /// absent from the result rather than failing the whole batch; the caller
    /// decides how to handle a post whose image didn't come back.
    func signedURLs(
        for paths: [String],
        expiresIn: Int = StorageService.signedURLLifetime
    ) async throws -> [String: URL] {
        guard !paths.isEmpty else { return [:] }

        do {
            let results = try await client.storage
                .from(Self.bucket)
                .createSignedURLs(paths: paths, expiresIn: expiresIn)

            var urls: [String: URL] = [:]
            for result in results {
                if case .success(let path, let signedURL) = result {
                    urls[path] = signedURL
                }
            }
            return urls
        } catch {
            throw Self.mapStorageError(error)
        }
    }

    static func mapStorageError(_ error: Error) -> StorageServiceError {
        // StorageError, like PostgrestError, is a plain Error rather than a
        // LocalizedError, so its localizedDescription is generic Foundation
        // boilerplate with none of the server's detail. Read `message`.
        guard let storageError = error as? StorageError else {
            return .other(error.localizedDescription)
        }

        if storageError.statusCode == "403"
            || storageError.message.lowercased().contains("row-level security") {
            return .notPermitted(storageError.message)
        }

        return .other(storageError.message)
    }

    static func jpegData(for image: UIImage) -> Data? {
        downscaled(image).jpegData(compressionQuality: jpegCompressionQuality)
    }

    /// Downscales so the longest edge is at most `maxDimension` pixels.
    ///
    /// Always redraws, even when the image is already small enough: drawing
    /// normalises EXIF orientation, so the bytes uploaded are upright rather
    /// than upright-only-if-you-read-the-orientation-tag.
    static func downscaled(_ image: UIImage) -> UIImage {
        // `size` is in points; multiply by `scale` to reason in real pixels.
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )

        let longestEdge = max(pixelSize.width, pixelSize.height)
        let ratio = longestEdge > maxDimension ? maxDimension / longestEdge : 1

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
}
