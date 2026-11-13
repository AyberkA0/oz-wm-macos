import Foundation

/// How long Oz waits for things, and how long something counts as "just now": every tuned
/// time in one place, in seconds. Most were measured against real apps; see where each is used.
enum Timing {
    // MARK: Who did it

    /// A move or resize macOS reported while the mouse was dragging counts as the user's
    /// for this long (the frame check runs once the button is up).
    static let byUser: CFTimeInterval = 3
    /// A drag lands where the mouse was let go, if that was this recent.
    static let mouseUpLanding: CFTimeInterval = 3
    /// A window let go in the zone is placed in its slot if its frame check comes this soon.
    static let dropLanding: CFTimeInterval = 5
    /// A move notification this soon after Oz moved a docked or floating window is Oz's own.
    static let ozMoveEcho: CFTimeInterval = 0.6
    /// An app that changes a tiled window's width again this soon after Oz put it back keeps it.
    static let appInsists: CFTimeInterval = 5
    /// Focus changes this soon after unlocking are macOS giving focus back, not the user.
    static let refocusAfterUnlock: CFTimeInterval = 2

    // MARK: Waiting for apps and macOS

    /// A window's frame is read this long after it last moved or resized (it has settled).
    static let frameCheck: CFTimeInterval = 0.4
    /// An app is given this long to zoom or unzoom a window after a title bar double click.
    static let zoomAnswer: CFTimeInterval = 0.35
    /// Full screen sets its flag as the window starts growing: asked this much later.
    static let fullScreenFlag: CFTimeInterval = 0.3
    /// Restored from filling the screen, a window is placed once more after this long (the
    /// app's own unzoom may land after Oz's).
    static let unzoomAgain: CFTimeInterval = 0.3
    /// Beyond its animation, how long a window Oz made fill the screen has to take that size.
    static let forcedZoomCheck: CFTimeInterval = 0.4
    /// A docked window is checked this long after docking (macOS's own tiling may land later).
    static let dockCheck: CFTimeInterval = 0.6
    /// A torn-off tab let go before Oz saw its window is placed after this long.
    static let tornOffDrop: CFTimeInterval = 0.3
    /// A window Oz just placed is checked again after these times (some apps put it back).
    static let placementChecks: [CFTimeInterval] = [0.8, 2.0]
    /// A launched app's windows are looked for after these times (the first one often exists
    /// before Oz's observer is registered).
    static let launchScans: [CFTimeInterval] = [0.3, 1.0]
    /// An app shown again is scanned for its windows after this long.
    static let shownScan: CFTimeInterval = 0.1
    /// Once a focused window closes, its neighbour is focused after this long.
    static let focusNeighbor: CFTimeInterval = 0.12

    /// A new window born exactly on another of its app is most likely a tab of it: whether
    /// that other one has gone behind it is known after this long.
    static let tabJoin: CFTimeInterval = 0.25
    /// A window's tab closed: the tab behind it has come forward within this long.
    static let tabForward: CFTimeInterval = 0.15
    /// After focus moved within an app, its windows are checked for ones that became tabs
    /// behind another (windows merged) this much later.
    static let tabCheck: CFTimeInterval = 0.5

    // MARK: Desktops, screens, the lock screen

    /// The window server settles a new desktop in this long.
    static let spaceSettle: CFTimeInterval = 0.15
    /// Screens added, removed or rearranged settle in this long.
    static let screensSettle: CFTimeInterval = 0.3
    /// Windows are looked for again this long after unlocking (none are reported while locked).
    static let unlockScan: CFTimeInterval = 0.5

    // MARK: Stand-ins

    /// A stand-in surely reached the screen this long after it was put up: only then does
    /// the real window under it go off screen.
    static let standInSettle: CFTimeInterval = 0.06
    /// A fresh peek's stand-in needs a frame or two to appear before its window is parked.
    static let parkAfterPeek: CFTimeInterval = 0.05
    /// The stand-in fades this long after the app moved its window back.
    static let handOverFade: CFTimeInterval = 0.05
    /// The stand-in stops waiting for its window after this long.
    static let handOverGiveUp: CFTimeInterval = 0.6
    /// A parked window resized for a new snapshot is captured this long after the resize.
    static let resnapCapture: CFTimeInterval = 0.05
    /// A window is re-snapshotted at a new size at most this often.
    static let resnapEvery: CFTimeInterval = 2

    // MARK: Mission Control

    /// The windows' moves land before the overview opens, this long after.
    static let overviewOpen: CFTimeInterval = 0.05
    /// The overview's closing animation is over this long after a window is picked.
    static let overviewClosing: CFTimeInterval = 0.25
    /// An overview that hasn't shown up in this long isn't coming.
    static let overviewGiveUp: CFTimeInterval = 1.5

    // MARK: Dragging

    /// The cursor rests this long in an edge band before the strip scrolls under a drag.
    static let bandDwell: CFTimeInterval = 0.35
    /// Something dragged from another app rests this long on a window's picture before the
    /// strip scrolls that window into view.
    static let dragHoverReveal: CFTimeInterval = 0.5

    // MARK: Bookkeeping

    /// A preset's windows are waited for this long.
    static let presetOpening: CFTimeInterval = 30
    /// A preset's windows are arranged once none has shown up for this long.
    static let presetSettle: CFTimeInterval = 0.4
    /// The layout is saved (if it changed) and old notes tidied this often.
    static let saveEvery: TimeInterval = 5
    /// Notes of when something happened are forgotten after this long.
    static let forgetAfter: CFTimeInterval = 10
}
