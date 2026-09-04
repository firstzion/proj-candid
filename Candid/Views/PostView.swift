import PhotosUI
import SwiftUI
import UIKit

struct PostView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var caption = ""
    @State private var isLoadingImage = false
    @State private var isPosting = false
    @State private var message: Message?
    @State private var isShowingCamera = false

    private enum Message {
        case posted
        case failed(String)
    }

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

                switch message {
                case .posted:
                    Section {
                        Text("Posted.").foregroundStyle(.green)
                    }
                case .failed(let text):
                    FormMessageSection(message: text)
                case nil:
                    EmptyView()
                }
            }
            .navigationTitle("New Post")
        }
        // Cancelling the picker leaves the selection untouched, so the previous
        // photo simply stays.
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadSelectedImage(newItem) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { captured in
                selectedImage = captured
                message = nil
            }
            .ignoresSafeArea()
        }
    }

    private func loadSelectedImage(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        message = nil

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                // Keep whatever was already chosen rather than blanking the
                // preview because one load failed.
                message = .failed("That photo couldn't be loaded. Try another one.")
                isLoadingImage = false
                return
            }
            selectedImage = image
        } catch {
            message = .failed(error.localizedDescription)
        }

        isLoadingImage = false
    }

    private func post() async {
        guard let image = selectedImage else {
            message = .failed(PostError.noImageSelected.localizedDescription)
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
            message = .posted
        } catch {
            message = .failed(error.localizedDescription)
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
