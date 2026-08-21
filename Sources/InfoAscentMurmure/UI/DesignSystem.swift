import SwiftUI

/// Layout tokens.
///
/// Deliberately thin. The previous design system carried its own palette, its own type
/// ramp and a set of hand-drawn controls; all of that has been replaced by native AppKit
/// materials and system controls, which already adapt to light/dark, accent colour,
/// Increase Contrast and Reduce Motion without any code here. What remains is the handful
/// of numbers SwiftUI has no opinion about.
enum DS {
    /// An 4pt grid. Names describe intent, not size, so a value can be retuned in one place.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 28
    }

    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 10
        static let window: CGFloat = 16
    }

    enum Motion {
        /// The system's own spring. Honours Reduce Motion for free.
        static let standard = Animation.smooth(duration: 0.22)
        static let quick = Animation.smooth(duration: 0.14)
    }

    /// The one colour decision the app makes for itself: the recording accent.
    ///
    /// Everything else uses semantic system colours (`.primary`, `.secondary`,
    /// `Color.accentColor`) so the app follows the user's appearance settings.
    static let recording = Color.red
}
