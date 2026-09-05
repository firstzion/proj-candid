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

    /// What VoiceOver says once the image has loaded — the post's caption, or
    /// a fallback naming who posted it. The loading and missing states below
    /// have their own fixed wording regardless, since neither has content yet
    /// to describe.
    let accessibilityLabel: String

    /// How the loaded image sits in its container: `.fit` for a feed row or
    /// the detail view, `.fill` for a profile grid's square cell, which clips.
    let contentMode: ContentMode

    /// Height reserved while loading or when the image is missing. A feed row
    /// wants a row-sized placeholder; a grid cell wants none, since its
    /// square already has a size.
    let placeholderMinHeight: CGFloat

    /// When set, the image is decoded and cached at this size — pixels on the
    /// shorter edge, which is what a square cell needs to cover itself — via
    /// `ImageCache.thumbnail(for:from:side:)`. The profile grid sets it; the
    /// feed row and the detail view leave it nil and get the full image, which
    /// is what they draw.
    let thumbnailSide: CGFloat?

    /// Passed in rather than read from `@Environment(\.services)`: a cache
    /// hit has to render in the very first frame, in `init`, and environment
    /// values are not readable there.
    let imageCache: ImageCache

    @State private var phase: Phase

    private enum Phase {
        case loading
        case loaded(UIImage)
        case missing
    }

    init(
        path: String,
        url: URL?,
        accessibilityLabel: String,
        contentMode: ContentMode = .fit,
        placeholderMinHeight: CGFloat = 200,
        thumbnailSide: CGFloat? = nil,
        imageCache: ImageCache
    ) {
        self.path = path
        self.url = url
        self.accessibilityLabel = accessibilityLabel
        self.contentMode = contentMode
        self.placeholderMinHeight = placeholderMinHeight
        self.thumbnailSide = thumbnailSide
        self.imageCache = imageCache

        // Look in the keyspace this view will actually draw from: a cached
        // full image is no use to a grid cell that wants the thumbnail, since
        // showing it would be the oversized decode all over again.
        let cached: UIImage?
        if let thumbnailSide {
            cached = imageCache.cachedThumbnail(for: path, side: thumbnailSide)
        } else {
            cached = imageCache.cachedImage(for: path)
        }

        // A cache hit renders in the first frame; anything else starts as a
        // spinner and resolves in `load()`.
        if let cached {
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
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel(accessibilityLabel)
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: placeholderMinHeight)
                    .accessibilityLabel("Loading photo")
            case .missing:
                // The object could not be signed or fetched — most likely it
                // no longer exists. The post is still shown; see
                // `FeedPost.imageURL`.
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: placeholderMinHeight)
                    .accessibilityLabel("Photo unavailable")
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
            let image: UIImage
            if let thumbnailSide {
                image = try await imageCache.thumbnail(for: path, from: url, side: thumbnailSide)
            } else {
                image = try await imageCache.image(for: path, from: url)
            }
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
