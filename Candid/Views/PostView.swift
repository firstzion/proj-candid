import PhotosUI
import SwiftUI
import UIKit

struct PostView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var caption = ""
    @State private var isLoadingImage = false
    @State private var loadError: String?
    @State private var isShowingCamera = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 320)
                    } else if isLoadingImage {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Text("No photo selected yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    PhotosPicker(
                        selectedImage == nil ? "Choose Photo" : "Choose a Different Photo",
                        selection: $pickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    )

                    // Only offered where a camera exists — it never does in the
                    // Simulator, and showing a button that cannot work is worse
                    // than not showing one.
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo") { isShowingCamera = true }
                    }
                }

                Section("Caption") {
                    TextField("Optional", text: $caption, axis: .vertical)
                        .lineLimit(1...4)
                }

                FormMessageSection(message: loadError)

                #if DEBUG
                Section("Debug") {
                    StorageUploadCheck()
                }
                #endif
            }
            .navigationTitle("New Post")
        }
        // Cancelling the picker leaves the selection untouched, so there is
        // nothing to handle for that case: the previous photo simply stays.
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadSelectedImage(newItem) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { captured in
                selectedImage = captured
            }
            .ignoresSafeArea()
        }
    }

    private func loadSelectedImage(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        loadError = nil

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                // Keep whatever was already chosen rather than blanking the
                // preview because one load failed.
                loadError = "That photo couldn't be loaded. Try another one."
                isLoadingImage = false
                return
            }
            selectedImage = image
        } catch {
            loadError = error.localizedDescription
        }

        isLoadingImage = false
    }
}

/// Thin wrapper over `UIImagePickerController` for camera capture. SwiftUI has
/// no native camera control; `PhotosPicker` only reads the library.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

#if DEBUG
import Supabase

/// Debug-only harness from SOL-9, kept until SOL-11 wires the real upload.
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
        VStack(alignment: .leading, spacing: 10) {
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
                Text("Uploaded \(Int(pixels.width))×\(Int(pixels.height)), \(byteCount / 1024) KB")
                    .foregroundStyle(.green)
                Text(uploaded.path).font(.caption2).foregroundStyle(.secondary)
                AsyncImage(url: uploaded.signedURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(height: 100)
            case .rejectedAsExpected(let message):
                Text("Rejected as expected: \(message)").foregroundStyle(.green)
            case .unexpected(let message):
                Text(message).foregroundStyle(.red)
            }
        }
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

    private func runForbiddenUpload() async {
        outcome = .running
        do {
            let client = try SupabaseService.shared.client()
            let path = "\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"

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
