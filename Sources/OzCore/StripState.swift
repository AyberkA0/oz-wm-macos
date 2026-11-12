import CoreGraphics

/// A strip's arrangement, independent of the live objects: its rows (windows, heights, widths
/// and places in the row), scroll position and focused window, plus the windows tiled in the
/// regions around the zone. Saved to disk to survive restarts, and kept in memory for undo.
public struct StripState: Codable, Equatable {
    public struct Window: Codable, Equatable {
        /// Window id (the same while the app keeps running, so across Oz restarts).
        public var id: WinID
        /// To find it again after its app restarted (new id): the app and window title.
        public var app: String
        public var bundleID: String?
        public var title: String
        /// Width share (nil: 1) and, alone in a narrowed row, the place in it (nil: left edge).
        public var weight: Double?
        public var offset: Double?

        public init(id: WinID, app: String = "", bundleID: String? = nil, title: String = "",
                    weight: Double? = nil, offset: Double? = nil) {
            self.id = id
            self.app = app
            self.bundleID = bundleID
            self.title = title
            self.weight = weight
            self.offset = offset
        }
    }

    public struct Row: Codable, Equatable {
        public var height: Double
        public var windows: [Window]
        public init(height: Double, windows: [Window]) {
            self.height = height
            self.windows = windows
        }
    }

    public var rows: [Row]
    public var scroll: Double
    public var focused: WinID?
    /// Windows tiled in the regions outside the zone: region index (as text) -> windows in order.
    public var docks: [String: [Window]]

    public init(rows: [Row] = [], scroll: Double = 0, focused: WinID? = nil, docks: [String: [Window]] = [:]) {
        self.rows = rows
        self.scroll = scroll
        self.focused = focused
        self.docks = docks
    }

    /// Every window id it mentions.
    public var windowIDs: [WinID] {
        rows.flatMap { $0.windows.map(\.id) } + docks.values.flatMap { $0.map(\.id) }
    }
}

/// What is known about a live window when matching saved ones to it.
public struct WindowDescription: Equatable {
    public var id: WinID
    public var app: String
    public var bundleID: String?
    public var title: String

    public init(id: WinID, app: String, bundleID: String?, title: String) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.title = title
    }

    func sameApp(_ w: StripState.Window) -> Bool {
        if let b = bundleID, let wb = w.bundleID { return b == wb }
        return app == w.app
    }
}

public enum WindowMatcher {
    /// The live window a saved one stands for: the same id of the same app (the app kept
    /// running), else the first unused window of that app with the same title (it restarted).
    /// Never a window already used, nor a different app's.
    public static func match(_ saved: StripState.Window, in candidates: [WindowDescription],
                             excluding used: Set<WinID>) -> WinID? {
        if let c = candidates.first(where: { $0.id == saved.id && !used.contains($0.id) }), c.sameApp(saved) {
            return c.id
        }
        return candidates.first { !used.contains($0.id) && $0.sameApp(saved) && $0.title == saved.title }?.id
    }
}

extension Strip {
    /// This strip's arrangement; `describe` names each window (app, title) for matching later.
    public func state(describe: (WinID) -> WindowDescription? = { _ in nil }) -> StripState {
        StripState(rows: rows.map { row in
            StripState.Row(height: Double(row.height), windows: row.windows.map { id in
                let d = describe(id)
                return StripState.Window(id: id, app: d?.app ?? "", bundleID: d?.bundleID, title: d?.title ?? "",
                                         weight: widthWeights[id].map(Double.init), offset: widthOffsets[id].map(Double.init))
            })
        }, scroll: Double(scrollY), focused: focused)
    }

    /// Rearranges this strip's windows like `state`: windows it matches go to their saved rows
    /// with their heights (at most `maxHeight`), widths and places; the rest keep their order,
    /// after them. Scroll and focus come back too. Returns the windows that were matched; with
    /// none, the strip is left as it is (the saved scroll belongs to windows that aren't here).
    @discardableResult
    public func restore(_ state: StripState, maxHeight: CGFloat,
                        match: (StripState.Window, Set<WinID>) -> WinID?) -> Set<WinID> {
        var used = Set<WinID>()
        var newRows: [Row] = []
        var weights: [WinID: CGFloat] = [:], offsets: [WinID: CGFloat] = [:]
        var focus: WinID?
        for saved in state.rows {
            var ids: [WinID] = []
            for w in saved.windows {
                guard let id = match(w, used), contains(id) else { continue }
                ids.append(id)
                used.insert(id)
                if let x = w.weight { weights[id] = CGFloat(x) }
                if let x = w.offset { offsets[id] = CGFloat(x) }
                if w.id == state.focused { focus = id }
            }
            if !ids.isEmpty { newRows.append(Row(ids, height: min(max(CGFloat(saved.height), 60), maxHeight))) }
        }
        for row in rows {
            let rest = row.windows.filter { !used.contains($0) }
            if !rest.isEmpty { newRows.append(Row(rest, height: row.height)) }
        }
        guard !used.isEmpty else { return used }
        rows = newRows
        for id in used {
            widthWeights[id] = weights[id]
            widthOffsets[id] = offsets[id]
        }
        if let focus { focused = focus }
        scrollY = CGFloat(state.scroll)
        renderScrollY = scrollY
        return used
    }
}
