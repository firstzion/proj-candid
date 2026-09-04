import PhotosUI
import SwiftUI
import UIKit

struct PostView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var caption = ""
    @State private var isLoadingImage = false
    @State private var isPosting = false
    @State private var message: FormMessage?
    @State private var isShowingCamera = false

    /// The in-flight load for the current `pickerItem`, so picking again
    /// cancels it rather than racing it — see `loadSelectedImage`.
    @State private var imageLoadTask: Task<Void, Never>?

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

                    // Only offered where a camera exists.
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo") { isShowingCamera = true }
                    }
                }
                .disabled(isPosting)

                Section("Caption") {
                    TextField("Optional", text: $caption, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(isPosting)
                }

                Section {
                    AsyncSubmitButton("Post", isSubmitting: isPosting, isEnabled: selectedImage != nil) {
                        await post()
                    }
                }

                FormMessageSection(message: message)
            }
            .navigationTitle("New Post")
        }
        // Cancelling the picker leaves the selection untouched, so the previous
        // photo simply stays.
        .onChange(of: pickerItem) { _, newItem in
            imageLoadTask?.cancel()
            guard let newItem else {
                // Cleared programmatically, after a post. Any load still in
                // flight was just cancelled and must not leave the spinner up.
                isLoadingImage = false
                return
            }
            imageLoadTask = Task { await loadSelectedImage(newItem) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { captured in
                selectedImage = captured
                message = nil
            }
            .ignoresSafeArea()
        }
    }

    /// Loads the picked photo. Picking again while a load is in flight cancels
    /// the earlier task, and both paths below re-check that `item` is still
    /// the selection before touching any state. Without that, two loads raced:
    /// whichever finished last set the preview — sometimes the *older* photo —
    /// and the first to finish took the spinner down while the other was still
    /// running.
    private func loadSelectedImage(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        message = nil

        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            // Superseded by a newer pick, which now owns the spinner and the
            // message; a cancelled load lands here too.
            guard pickerItem == item else { return }
            message = .failure(error.localizedDescription)
            isLoadingImage = false
            return
        }

        guard pickerItem == item else { return }

        if let data, let image = UIImage(data: data) {
            selectedImage = image
        } else {
            // Keep whatever was already chosen rather than blanking the
            // preview because one load failed.
            message = .failure("That photo couldn't be loaded. Try another one.")
        }
        isLoadingImage = false
    }

    private func post() async {
        guard let image = selectedImage else {
            message = .failure(PostError.noImageSelected.localizedDescription)
            return
        }

        isPosting = true
        message = nil

        do {
            try await PostService().createPost(image: image, caption: caption)
            // Only reset once the row is actually written, so a failure leaves
            // the photo and caption in place to retry rather than discarding
            // work the person would have to redo.
            selectedImage = nil
            pickerItem = nil
            caption = ""
            message = .success("Posted.")
        } catch {
            message = .failure(error.localizedDescription)
        }

        isPosting = false
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

#Preview {
    PostView()
}
