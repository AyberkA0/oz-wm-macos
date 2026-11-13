import Cocoa
import OzCore

/// Everything Oz notes about one window, by its id, apart from `ManagedWindow` (which is made
/// anew each time the window is picked up). Nothing noted is the default; `WindowStates`
/// keeps no record for it.
struct WindowState: Equatable {
    // MARK: Tiled

    /// The app refused to get smaller than this at the top edge.
    var minHeight: CGFloat?
    /// Sent straight to its final frame (a new window): the layout leaves it alone while the
    /// rest of the strip animates around it.
    var pinned = false
    /// Waiting for its stand-in to reach the screen before being moved away.
    var pendingPark: DispatchWorkItem?
    /// A slow app's window drawn by a stand-in while the strip moves (the real one parked).
    var proxied = false
    /// When its stand-in was put up: the real window stays underneath, moving with it, until
    /// the stand-in has surely reached the screen (a new or resized overlay window takes a
    /// frame or two), and only then goes off screen. Parking it at once left a frame with
    /// neither on screen: the window flickered as a swipe started.
    var proxyShownAt: CFTimeInterval?
    /// Its stand-in waits for the real window to be back before fading (see `handOver`).
    var handingOver = false
    /// Being resized off screen for a new snapshot (see `refreshSnapshot`), and when it last
    /// was: an app that won't take the new size isn't asked every frame.
    var resnapping = false
    var lastResnap: CFTimeInterval?
    /// When the user last dragged it by the mouse (our own moves aren't).
    var userDraggedAt: CFTimeInterval?
    /// When the user last resized it by an edge with the mouse.
    var userResizedAt: CFTimeInterval?
    /// When Oz last put it back to the size it gave it (see `compareFrame`): an app that
    /// insists on its own width isn't fought over and over.
    var sizeEnforcedAt: CFTimeInterval?

    /// Tiled, then minimized or hidden with its app: where it was in its strip, to go back
    /// there (not to a new row at the end) when it returns.
    var tiledPlace: TiledPlace?

    struct TiledPlace: Equatable {
        let key: StripKey
        let place: RowPlace
    }

    // MARK: Floating

    /// Taken out of the strip by the user (dragged out of the scroll area, a tab torn off
    /// outside it, toggleFloat): dropped into a scroll area, it is tiled again. Not a window
    /// floating because of a rule or a fixed size.
    var manualFloat = false
    /// Floated on purpose (toggleFloat, the menu): wherever it is dragged it stays floating,
    /// joining neither the strip nor a region. toggleFloat or undo tiles it again.
    var keptFloating = false
    /// Being dragged (or a tab being torn off): placed when the mouse is let go.
    var pendingDrop = false
    /// Made to fill the screen (see `Zoom`).
    var zoom: Zoom?
    /// Docked: its share of its region against the others there (nil: 1), set by dragging
    /// the edge between two of them.
    var dockShare: CGFloat?
    /// When Oz last moved it (a docked window's move notifications aren't a user drag).
    var dockPlacedAt: CFTimeInterval?
    /// Sent to the Dock: brought back, it goes back where it was (its region and place)
    /// rather than into the strip.
    var minimized: Minimized?

    /// A floating window filling the screen: where it was before (it goes back there once
    /// another window gets focus), and whether Oz did it itself (its app zoomed it, or
    /// ignored the double click and Oz made it fill the screen).
    struct Zoom: Equatable {
        let before: CGRect
        let byOz: Bool
    }

    struct Minimized: Equatable {
        let manual: Bool
        let kept: Bool
        let dock: DockPlace?
    }

    struct DockPlace: Equatable {
        let key: StripKey
        let region: Int
        let index: Int
    }

    var isEmpty: Bool { self == WindowState() }

    /// Taken out of the strip by a drag (or torn off): let go in a scroll area or a region,
    /// it is placed there.
    var droppable: Bool { manualFloat && !keptFloating }

    /// The value, cleared.
    mutating func take<T>(_ field: WritableKeyPath<WindowState, T?>) -> T? {
        defer { self[keyPath: field] = nil }
        return self[keyPath: field]
    }

    /// Clears the flag; whether it was set.
    mutating func clear(_ flag: WritableKeyPath<WindowState, Bool>) -> Bool {
        defer { self[keyPath: flag] = false }
        return self[keyPath: flag]
    }

    /// Sets the flag; whether it wasn't set yet.
    mutating func mark(_ flag: WritableKeyPath<WindowState, Bool>) -> Bool {
        defer { self[keyPath: flag] = true }
        return !self[keyPath: flag]
    }
}

/// Every window's `WindowState`, by id.
struct WindowStates {
    private var all: [CGWindowID: WindowState] = [:]

    subscript(_ id: CGWindowID) -> WindowState {
        get { all[id] ?? WindowState() }
        set { all[id] = newValue.isEmpty ? nil : newValue }
    }

    /// The windows whose state matches.
    func ids(where match: (WindowState) -> Bool) -> [CGWindowID] {
        all.compactMap { match($0.value) ? $0.key : nil }
    }

    /// The heights apps refused to go below, for the layout.
    var minHeights: [CGWindowID: CGFloat] { all.compactMapValues(\.minHeight) }

    /// The windows their app zoomed, and where each was before.
    var zoomed: [(id: CGWindowID, before: CGRect)] {
        all.compactMap { id, s in s.zoom.map { (id, $0.before) } }
    }

    mutating func update(_ ids: some Sequence<CGWindowID>, _ change: (inout WindowState) -> Void) {
        for id in ids { change(&self[id]) }
    }

    mutating func updateAll(_ change: (CGWindowID, inout WindowState) -> Void) {
        for id in Array(all.keys) { change(id, &self[id]) }
    }
}

/// The same work item (for `WindowState`'s equality).
extension DispatchWorkItem: @retroactive Equatable {
    public static func == (a: DispatchWorkItem, b: DispatchWorkItem) -> Bool { a === b }
}
