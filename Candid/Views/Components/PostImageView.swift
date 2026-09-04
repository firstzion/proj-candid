import SwiftUI

/// A post's image, from `ImageCache` — loaded on first sight, instant after.
///
/// Replaces `AsyncImage`, which keys its loading on the URL: a signed URL is
/// different every time it is minted, so `AsyncImage` re-downloaded every
/// image on every refresh and again for every row scrolled off and back. This
/// keys on the storage path and asks the cache synchronously first, so a
/// cached image is on screen in the row's first frame with no spinner.
struct PostImageView: View {
    /// The storage path — the image's durable identity and the cache key.
    let path: String

    /// Where to fetch it this time, or nil if the object could not be signed —
    /// see `FeedPost.imageURL`.
    let url: URL?

    @State private var phase: Phase

    private enum Phase {
        case loading
        case loaded(UIImage)
        case missing
    }

    init(path: String, url: URL?) {
        self.path = path
        self.url = url
        // A cache hit renders in the first frame; anything else starts as a
        // spinner and resolves in `load()`.
        if let cached = ImageCache.shared.cachedImage(for: path) {
            _phase = State(initialValue: .loaded(cached))
        } else {
            _phase = State(initialValue: url == nil ? .missing : .loading)
        }
    }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .missing:
                // The object could not be signed or fetched — most likely it
                // no longer exists. The post is still shown; see
                // `FeedPost.imageURL`.
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        // Keyed on the URL so a refresh that re-mints it re-runs this — and
        // finds the cache already warm.
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .missing
            return
        }
        if case .loaded = phase {
            return
        }
        do {
            let image = try await ImageCache.shared.image(for: path, from: url)
            phase = .loaded(image)
        } catch {
            // Not on cancellation: the row scrolled away before the bytes
            // arrived, and it will ask again — from the cache, if the download
            // finished — when it comes back.
            if !Task.isCancelled {
                phase = .missing
            }
        }
    }
}
