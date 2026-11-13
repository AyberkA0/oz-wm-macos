import CoreGraphics

/// Window identifier (CGWindowID).
public typealias WinID = UInt32

/// A horizontal row of the strip. Usually holds one window; `slurpIn` can put
/// several side by side (like panels in a comic page row). This is the vertical
/// analogue of a PaperWM column.
public final class Row {
    public var windows: [WinID]
    public var height: CGFloat

    public init(_ windows: [WinID], height: CGFloat) {
        self.windows = windows
        self.height = height
    }
}

public enum Placement: Equatable {
    /// Put the window at this frame (top-left origin, global AX coordinates).
    case frame(CGRect)
    /// Window is outside the viewport; hide it in a screen corner.
    case park
    /// Window's full frame sticks out above the top edge (slide mode). The window
    /// manager shows a snapshot of it sliding off, or falls back to shrinking.
    case overflow(CGRect)
}

/// What to do with a window that is partially scrolled above the top edge.
/// macOS won't let windows go above the menu bar, so we can't simply move it up.
public enum TopOverflow: String, CaseIterable {
    /// Let it slide off the top like it does at the bottom (drawn from a snapshot while moving).
    case slide
    /// Pin it to the top edge and shrink it to the still-visible part.
    case shrink
    /// Hide it as soon as its top leaves the screen.
    case hide
}

/// How a swipe comes to rest.
public enum SnapMode: String, CaseIterable {
    /// Every swipe moves exactly one window, in its direction (however far or fast).
    case always
    /// Glide freely; settle on a window edge only when released close to one.
    case near
    /// Glide freely, never snap.
    case off
}

/// One window's place in a layout pass.
public struct LayoutItem {
    public let id: WinID
    public let placement: Placement
    /// Full height of the window's row (a shrunk window is shorter than this).
    public let rowHeight: CGFloat
    /// Where the whole window would be, ignoring the screen edges.
    public let frame: CGRect
}

/// A window's place in a strip (see `Strip.place(of:)`): its row, the windows it shared the
/// row with on either side, and the first windows of the rows above and below.
public struct RowPlace: Equatable {
    public let row: Int
    public let height: CGFloat
    public let left: [WinID]
    public let right: [WinID]
    public let above: WinID?
    public let below: WinID?
    public let weight: CGFloat?
    public let offset: CGFloat?
}

public enum InsertPosition: String, CaseIterable {
    case below, above, end, start
}

public enum Direction {
    case up, down, left, right
}

public struct LayoutParams {
    /// Area windows are laid out in (visible frame minus outer gaps), AX coordinates.
    public var viewport: CGRect
    /// Highest y a window may have (bottom of the menu bar).
    public var hardTop: CGFloat
    /// Windows whose top is below this are hidden.
    public var hardBottom: CGFloat
    /// The scroll area ends above the screen's bottom: windows are cut off at `hardBottom`
    /// like at the top, instead of running off the screen.
    public var cutBottom: Bool
    public var gap: CGFloat
    public var widthRatio: CGFloat
    public var topOverflow: TopOverflow
    public var minVisible: CGFloat

    public init(viewport: CGRect, hardTop: CGFloat, hardBottom: CGFloat, gap: CGFloat,
                widthRatio: CGFloat = 1, topOverflow: TopOverflow = .shrink, minVisible: CGFloat = 80,
                cutBottom: Bool = false) {
        self.viewport = viewport
        self.hardTop = hardTop
        self.hardBottom = hardBottom
        self.cutBottom = cutBottom
        self.gap = gap
        self.widthRatio = widthRatio
        self.topOverflow = topOverflow
        self.minVisible = minVisible
    }

    /// Lowest y anything may be drawn at (infinite when windows may run off the screen).
    public var clipBottom: CGFloat { cutBottom ? hardBottom : .greatestFiniteMagnitude }
}

