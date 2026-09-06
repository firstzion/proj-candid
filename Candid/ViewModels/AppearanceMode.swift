import SwiftUI

/// The user's chosen appearance override — System follows the device
/// setting; Light/Dark pin the app regardless of it. Persisted under
/// `"appearanceMode"` via `@AppStorage`, which keeps every view that reads it
/// in sync automatically: `RootView` applies it with `.preferredColorScheme`,
/// and `ProfileScreen` offers the switcher.
enum AppearanceMode: Int, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` tells `.preferredColorScheme` to follow the system, which is
    /// exactly what "Auto" means here.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
