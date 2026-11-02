import CoreGraphics

/// When a window counts as filling its screen, and when a change of its size counts as a zoom
/// (or an unzoom): every such test, in one place. Each keeps the margin it was tuned with, as
/// they answer different questions.
public enum ScreenFill {
    /// Covers nearly all of the screen's visible area `v` (95% each way), the way a window
    /// zoomed by its app does: made to fill the screen some other way than by Oz.
    public static func covers(_ r: CGRect, visible v: CGRect) -> Bool {
        r.width >= v.width * 0.95 && r.height >= v.height * 0.95
    }

    /// Reaches every edge of `area` (to 4 pt): Oz's own placements keep the outer gap, so
    /// they never do; a window that does was made to fill the screen by its app.
    public static func reaches(_ r: CGRect, _ area: CGRect) -> Bool {
        r.width >= area.width - 4 && r.height >= area.height - 4
    }

    /// Took the size Oz asked for to fill the screen (to 4 pt each way).
    public static func took(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.width - target.width) <= 4 && abs(actual.height - target.height) <= 4
    }

    /// A tiled window's app resized it after a title bar double click: by more than 20 pt
    /// either way (a toolbar button clicked twice doesn't).
    public static func resized(_ actual: CGRect, from before: CGRect) -> Bool {
        abs(actual.width - before.width) > 20 || abs(actual.height - before.height) > 20
    }

    /// How much a floating window's area must change for a double click to have zoomed or
    /// unzoomed it (pt²: a 400 pt strip 20 pt high).
    static let zoomArea: CGFloat = 400 * 20

    /// A floating window got bigger after a double click: its app zoomed it.
    public static func grew(_ actual: CGRect, from before: CGRect) -> Bool {
        actual.width * actual.height > before.width * before.height + zoomArea
    }

    /// A zoomed floating window got smaller after a double click: its app unzoomed it.
    public static func shrank(_ actual: CGRect, from zoomed: CGRect) -> Bool {
        actual.width * actual.height < zoomed.width * zoomed.height - zoomArea
    }
}