/// A vertically scrolling strip of rows: one per (space, display).
public final class Strip {
    public var rows: [Row] = []
    /// Logical scroll position (where we want to be), in points from the top of the strip.
    public var scrollY: CGFloat = 0
    /// Scroll position currently rendered on screen (differs from `scrollY` while animating).
    public var renderScrollY: CGFloat = 0
    public var focused: WinID?
    /// Width share of each window (default 1). Windows sharing a row split it in proportion
    /// to their shares; a window alone in its row with a share below 1 takes only that
    /// fraction of the row and leaves the rest empty.
    public var widthWeights: [WinID: CGFloat] = [:]
    /// Where a narrowed window alone in its row sits: the space left of it, as a fraction of
    /// the row's width (default 0, the left edge). Set by resizing it from either side.
    public var widthOffsets: [WinID: CGFloat] = [:]

    public init() {}

    public var windowIDs: [WinID] { rows.flatMap { $0.windows } }
    public var isEmpty: Bool { rows.isEmpty }

    public func contains(_ id: WinID) -> Bool { locate(id) != nil }

    public func locate(_ id: WinID) -> (row: Int, col: Int)? {
        for (r, row) in rows.enumerated() {
            if let c = row.windows.firstIndex(of: id) { return (r, c) }
        }
        return nil
    }

    // MARK: Geometry

    public func rowTop(_ index: Int, gap: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for i in 0..<min(index, rows.count) { y += rows[i].height + gap }
        return y
    }

    public func contentHeight(gap: CGFloat) -> CGFloat {
        rows.isEmpty ? 0 : rowTop(rows.count, gap: gap) - gap
    }

    public func maxScroll(viewportHeight vh: CGFloat, gap: CGFloat) -> CGFloat {
        max(0, contentHeight(gap: gap) - vh)
    }

    public static func height(forRatio ratio: CGFloat, viewportHeight vh: CGFloat, gap: CGFloat) -> CGFloat {
        // Two 1/2 rows plus the gap between them fill the viewport exactly.
        max(40, (ratio * (vh + gap) - gap).rounded())
    }

    // MARK: Editing

    public func insert(_ id: WinID, height: CGFloat, anchor: WinID?, position: InsertPosition) {
        let row = Row([id], height: height)
        let anchorRow = anchor.flatMap { locate($0)?.row }
        let index: Int
        switch position {
        case .end: index = rows.count
        case .start: index = 0
        case .below: index = anchorRow.map { $0 + 1 } ?? rows.count
        case .above: index = anchorRow ?? rows.count
        }
        rows.insert(row, at: index)
    }

    /// Inserts `id` as a row of its own just above the row holding `anchor` (at the end
    /// when there is no anchor). Used when a window is dropped between two rows.
    public func insertRow(_ id: WinID, height: CGFloat, before anchor: WinID?) {
        let index = anchor.flatMap { locate($0)?.row } ?? rows.count
        rows.insert(Row([id], height: height), at: index)
    }

    /// Puts `id` next to `anchor` in its row, on its right or left, sharing the row's width.
    @discardableResult
    public func insertBeside(_ id: WinID, anchor: WinID, right: Bool) -> Bool {
        guard let (r, c) = locate(anchor) else { return false }
        rows[r].windows.insert(id, at: right ? c + 1 : c)
        widthWeights[id] = nil
        return true
    }

    /// Where a window is, for putting it back there once it has been away (minimized, its app
    /// hidden) and the strip may have changed meanwhile: `nil` if it isn't in the strip.
    public func place(of id: WinID) -> RowPlace? {
        guard let (r, c) = locate(id) else { return nil }
        let row = rows[r]
        return RowPlace(row: r, height: row.height, left: Array(row.windows[..<c]), right: Array(row.windows[(c + 1)...]),
                        above: r > 0 ? rows[r - 1].windows.first : nil,
                        below: r + 1 < rows.count ? rows[r + 1].windows.first : nil,
                        weight: widthWeights[id], offset: widthOffsets[id])
    }

