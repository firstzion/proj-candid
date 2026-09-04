import SwiftUI

struct PostView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Post")

            #if DEBUG
            StorageUploadCheck()
            #endif
        }
        .padding()
    }
}

#if DEBUG
import Supabase
import UIKit

/// Debug-only harness for SOL-9: exercises `StorageService` before there is any
/// compose UI. Replaced by the real post flow in SOL-11.
private struct StorageUploadCheck: View {
    private enum Outcome {
        case idle
        case running
        case uploaded(UploadedImage, byteCount: Int, pixels: CGSize)
        case rejectedAsExpected(String)
        case unexpected(String)
    }

    @State private var outcome: Outcome = .idle

    var body: some View {
        VStack(spacing: 12) {
            Button("Upload Test Image") {
                Task { await runUpload() }
            }
            .disabled(isRunning)

            Button("Try Upload To Another User's Folder") {
                Task { await runForbiddenUpload() }
            }
            .disabled(isRunning)

            switch outcome {
            case .idle:
                EmptyView()

            case .running:
                ProgressView()

            case .uploaded(let uploaded, let byteCount, let pixels):
                VStack(spacing: 6) {
                    Text("Uploaded \(Int(pixels.width))×\(Int(pixels.height)), \(byteCount / 1024) KB")
                        .foregroundStyle(.green)
                    Text(uploaded.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Rendering through the signed URL is the proof it works.
                    AsyncImage(url: uploaded.signedURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(height: 120)
                }

            case .rejectedAsExpected(let message):
                Text("Rejected as expected: \(message)")
                    .foregroundStyle(.green)

            case .unexpected(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .font(.footnote)
    }

    private var isRunning: Bool {
        if case .running = outcome { return true }
        return false
    }

    private func runUpload() async {
        outcome = .running
        do {
            let client = try SupabaseService.shared.client()
            let userId = try await client.auth.session.user.id

            let image = Self.makeTestImage()
            let uploaded = try await StorageService().uploadPostImage(image, userId: userId)

            // Report what actually went over the wire, so the downscale and
            // compression are visible rather than assumed.
            let processed = StorageService.downscaled(image)
            let bytes = StorageService.jpegData(for: image)?.count ?? 0
            outcome = .uploaded(
                uploaded,
                byteCount: bytes,
                pixels: CGSize(width: processed.size.width, height: processed.size.height)
            )
        } catch {
            outcome = .unexpected(error.localizedDescription)
        }
    }

    /// Writes straight through the client with a deliberately wrong folder, to
    /// confirm the storage policy rejects it. Goes around `StorageService` on
    /// purpose: building a bad path is not something the real API should offer.
    private func runForbiddenUpload() async {
        outcome = .running
        do {
            let client = try SupabaseService.shared.client()
            let someoneElse = UUID().uuidString.lowercased()
            let path = "\(someoneElse)/\(UUID().uuidString.lowercased()).jpg"

            guard let data = StorageService.jpegData(for: Self.makeTestImage()) else {
                outcome = .unexpected("Could not encode the test image.")
                return
            }

            try await client.storage
                .from(StorageService.bucket)
                .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))

            outcome = .unexpected("SECURITY PROBLEM: upload to another user's folder succeeded.")
        } catch {
            let mapped = StorageService.mapStorageError(error)
            if case .notPermitted(let message) = mapped {
                outcome = .rejectedAsExpected(message)
            } else {
                outcome = .unexpected("Rejected, but not as a permission error: \(mapped.localizedDescription)")
            }
        }
    }

    /// A deliberately oversized image (3000×2000) so the 1600px downscale is
    /// actually exercised.
    private static func makeTestImage() -> UIImage {
        let size = CGSize(width: 3000, height: 2000)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))

            UIColor.systemTeal.setFill()
            context.cgContext.fillEllipse(
                in: CGRect(x: size.width / 4, y: size.height / 4,
                           width: size.width / 2, height: size.height / 2)
            )
        }
    }
}
#endif

#Preview {
    PostView()
}
