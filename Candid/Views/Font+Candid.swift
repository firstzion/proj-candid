import SwiftUI

/// Newsreader (OFL, bundled under Resources/Fonts) is what anything a person
/// wrote is set in — usernames, captions, titles — everywhere the design
/// uses SF Pro instead is system chrome (buttons, field labels, nav back).
///
/// It's a variable font; "16pt" in the PostScript name is Google's optical-
/// size-range label for this cut, not a fixed rendering size. The design
/// only ever calls for the Regular/Italic default instance (wght 400) — no
/// other weight appears in Newsreader anywhere in the spec.
extension Font {
    static func newsreader(_ size: CGFloat) -> Font {
        .custom("Newsreader16pt-Regular", size: size)
    }

    static func newsreaderItalic(_ size: CGFloat) -> Font {
        .custom("Newsreader16pt-Italic", size: size)
    }
}