    /// Puts a window (not in the strip) back where `place` says, as well as the strip still
    /// allows. It shared its row: beside those of that row still together (right of the nearest
    /// that was on its left, else left of the nearest on its right), with its share. Otherwise
    /// a row of its own, at most `maxHeight` high: above the row that was below it, else below
    /// the one that was above it, else at the row number it had.
    public func insert(_ id: WinID, at place: RowPlace, maxHeight: CGFloat) {
        guard !contains(id) else { return }
        if let anchor = place.left.last(where: contains), let (r, c) = locate(anchor) {
            rows[r].windows.insert(id, at: c + 1)
            widthWeights[id] = place.weight
            return
        }
        if let anchor = place.right.first(where: contains), let (r, c) = locate(anchor) {
            rows[r].windows.insert(id, at: c)
            widthWeights[id] = place.weight
            return
        }
        let index: Int
        if let b = place.below, let (r, _) = locate(b) {
            index = r
        } else if let a = place.above, let (r, _) = locate(a) {
            index = r + 1
        } else {
            index = min(place.row, rows.count)
        }
        rows.insert(Row([id], height: min(place.height, maxHeight)), at: index)
        // Narrowed, alone in its row: as wide as it was, where it was.
        if place.left.isEmpty && place.right.isEmpty {
            widthWeights[id] = place.weight
            widthOffsets[id] = place.offset
        }
    }

    /// Removes a window; returns the neighbour that should receive focus.
    @discardableResult
    public func remove(_ id: WinID) -> WinID? {
        guard let (r, c) = locate(id) else { return nil }
        rows[r].windows.remove(at: c)
        widthWeights[id] = nil
        widthOffsets[id] = nil
        var neighbor: WinID?
        if rows[r].windows.isEmpty {
            rows.remove(at: r)
            if r < rows.count {
                neighbor = rows[r].windows.first
            } else if r > 0 {
                neighbor = rows[r - 1].windows.first
            }
        } else {
            neighbor = rows[r].windows[min(c, rows[r].windows.count - 1)]
        }
        if focused == id { focused = neighbor }
        return neighbor
    }

    public func neighbor(of id: WinID, _ direction: Direction) -> WinID? {
        guard let (r, c) = locate(id) else { return nil }
        switch direction {
        case .up, .down:
            let t = r + (direction == .down ? 1 : -1)
            guard rows.indices.contains(t) else { return nil }
            let target = rows[t].windows
            return target[min(c, target.count - 1)]
        case .left, .right:
            let t = c + (direction == .right ? 1 : -1)
            guard rows[r].windows.indices.contains(t) else { return nil }
            return rows[r].windows[t]
        }
    }

    /// Moves a window up/down. A window sharing a row is first expelled into its own row,
    /// which it fills (its share of the row it left means nothing alone), as with `barfOut`.
    @discardableResult
    public func moveVertical(_ id: WinID, by delta: Int) -> Bool {
        guard let (r, c) = locate(id) else { return false }
        let row = rows[r]
        if row.windows.count > 1 {
            row.windows.remove(at: c)
            widthWeights[id] = nil
            rows.insert(Row([id], height: row.height), at: delta > 0 ? r + 1 : r)
            return true
        }
        let t = r + delta
        guard rows.indices.contains(t) else { return false }
        rows.swapAt(r, t)
        return true
    }

