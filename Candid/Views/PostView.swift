import PhotosUI
import SwiftUI
import UIKit

struct PostView: View {
    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation

    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var caption = ""

    /// Who can see the post. Starts at the tier the schema defaults to and
    /// then keeps whatever was chosen last, rather than snapping back after
    /// every post: of the two mistakes a reset invites, sending a friends-only
    /// photo to every follower is the one that can't be taken back.
    @State private var visibility: PostVisibility = .default

    @State private var isLoadingImage = false
    @State private var isPosting = false
    @State private var message: FormMessage?
    @State private var isShowingCamera = false

    /// The in-flight load — a library pick being decoded or a camera capture
    /// being downscaled — so a newer one cancels it rather than racing it. See
    /// `loadSelectedImage`.
    @State private var imageLoadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    photoPreview
                        .padding(.top, 4)

                    HStack {
                        Spacer()
                        photoPickerCapsule
                        Spacer()
                    }
                    .padding(.top, 14)
                    .disabled(isPosting)

                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(Color.candidDivider).frame(height: 0.5)
                        TextField("", text: $caption, axis: .vertical)
                            .font(.newsreader(17.5))
                            .foregroundStyle(.candidBody)
                            .tint(.candidAccent)
                            .lineLimit(1...4)
                            .disabled(isPosting)
                            .padding(.top, 16)
                            .accessibilityLabel("Caption")
                        Text("Caption optional")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.candidFaint)
                            .padding(.top, 10)
                    }
                    .padding(.top, 26)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Who can see this")
                            .font(.system(size: 13))
                            .foregroundStyle(.candidMuted)
                        VisibilityToggle(selection: $visibility)
                            .disabled(isPosting)
                        Text("Friends are people you follow who follow you back. A post's audience can't be changed later — delete and repost instead.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.candidFaint)
                    }
                    .padding(.top, 30)

                    AsyncSubmitButton("Post", isSubmitting: isPosting, isEnabled: selectedImage != nil) {
                        await post()
                    }
                    .padding(.top, 30)

                    FormMessageSection(message: message)
                        .padding(.top, message == nil ? 0 : 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color.candidGround)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New Post")
                        .font(.newsreader(19))
                        .foregroundStyle(.candidInk)
                }
            }
            .toolbarBackground(Color.candidGround, for: .navigationBar)
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
                imageLoadTask?.cancel()
                imageLoadTask = Task { await useCapturedImage(captured) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .aspectRatio(4 / 5, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipped()
        } else if isLoadingImage {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.candidSurface)
                .frame(maxWidth: .infinity)
                .frame(height: 400)
                .overlay { ProgressView() }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.candidSurface)
                .frame(maxWidth: .infinity)
                .frame(height: 400)
                .overlay {
                    Text("No photo selected yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.candidFaint)
                }
        }
    }

    /// One capsule standing in for both photo sources — the design shows a
    /// single "Choose another" capsule, and a `Menu` keeps the camera option
    /// (which the mock doesn't cover at all) without adding a second control.
    private var photoPickerCapsule: some View {
        Menu {
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
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 14))
                Text(selectedImage == nil ? "Choose Photo" : "Choose Another")
                    .font(.system(size: 14.5))
            }
            .foregroundStyle(.candidMuted)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .overlay {
                Capsule().strokeBorder(Color.candidBorder.opacity(0.6))
            }
        }
    }

    /// Loads the picked photo. Picking again while a load is in flight cancels
    /// the earlier task, and both paths below re-check that this load is still
    /// the current one before touching any state. Without that, two loads
    /// raced: whichever finished last set the preview — sometimes the *older*
    /// photo — and the first to finish took the spinner down while the other
    /// was still running.
    private func loadSelectedImage(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        message = nil

        let image: UIImage?
        do {
            let data = try await item.loadTransferable(type: Data.self)
            image = await Self.downsampled(data)
        } catch {
            // Superseded by a newer pick or a camera capture, which now owns
            // the spinner and the message; a cancelled load lands here too.
            guard isCurrentLoad(for: item) else { return }
            message = .failure(error.localizedDescription)
            isLoadingImage = false
            return
        }

        guard isCurrentLoad(for: item) else { return }

        if let image {
            selectedImage = image
        } else {
            // Keep whatever was already chosen rather than blanking the
            // preview because one load failed.
            message = .failure("That photo couldn't be loaded. Try another one.")
        }
        isLoadingImage = false
    }

    /// A camera capture arrives as a full-resolution `UIImage` — decoded, it
    /// is tens of megabytes. Bring it down to the upload size before it is
    /// held in state or drawn, off the main actor so dismissing the camera
    /// does not hitch.
    private func useCapturedImage(_ captured: UIImage) async {
        isLoadingImage = true
        message = nil

        let image = await Task.detached(priority: .userInitiated) {
            StorageService.downscaled(captured)
        }.value

        guard !Task.isCancelled else { return }
        selectedImage = image
        isLoadingImage = false
    }

    /// Whether the load for `item` is still the one that should update the
    /// screen. Every superseding action — a new pick, a capture, clearing the
    /// picker after a post — cancels the previous task first, so cancellation
    /// alone would do; the selection check is insurance against a
    /// `loadTransferable` that ignores cancellation and finishes anyway.
    private func isCurrentLoad(for item: PhotosPickerItem) -> Bool {
        !Task.isCancelled && pickerItem == item
    }

    /// Decodes straight to the upload size, off the main actor: decoding is
    /// the expensive part of picking a photo, and this way the full-size
    /// bitmap is never built — see `ImageDownsampler`.
    private static func downsampled(_ data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampler.image(from: data, maxPixelSize: StorageService.maxDimension)
        }.value
    }

    private func post() async {
        guard let image = selectedImage else {
            message = .failure(PostError.noImageSelected.localizedDescription)
            return
        }

        isPosting = true
        message = nil

        do {
            try await services.post.createPost(image: image, caption: caption, visibility: visibility)
            // Only reset once the row is actually written, so a failure leaves
            // the photo and caption in place to retry rather than discarding
            // work the person would have to redo. `visibility` deliberately
            // stays as chosen — see its declaration.
            selectedImage = nil
            pickerItem = nil
            caption = ""
            message = .success("Posted.")
            // Tells the Feed tab to refresh even if it isn't stale yet, so
            // switching over shows this post instead of "where did it go?".
            feedInvalidation.markStale()
        } catch {
            message = .failure(error.localizedDescription)
        }

        isPosting = false
    }
}

/// Two-segment capsule, filled with the accent when selected — the design
/// never shows this control at all (its compose mock has no visibility
/// picker), so this follows the capsule vocabulary the mock uses elsewhere
/// ("Choose another", the primary button) rather than retinting the native
/// segmented control.
private struct VisibilityToggle: View {
    @Binding var selection: PostVisibility

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PostVisibility.allCases, id: \.self) { tier in
                let isSelected = tier == selection
                Button {
                    selection = tier
                } label: {
                    Text(tier.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.candidGround : Color.candidInk)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background {
                            Capsule().fill(isSelected ? Color.candidAccent : Color.clear)
                        }
                        .overlay {
                            Capsule().strokeBorder(Color.candidBorder.opacity(isSelected ? 0 : 0.6))
                        }
                }
                .buttonStyle(.plain)
            }
        }
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
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
}
