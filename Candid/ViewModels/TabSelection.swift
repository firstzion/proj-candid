import Foundation

/// Which tab is showing, so an empty state can send someone to the People tab
/// or the Post tab (SOL-40) — the one piece of plumbing the empty states
/// need. Owned by `RootTabView`, which binds the `TabView` to it, and shared
/// through the environment with the screens that jump.
@Observable
final class TabSelection {
    enum Tab: Hashable {
        case feed
        case post
        case people
        case profile
    }

    var selected: Tab = .feed
}