    /// Moving up/down into a row that has room for this window: the next row holds a single
    /// narrowed window and this one fits in the space beside it. Then it joins that row on the
    /// side it's already on, the two sharing the row in proportion to their widths. False (and
    /// nothing changes) when it doesn't fit; the caller then moves it as usual.
    @discardableResult
    public func joinIfFits(_ id: WinID, by delta: Int) -> Bool {
        guard let (r, c) = locate(id) else { return false }
        var t = r + delta
        guard rows.indices.contains(t), rows[t].windows.count == 1, let other = rows[t].windows.first,
              weight(other) < 1 else { return false }
        let row = rows[r].windows
        // Its share of the row width now: alone, its own (narrowed) width; shared, its part.
        let share = row.count == 1 ? min(weight(id), 1) : (widthFraction(id) ?? 1)
        guard share <= 1 - weight(other) + 0.02 else { return false }
        // Which side of the other window it is on (by the middles of the two).
        let mine: CGFloat
        if row.count == 1 {
            mine = (widthOffsets[id] ?? 0) + share / 2
        } else {
            mine = row[..<c].compactMap { widthFraction($0) }.reduce(0, +) + share / 2
        }
        let right = mine >= (widthOffsets[other] ?? 0) + weight(other) / 2
        rows[r].windows.remove(at: c)
        if rows[r].windows.isEmpty {
            rows.remove(at: r)
            if t > r { t -= 1 }
        }
        widthWeights[id] = share
        widthOffsets[id] = nil
        widthOffsets[other] = nil
        if right { rows[t].windows.append(id) } else { rows[t].windows.insert(id, at: 0) }
        return true
    }

    @discardableResult
    public func moveHorizontal(_ id: WinID, by delta: Int) -> Bool {
        guard let (r, c) = locate(id) else { return false }
        let t = c + delta
        guard rows[r].windows.indices.contains(t) else { return false }
        rows[r].windows.swapAt(c, t)
        return true
    }

    public func moveToEdge(_ id: WinID, top: Bool) {
        guard let (r, c) = locate(id) else { return }
        let row = rows[r]
        if row.windows.count > 1 {
            row.windows.remove(at: c)
            widthWeights[id] = nil
            rows.insert(Row([id], height: row.height), at: top ? 0 : rows.count)
        } else {
            rows.remove(at: r)
            rows.insert(row, at: top ? 0 : rows.count)
        }
    }

    /// PaperWM's slurp: pull the first window of the row below into this row.
    @discardableResult
    public func slurpIn(_ id: WinID) -> Bool {
        guard let (r, _) = locate(id), r + 1 < rows.count else { return false }
        let next = rows[r + 1]
        let w = next.windows.removeFirst()
        widthWeights[w] = nil
        rows[r].windows.append(w)
        if next.windows.isEmpty { rows.remove(at: r + 1) }
        return true
    }

    /// Moves this window into the row above (appended on the right) or below (on the left),
    /// so it sits side by side with that row's windows.
    @discardableResult
    public func joinVertical(_ id: WinID, by delta: Int) -> Bool {
        guard let (r, c) = locate(id), rows.indices.contains(r + delta) else { return false }
        var target = r + delta
        rows[r].windows.remove(at: c)
        if rows[r].windows.isEmpty {
            rows.remove(at: r)
            if delta > 0 { target -= 1 }
        }
        if delta < 0 {
            rows[target].windows.append(id)
        } else {
            rows[target].windows.insert(id, at: 0)
        }
        widthWeights[id] = nil
        return true
    }

    // MARK: Widths within a row

    public func weight(_ id: WinID) -> CGFloat { widthWeights[id] ?? 1 }

    /// Share of the row's width this window gets (1 when alone in its row).
    public func widthFraction(_ id: WinID) -> CGFloat? {
        guard let (r, _) = locate(id) else { return nil }
        let sum = rows[r].windows.map(weight).reduce(0, +)
        return sum > 0 ? weight(id) / sum : 1
    }

    /// Gives this window `fraction` of its row; the others keep their proportions.
    @discardableResult
    public func setWidthFraction(_ id: WinID, _ fraction: CGFloat) -> Bool {
        guard let (r, _) = locate(id), rows[r].windows.count > 1 else { return false }
        let f = min(max(fraction, 0.1), 0.9)
        let others = rows[r].windows.filter { $0 != id }.map(weight).reduce(0, +)
        widthWeights[id] = f * others / (1 - f)
        return true
    }

