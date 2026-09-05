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

    init(client: SupabaseClient) {
        auth = AuthService(client: client)
        profile = ProfileService(client: client)
        post = PostService(client: client)
        feed = FeedService(client: client)
        follow = FollowService(client: client)
        storage = StorageService(client: client)
        invite = InviteService(client: client)
    }
}

private struct AppServicesKey: EnvironmentKey {
    static let defaultValue: AppServices? = nil
}

extension EnvironmentValues {
    /// Set once, at the root, by `CandidApp`. Every view under `RootView` can
    /// rely on this being non-nil — `CandidApp` shows a configuration-error
    /// screen instead of `RootView` when the client can't be built, so
    /// nothing that reads this ever renders otherwise.
    var services: AppServices? {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}
