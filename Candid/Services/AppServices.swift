import Foundation
import Supabase
import SwiftUI

/// Every service the app's views can call, built once from the live client at
/// launch and handed down via the environment — see `CandidApp`. A view that
/// needs a service reads it from here instead of constructing one; nothing
/// below the app root reaches for a singleton.
struct AppServices {
    let auth: AuthService
    let profile: ProfileService
    let post: PostService
    let feed: FeedService
    let follow: FollowService
    let storage: StorageService
    let invite: InviteService
    let report: ReportService
    let imageCache: ImageCache

    init(client: SupabaseClient, imageCache: ImageCache = ImageCache()) {
        auth = AuthService(client: client)
        profile = ProfileService(client: client)
        post = PostService(client: client, imageCache: imageCache)
        feed = FeedService(client: client)
        follow = FollowService(client: client)
        storage = StorageService(client: client)
        invite = InviteService(client: client)
        report = ReportService(client: client)
        self.imageCache = imageCache
    }
}

private struct AppServicesKey: EnvironmentKey {
    /// A preview default: every call through it fails gracefully, landing in
    /// the view's own error state, so a `#Preview` needs no injection.
    static let defaultValue = AppServices(client: .preview)
}

extension EnvironmentValues {
    /// Set once, at the root, by `CandidApp`.
    var services: AppServices {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}