    public func cycledWidthFraction(_ id: WinID, ratios: [CGFloat], forward: Bool) -> CGFloat? {
        guard let cur = widthFraction(id), !ratios.isEmpty else { return nil }
        let sorted = ratios.sorted()
        if forward { return sorted.first { $0 > cur + 0.01 } ?? sorted.first }
        return sorted.last { $0 < cur - 0.01 } ?? sorted.last
    }

    /// Sets the share of a window alone in its row (`nil`/>= 0.97 means full width). It keeps
    /// its place in the row, moved left only as far as it needs to still fit.
    public func setLoneWidth(_ id: WinID, _ share: CGFloat?) {
        guard let s = share, s < 0.97 else {
            widthWeights[id] = nil
            widthOffsets[id] = nil
            return
        }
        widthWeights[id] = max(s, 0.1)
        if let o = widthOffsets[id] { setLoneOffset(id, o) }
    }

    /// Places a narrowed window alone in its row: `offset` is the space left of it as a
    /// fraction of the row's width, kept within the row.
    public func setLoneOffset(_ id: WinID, _ offset: CGFloat) {
        let o = min(max(offset, 0), max(0, 1 - weight(id)))
        widthOffsets[id] = o < 0.005 ? nil : o
    }

    /// The row's left edge and width for these layout parameters.
    public static func rowExtent(_ p: LayoutParams) -> (x: CGFloat, width: CGFloat) {
        let rowWidth = (p.viewport.width * min(max(p.widthRatio, 0.1), 1)).rounded()
        return ((p.viewport.minX + (p.viewport.width - rowWidth) / 2).rounded(), rowWidth)
    }

    /// Equal widths for every window in the row of `id`.
    public func equalizeRow(of id: WinID) {
        guard let (r, _) = locate(id) else { return }
        for w in rows[r].windows { widthWeights[w] = nil }
    }

    /// PaperWM's barf: expel this window from its row into a new row below.
    @discardableResult
    public func barfOut(_ id: WinID) -> Bool {
        guard let (r, c) = locate(id), rows[r].windows.count > 1 else { return false }
        rows[r].windows.remove(at: c)
        rows.insert(Row([id], height: rows[r].height), at: r + 1)
        widthWeights[id] = nil
        return true
    }

    /// Next/previous preset height for the row containing `id`.
    public func cycledHeight(_ id: WinID, ratios: [CGFloat], viewportHeight vh: CGFloat,
                             gap: CGFloat, forward: Bool) -> CGFloat? {
        guard let (r, _) = locate(id), !ratios.isEmpty else { return nil }
        let heights = ratios.map { Strip.height(forRatio: $0, viewportHeight: vh, gap: gap) }.sorted()
        let cur = rows[r].height
        if forward {
            return heights.first { $0 > cur + 2 } ?? heights.first
        }
        return heights.last { $0 < cur - 2 } ?? heights.last
    }

    // MARK: Scrolling

    /// Smallest scroll change that brings the row of `id` fully into view.
    public func scrollToReveal(_ id: WinID, viewportHeight vh: CGFloat, gap: CGFloat) -> CGFloat {
        guard let (r, _) = locate(id) else { return scrollY }
        let top = rowTop(r, gap: gap)
        let h = rows[r].height
        if h >= vh - 0.5 || top < scrollY { return top }
        if top + h > scrollY + vh { return top + h - vh }
        return scrollY
    }

    public func scrollToCenter(_ id: WinID, viewportHeight vh: CGFloat, gap: CGFloat) -> CGFloat {
        guard let (r, _) = locate(id) else { return scrollY }
        return (rowTop(r, gap: gap) + rows[r].height / 2 - vh / 2).rounded()
    }

    public func scrollToTop(_ id: WinID, gap: CGFloat) -> CGFloat {
        guard let (r, _) = locate(id) else { return scrollY }
        return rowTop(r, gap: gap)
    }

    public func clampScroll(_ s: CGFloat, viewportHeight vh: CGFloat, gap: CGFloat) -> CGFloat {
        min(max(0, s), maxScroll(viewportHeight: vh, gap: gap))
    }

