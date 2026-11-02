import Cocoa

/// What the window server knows about windows, without asking their apps: where each is
/// (AX coordinates, top-left origin), its layer and its owner.
enum WindowServer {
    struct Window {
        let id: CGWindowID
        let pid: pid_t?
        let owner: String?
        let layer: Int?
        let bounds: CGRect

        init?(_ info: [String: Any]) {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { return nil }
            self.id = id
            self.bounds = bounds
            pid = info[kCGWindowOwnerPID as String] as? pid_t
            owner = info[kCGWindowOwnerName as String] as? String
            layer = info[kCGWindowLayer as String] as? Int
        }

        /// An app's ordinary window (layer 0), not one of Oz's own (its boards span whole
        /// screens, and its stand-ins sit over the windows they stand in for).
        var isOtherAppWindow: Bool { layer == 0 && pid != getpid() }
    }

    /// One window, nil if it's gone. (The ids go in as plain values: an array of numbers
    /// gets no answer.)
    static func window(_ id: CGWindowID) -> Window? {
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &value, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first else { return nil }
        return Window(info)
    }

    /// The windows on screen, frontmost first; with `desktop`, the desktop's own too.
    static func onScreen(desktop: Bool = false) -> [Window] {
        let options: CGWindowListOption = desktop ? .optionOnScreenOnly : [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(Window.init)
    }

    /// The frontmost app window (see `isOtherAppWindow`) at `p`, AX coordinates.
    static func appWindow(at p: CGPoint) -> Window? {
        onScreen().first { $0.isOtherAppWindow && $0.bounds.contains(p) }
    }

    /// Every window there is, on any desktop, shown or not.
    static func allIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}
