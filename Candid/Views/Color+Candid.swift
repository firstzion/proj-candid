import SwiftUI

/// `Color.candidGround`, `.candidAccent`, etc. come from the asset catalog's
/// generated symbols (Cool Ash — Candid Design turn 2, option 2b, rolled
/// through every screen in turn 1) — no manual declaration needed here.
///
/// `accent` is already contrast-corrected for on-ash use (#52705A, darkened
/// from the nominal brand sage #5C7C63, which measured under AA and never
/// ships as a UI color). `border` is deliberately the same value in both
/// appearances and is for non-text elements only — hairlines and the
/// inactive tab icon — never body copy.
extension Color {
    /// The hairline/divider treatment used throughout the design: ink at
    /// 12–14% opacity. Dark-mode ink is already light-colored, so this one
    /// value is correct in both appearances without a separate asset.
    static var candidDivider: Color { .candidInk.opacity(0.12) }
}