    /// Scroll positions a swipe may come to rest at: each row aligned to the
    /// top edge (like turning to the next panel), plus both ends.
    public func snapTargets(viewportHeight vh: CGFloat, gap: CGFloat) -> [CGFloat] {
        let m = maxScroll(viewportHeight: vh, gap: gap)
        var t = Set<CGFloat>([0, m])
        for i in rows.indices { t.insert(min(rowTop(i, gap: gap), m)) }
        return t.sorted()
    }

    /// Scroll positions where a window edge lines up with a screen edge:
    /// a row's top on the top edge, or a row's bottom on the bottom edge.
    public func edgeTargets(viewportHeight vh: CGFloat, gap: CGFloat) -> [CGFloat] {
        let m = maxScroll(viewportHeight: vh, gap: gap)
        var t = Set<CGFloat>([0, m])
        for i in rows.indices {
            let top = rowTop(i, gap: gap)
            t.insert(min(max(top, 0), m))
            t.insert(min(max(top + rows[i].height - vh, 0), m))
        }
        return t.sorted()
    }

    /// Free scrolling with inertia: glide on from `s` with `velocity` (points/s), and settle on a
    /// window edge only if the glide ends within `snapDistance` of one.
    public func restingScroll(from s: CGFloat, velocity: CGFloat, viewportHeight vh: CGFloat, gap: CGFloat,
                              snapDistance: CGFloat, momentum: CGFloat = 1) -> CGFloat {
        let projected = clampScroll(s + velocity * 0.25 * momentum, viewportHeight: vh, gap: gap).rounded()
        guard snapDistance > 0,
              let nearest = edgeTargets(viewportHeight: vh, gap: gap)
                .min(by: { abs($0 - projected) < abs($1 - projected) }),
              abs(nearest - projected) <= snapDistance else { return projected }
        return nearest
    }

    /// Where a swipe released at `s` with `velocity` (points/s, positive = scrolling down)
    /// lands when every swipe moves one window: only the swipe's direction counts, not how
    /// far or how fast it went (except `steps`). `start`: where the swipe began.
    ///
    /// Down: the next window not yet fully shown below comes in, its bottom on the bottom
    /// edge. Up: the next one above, its top on the top edge. If that window was already
    /// mostly in view (over `mostlyShown` of its height) when the swipe began, it goes on to
    /// the window's far edge instead: down, its top on the top edge; up, its bottom on the
    /// bottom edge. A window taller than the screen moves it by at most a screen. `steps`:
    /// how many windows it moves on, one after the other (a very strong swipe). A nudge
    /// (under `nudge` points, released slowly) goes back to where the swipe started; at an
    /// end of the strip it stays there.
    public func snapTarget(from s: CGFloat, velocity: CGFloat, start: CGFloat? = nil, viewportHeight vh: CGFloat,
                           gap: CGFloat, nudge: CGFloat = 30, mostlyShown: CGFloat = 0.65, steps: Int = 1) -> CGFloat {
        let from = clampScroll(start ?? s, viewportHeight: vh, gap: gap)
        let moved = s - from
        // Fingers slow down before they lift: a slow release goes the way the swipe went.
        let dir: CGFloat = abs(velocity) >= vh * 0.1 ? (velocity > 0 ? 1 : -1) : (abs(moved) >= nudge ? (moved > 0 ? 1 : -1) : 0)
        func step(_ from: CGFloat) -> CGFloat {
            var target = from
            func shown(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
                max(0, min(bottom, from + vh) - max(top, from)) / max(bottom - top, 1)
            }
            if dir > 0 {
                for i in rows.indices {
                    let top = rowTop(i, gap: gap), bottom = top + rows[i].height
                    guard bottom > from + vh + 1 else { continue }
                    if rows[i].height > vh + 1 {
                        target = min(bottom - vh, from + vh)
                    } else {
                        target = shown(top, bottom) > mostlyShown && top > from + 1 ? top : bottom - vh
                    }
                    break
                }
            } else if dir < 0 {
                for i in rows.indices.reversed() {
                    let top = rowTop(i, gap: gap), bottom = top + rows[i].height
                    guard top < from - 1 else { continue }
                    if rows[i].height > vh + 1 {
                        target = max(top, from - vh)
                    } else {
                        target = shown(top, bottom) > mostlyShown && bottom - vh < from - 1 ? bottom - vh : top
                    }
                    break
                }
            }
            return clampScroll(target, viewportHeight: vh, gap: gap)
        }
        var target = from
        for _ in 0..<max(1, steps) {
            let next = step(target)
            if abs(next - target) < 1 { break }
            target = next
        }
        return clampScroll(target, viewportHeight: vh, gap: gap)
    }

