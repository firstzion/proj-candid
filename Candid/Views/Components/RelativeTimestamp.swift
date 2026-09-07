import SwiftUI

/// When something was posted, the way the feed has always said it: a named
/// relative date for the first week ("2 days ago"), an absolute month and
/// day after that. Extracted from `FeedPostRow` so the comment thread
/// (SOL-90) shares one definition rather than growing a second one.
///
/// A `Text` underneath, so callers style it with `.font` and
/// `.foregroundStyle` like any other line.
struct RelativeTimestamp: View {
    let date: Date

    /// How long a date stays relative before switching to absolute. Three
    /// months ago reading "12 wk" is not more useful than "Jun 12", and it
    /// stops changing every time the row re-renders.
    static let relativeCutoff: TimeInterval = 7 * 24 * 60 * 60

    var body: some View {
        if Date.now.timeIntervalSince(date) > Self.relativeCutoff {
            Text(date, format: .dateTime.month().day())
        } else {
            Text(date, format: .relative(presentation: .named))
        }
    }
}
