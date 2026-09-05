import OSLog

/// The app's loggers: one subsystem, a category per layer, so Console can be
/// filtered to either without searching message text.
///
/// What belongs here is the detail a developer needs and a person does not.
/// Chiefly the server's own words for a failure — which used to go straight to
/// the screen, see `fallbackMessage(for:context:)` — and the paths that give
/// up quietly on purpose, like the storage cleanup after an account is already
/// gone, where there is no one left to tell.
///
/// Everything logged so far is our own text, never the person's, which is why
/// the call sites mark it `privacy: .public`: the default would redact exactly
/// the part that makes the line worth having.
enum Log {
    static let services = Logger(subsystem: subsystem, category: "services")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    private static let subsystem = "com.firstzion.candid"
}