    /// Topmost row fully visible at scroll `s` (or the row covering the top edge).
    public func topVisibleRow(scroll s: CGFloat, viewportHeight vh: CGFloat, gap: CGFloat) -> Int? {
        var covering: Int?
        for i in rows.indices {
            let top = rowTop(i, gap: gap)
            let bottom = top + rows[i].height
            if top >= s - 1 && bottom <= s + vh + 1 { return i }
            if covering == nil && bottom > s { covering = i }
        }
        return covering
    }

    public func isFullyVisible(_ id: WinID, scroll s: CGFloat, viewportHeight vh: CGFloat, gap: CGFloat) -> Bool {
        guard let (r, _) = locate(id) else { return false }
        let top = rowTop(r, gap: gap)
        return top >= s - 1 && top + rows[r].height <= s + vh + 1
    }

    // MARK: Layout

    /// Computes where every window goes when the strip is scrolled to `scroll`.
    public func layout(_ p: LayoutParams, scroll: CGFloat, minHeights: [WinID: CGFloat] = [:]) -> [LayoutItem] {
        var out: [LayoutItem] = []
        out.reserveCapacity(rows.count)
        let (x0, rowWidth) = Strip.rowExtent(p)
        var y = p.viewport.minY - scroll
        for row in rows {
            let top = y.rounded()
            let bottom = top + row.height
            y += row.height + p.gap
            let n = row.windows.count
            let available = rowWidth - p.gap * CGFloat(n - 1)
            let weights = row.windows.map(weight)
            let total = weights.reduce(0, +)
            // A lone, narrowed window keeps its width; the rest of the row stays empty.
            let loneWidth = n == 1 && weights[0] < 1 ? (rowWidth * weights[0]).rounded() : nil
            var x = x0
            if let lw = loneWidth, let o = widthOffsets[row.windows[0]] {
                x = min(x0 + (rowWidth * o).rounded(), x0 + rowWidth - lw)
            }
            for (i, id) in row.windows.enumerated() {
                // The last panel takes what's left so rounding never leaves a gap.
                let w = loneWidth ?? (i == n - 1 ? x0 + rowWidth - x : (available * weights[i] / total).rounded())
                defer { x += w + p.gap }
                let frame = CGRect(x: x, y: top, width: w, height: bottom - top)
                out.append(LayoutItem(id: id, placement: Strip.placement(frame, p, minHeight: minHeights[id]),
                                      rowHeight: row.height, frame: frame))
            }
        }
        return out
    }

    /// How a window whose full frame is `r` is shown, given the screen edges.
    public static func placement(_ r: CGRect, _ p: LayoutParams, minHeight: CGFloat? = nil) -> Placement {
        if r.maxY <= p.hardTop + 1 || r.minY >= p.hardBottom - 1 { return .park }
        if r.minY < p.hardTop || r.maxY > p.clipBottom + 1 {
            if p.topOverflow == .slide { return .overflow(r) }
            let top = max(r.minY, p.hardTop), visible = min(r.maxY, p.clipBottom) - top
            if p.topOverflow == .shrink && visible >= max(p.minVisible, minHeight ?? 0) {
                return .frame(CGRect(x: r.minX, y: top, width: r.width, height: visible))
            }
            return .park
        }
        return .frame(r)
    }
}
