import Cocoa
import OzCore
import QuartzCore

struct StripKey: Hashable {
    let space: SpaceID
    let display: CGDirectDisplayID
}

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleID: String?
    /// Last frame we applied (AX coordinates).
    var lastFrame: CGRect?
    /// Where its app put it when zooming it (floating windows).
    var zoomedFrame: CGRect?
    var parked = false
    var shrunk = false
    /// Its size was changed since the last settle (the app may have refused it).
    var needsSizeCheck = false
    var savedHeight: CGFloat?
    var frameCheck: DispatchWorkItem?

    /// Title as of when the window was found (read off the main thread; used for rules/events).
    var title: String

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, appName: String, bundleID: String?, title: String = "") {
        self.title = title
        self.id = id
        self.element = element
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
    }

}

/// What Oz needs to know about a window, gathered from its app in one go so it can be
/// done off the main thread (each AX read is a round trip to the app, which may be busy).
struct WindowProbe {
    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID
    let frame: CGRect?
    /// A standard, visible (not minimized / not fullscreen) window.
    let manageable: Bool
    let resizable: Bool
    /// An app's main window rather than a popup, alert or splash screen: it has a close
    /// button, can be made full screen (an app's secondary windows, like Blender's
    /// preferences or render window, only zoom) and doesn't block its app.
    let main: Bool
    let title: String

    static func read(_ el: AXUIElement, pid: pid_t) -> WindowProbe? {
        guard let wid = AX.windowID(el) else { return nil }
        let manageable = AX.string(el, kAXRoleAttribute) == kAXWindowRole
            && AX.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && AX.bool(el, kAXMinimizedAttribute) != true
            && AX.bool(el, "AXFullScreen") != true
        let resizable = manageable && AX.isSettable(el, kAXSizeAttribute) && AX.isSettable(el, kAXPositionAttribute)
        let main = manageable && AX.element(el, kAXCloseButtonAttribute) != nil
            && AX.element(el, "AXFullScreenButton") != nil
            && AX.bool(el, kAXModalAttribute) != true
        return WindowProbe(element: el, pid: pid, id: wid, frame: AX.frame(el), manageable: manageable,
                           resizable: resizable, main: main, title: manageable ? AX.string(el, kAXTitleAttribute) ?? "" : "")
    }

    static func readApp(_ pid: pid_t) -> [WindowProbe] {
        AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute).compactMap { read($0, pid: pid) }
    }

    /// All apps, in parallel.
    static func readApps(_ pids: [pid_t]) -> [WindowProbe] {
        let lock = NSLock()
        var out: [WindowProbe] = []
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let probes = readApp(pids[i])
            lock.lock()
            out += probes
            lock.unlock()
        }
        return out
    }
}

struct RuleResult {
    var float = false
    var ignore = false
    var height: CGFloat?
}

enum Command: String, CaseIterable {
    case focusUp, focusDown, focusLeft, focusRight, focusFirst, focusLast, focusRow
    case moveUp, moveDown, moveLeft, moveRight, moveFirst, moveLast
    case slurpIn, barfOut, joinUp, joinDown
    case cycleHeight, cycleHeightBack, setHeight, toggleFullHeight, resizeHeight
    case cycleWidth, cycleWidthBack, setWidth, resizeWidth, equalizeRow
    case center, alignTop, scrollUp, scrollDown, scrollBy, scrollToTop, scrollToBottom
    case toggleFloat, toggleMaximize, closeWindow, moveToNextScreen, undo
    case retile, toggleTiling, toggleSpaceTiling, editScrollArea, openSettings, reloadConfig
    case missionControl, appExpose, showDesktop, launchpad
}

final class WindowManager {
    var settings = Settings()
    private(set) var enabled = true

    /// Hooks wired up by the app delegate / config engine.
    var rulesProvider: ((ManagedWindow) -> RuleResult)?
    var emit: ((String, [String: Any]) -> Void)?
    var reloadConfig: (() -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    /// Opens the scroll area editor for a screen (owned by the app delegate).
    var editScrollArea: ((NSScreen) -> Void)?
    /// Opens the Settings window (owned by the app delegate).
    var openSettings: (() -> Void)?

    private var strips: [StripKey: Strip] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    private var floating: [CGWindowID: ManagedWindow] = [:]
    private var observers: [pid_t: AppObserver] = [:]
    private var minHeights: [CGWindowID: CGFloat] = [:]
    let snapshots = SnapshotCache()
    private let overlays = OverlayManager()
    /// Windows waiting for their stand-in to reach the screen before being moved away.
    private var pendingParks: [CGWindowID: DispatchWorkItem] = [:]

    private struct GestureState {
        let key: StripKey; let strip: Strip; let screen: NSScreen; let startScroll: CGFloat
        /// How far the finger may move the strip: magnetic scrolling stops it at the next
        /// window either way, otherwise the strip's ends.
        var range: ClosedRange<CGFloat>
        /// How far the fingers have gone on the trackpad (trackpad heights, the way they went).
        var padTravel = 0.0
        let startTime = CACurrentMediaTime()
        /// Where the fingers alone would have the strip (no stops), for the give at its ends.
        var free: CGFloat
    }
    private var gesture: GestureState?

    /// The window the user is resizing with the mouse right now; its neighbours reflow live.
    private var liveResize: (id: CGWindowID, key: StripKey)?
    private var liveReadInFlight = false
    /// New windows sent straight to their final frame; the layout leaves them alone while
    /// the rest of the strip animates around them.
    private var pinned = Set<CGWindowID>()
    /// Window to focus once its strip's scroll animation ends. Activating makes the app
    /// redraw in its focused look, and while it does it answers moves 50-70 ms late
    /// (measured), so focusing mid-glide made that window trail behind and then jump.
    private var pendingActivation: [StripKey: CGWindowID] = [:]
    /// Windows of slow apps drawn by a stand-in while the strip moves (real one parked).
    private var proxied = Set<CGWindowID>()
    /// When each stand-in was put up: the real window stays underneath, moving with it, until
    /// the stand-in has surely reached the screen (a new or resized overlay window takes a
    /// frame or two), and only then goes off screen. Parking it at once left a frame with
    /// neither on screen: the window flickered as a swipe started.
    private var proxyShownAt: [CGWindowID: CFTimeInterval] = [:]
    /// Stand-ins waiting for their real window to be back before fading (see `handOver`).
    private var handingOver = Set<CGWindowID>()
    private static let standInSettle: CFTimeInterval = 0.06
    /// Last focused window as reported by AX notifications (avoids asking the app).
    private var trackedFocus: CGWindowID?
    private var liveReadAgain = false

    private struct Animation {
        let strip: Strip
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: Double
        /// A damped spring instead of the ease-out: it starts at this speed (points/s, the
        /// way the strip moves) and swings past `to` before it settles there.
        var spring: Spring?

        struct Spring {
            static let damping = 0.7                // 1 = no swing past, lower = more
            static let omega = 2 * Double.pi / 0.45 // natural period 0.45 s
            let a: Double, b: Double, decay: Double, freq: Double
            /// Offset from the target `x0` with velocity `v0` (both points / points per s).
            init(x0: Double, v0: Double) {
                decay = Self.damping * Self.omega
                freq = Self.omega * (1 - Self.damping * Self.damping).squareRoot()
                a = x0
                b = (v0 + decay * x0) / freq
            }
            func offset(at time: Double) -> Double { exp(-decay * time) * (a * cos(freq * time) + b * sin(freq * time)) }
            /// Time until it is within half a point of the target for good.
            var duration: Double { max(0.1, log(max((a * a + b * b).squareRoot(), 0.5) / 0.5) / decay) }
        }

        /// Scroll position at `t` (0...1 of the duration).
        func scroll(at t: Double) -> CGFloat {
            if let spring {
                return t >= 1 ? to : to + CGFloat(spring.offset(at: t * duration))
            }
            return from + (to - from) * CGFloat(1 - pow(1 - t, 3))
        }
    }
    private var animations: [StripKey: Animation] = [:]
    /// Where each window of a strip was when a command rearranged it: during the strip's
    /// animation windows slide from there to their new place instead of jumping.
    private var transitions: [StripKey: [CGWindowID: CGRect]] = [:]
    /// Start frames recorded by `beginTransition`, picked up by the next animation.
    private var pendingFrom: [StripKey: [CGWindowID: CGRect]] = [:]
    /// Desktops (by `Spaces.persistentKey`) where tiling is off; their windows are left alone.
    private var untiledSpaces = Set(UserDefaults.standard.stringArray(forKey: "untiledSpaces") ?? [])
    /// The same desktops by their current SpaceID (refreshed when Spaces change).
    private var untiledIDs = Set<SpaceID>()
    /// Mission Control / App Exposé opened by Oz is up: windows sit where the overview can
    /// see them and layout waits until it closes.
    private var overviewActive = false
    /// Per strip, a window filling the whole screen (title bar double click / toggleMaximize)
    /// while the rest of the strip keeps its layout behind it.
    private var maximized: [StripKey: CGWindowID] = [:]
    /// The window growing to fill the screen or shrinking back, per strip, while it slides:
    /// on the way it leaves the Oz zone, and must not be cut off at the zone's edges.
    private var maximizeSliding: [StripKey: CGWindowID] = [:]
    /// Per desktop (by `Spaces.persistentKey`), the part of the screen the strip scrolls in,
    /// as fractions of the screen's visible frame (x, y from the top-left, width, height).
    /// Desktops without one use the whole screen.
    private var scrollAreas: [String: CGRect] = {
        var out: [String: CGRect] = [:]
        for (k, v) in UserDefaults.standard.dictionary(forKey: "scrollAreas") ?? [:] {
            if let a = v as? [Double], a.count == 4 { out[k] = CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
        }
        return out
    }()
    /// The scroll area of the desktop currently shown on each display.
    /// The same by current SpaceID, for every desktop (refreshed when Spaces change). Looked
    /// up through the desktop on screen right now: keyed by display, a desktop switch used the
    /// old desktop's area for a moment and windows jumped to the wrong width and back.
    private var areaBySpace: [SpaceID: CGRect] = [:]
    /// Saved arrangements (by desktop) not applied yet: each is put back once, the first time
    /// that desktop's windows are seen after Oz starts.
    private var pendingRestore: [String: StripState] = LayoutStore.load()
    private var lastSavedLayout: Data?
    /// A preset being opened on a desktop: its arrangement is applied as its apps' windows
    /// show up, for a while after it was opened.
    private var openingPreset: [StripKey: (preset: Preset, until: CFTimeInterval)] = [:]
    private var presetApplyWork: [StripKey: DispatchWorkItem] = [:]
    /// Per strip, its arrangement before each of the last layout changes, for `undo`.
    private var undoStacks: [StripKey: [StripState]] = [:]
    private static let undoDepth = 20
    private var saveTimer: Timer?
    /// A double click just landed on this window's title bar; its app may zoom it.
    private var zoomClick: (id: CGWindowID, key: StripKey, frame: CGRect)?
    /// Floating and docked windows their app zoomed (title bar double click), with where
    /// they were before: put back there once another window gets focus.
    private var appZoomed: [CGWindowID: CGRect] = [:]
    /// Floating and docked windows sent to the Dock: brought back, they go back there (the
    /// region and place they had) rather than into the strip.
    private var minimizedFloating: [CGWindowID: (manual: Bool, dock: (key: StripKey, region: Int, index: Int)?)] = [:]
    /// The floating window under the last single click and where it was: by the time Oz sees
    /// a double click (a global event, after the app's), its app may have zoomed it already.
    private var clickedFloating: (id: CGWindowID, frame: CGRect)?
    /// Floating windows the user took out of the strip (dragged out of the scroll area, a
    /// tab torn off outside it, toggleFloat): dropping one into a scroll area tiles it again.
    /// Windows floating because of a rule or a fixed size are not in here.
    private var manualFloat = Set<CGWindowID>()
    /// Tiled windows the user is dragging by the mouse (our own moves aren't).
    private var userDragged: [CGWindowID: CFTimeInterval] = [:]
    /// Tiled windows the user resized by an edge with the mouse, and when.
    private var userResized: [CGWindowID: CFTimeInterval] = [:]
    /// When Oz last put a window back to the size it gave it (see `compareFrame`): an app that
    /// insists on its own width isn't fought over and over.
    private var sizeEnforcedAt: [CGWindowID: CFTimeInterval] = [:]
    /// Floating windows being dragged (or a tab being torn off): placed when the mouse is let go.
    private var pendingDrops = Set<CGWindowID>()
    /// Where (AX coordinates) and when the left mouse button was last let go: a drag "lands"
    /// in the zone or region that holds the cursor at that moment.
    private var lastMouseUp: (point: CGPoint, at: CFTimeInterval)?
    /// Windows tiled in the regions outside the Oz zone (see `OutsideRegions`), per desktop:
    /// region index -> windows in order along the region's long side.
    private var docks: [StripKey: [Int: [CGWindowID]]] = [:]
    /// When Oz last moved a docked window (its move notifications aren't a user drag).
    private var dockPlacedAt: [CGWindowID: CFTimeInterval] = [:]
    /// The window the user is dragging right now (from its move notifications), whose
    /// landing place the drop preview shows.
    private var dragging: CGWindowID?
    private let dropPreview = DropPreview()
    private let insertionLine = InsertionLine()
    /// One scroll position bar per display, and the scroll it last showed per strip.
    private var scrollIndicators: [CGDirectDisplayID: ScrollIndicator] = [:]
    private var indicatedScroll: [StripKey: CGFloat] = [:]
    private var lastPreviewUpdate: CFTimeInterval = 0
    /// The tiled window whose edge is being dragged (until the mouse is let go).
    private var resizeDrag: CGWindowID?
    /// The strip scrolling under a drag: its current speed (points/s, positive = down),
    /// easing towards what the cursor's place in the edge bands asks for. Once started it
    /// lasts until the mouse is let go or leaves the zone (back in the middle the speed just
    /// drops to zero), so the windows aren't swapped between snapshots and real ones on every
    /// pass over a band's border.
    private var autoScroll: (key: StripKey, velocity: CGFloat, last: CFTimeInterval)?
    /// The drag has been in the middle of a zone (outside the edge bands) at least once, so
    /// it's not just a title bar grabbed at the top of the zone.
    private var dragScrollArmed = false
    /// The tiled window the user let go of, and when: it was dragged, however long ago its
    /// last move was (resting while the strip scrolls sends none).
    private var dropped: (id: CGWindowID, at: CFTimeInterval)?
    /// Where the left button went down (AX coordinates), while it's down. A window counts as
    /// dragged (or resized) by the user only once the cursor has left this spot: Oz's own
    /// moves while the button happens to be down are not drags.
    private var mouseDownAt: CGPoint?
    /// A window focused while the button was down: shown (scrolled to) once it's let go, not
    /// while it's held — moving a window under a held title bar makes macOS drag it along.
    private var revealOnMouseUp: CGWindowID?
    /// Since when the cursor rests in an edge band (scrolling starts after a short dwell, not
    /// when it merely passes through), and the timer that notices while it doesn't move.
    private var bandSince: CFTimeInterval?
    private var dwellTimer: Timer?
    private static let bandDwell = 0.35
    /// Strips whose layout must be re-applied on the next display frame.
    private var dirty = Set<StripKey>()
    private let driver = FrameDriver()
    let writer = AXWriter()

    private enum AddMode { case scan, created }

    // MARK: Lifecycle

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appLaunched(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Spaces.invalidate()
            // Give the window server a moment to settle the new Space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.spaceChanged()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Spaces.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.screensChanged() }
        }
        // While the screen is locked apps report no windows: a scan then (e.g. Oz started at
        // the lock screen) finds nothing, so look again once it is unlocked.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.scanAll(initial: false) }
        }
        driver.onFrame = { [weak self] in self?.frame() }
        // Clicks in other apps (global) and on Oz's own windows (local: peeks, editors).
        // Monitors run on the main thread: handled right away, before any AX notification
        // the click causes is looked at.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseWentUp() }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            self?.mouseWentUp()
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            DispatchQueue.main.async { self?.updateDropPreview() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.mouseWentDown(doubleClick: e.clickCount == 2)
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.mouseWentDown(doubleClick: false)
            return e
        }
        writer.onMinHeight = { [weak self] id, h in
            // The app refused to get that small at the top edge: remember it, re-evaluate.
            guard let self else { return }
            self.minHeights[id] = h
            if let (key, _) = self.locate(id) { self.markDirty(key) }
        }
        if settings.topOverflow == .slide { snapshots.requestPermissionOnce() }
        overlays.live = settings.livePeek
        overlays.liveFPS = settings.livePeekFPS
        overlays.captureScale = settings.captureScale
        snapshots.scale = settings.captureScale
        setupSnapshots()
        scanAll(initial: true)
        // Written when it changed: a few seconds of rearranging at most are lost to a crash.
        // The same tick tidies up what piles up over a long run.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.saveLayout()
            self?.housekeeping()
        }
        saveTimer?.tolerance = 1
    }

    /// Put every hidden/shrunk window back on screen (on quit or when tiling is turned off).
    func restoreAll() {
        overlays.hideAll()
        animations.removeAll()
        transitions.removeAll()
        pendingFrom.removeAll()
        dirty.removeAll()
        driver.pause()
        // Let queued moves land first, or they would undo the restore.
        writer.waitUntilIdle()
        var offset: CGFloat = 0
        for (key, strip) in strips {
            for (w, r) in restoreFrames(strip, key: key, offset: &offset) {
                AX.setPosition(w.element, r.origin)
                AX.setSize(w.element, r.size)
            }
        }
    }

    /// On-screen frames for the strip's hidden (parked or shrunk) windows, cascaded from the
    /// top-left so none of them is lost off screen.
    private func restoreFrames(_ strip: Strip, key: StripKey, offset: inout CGFloat) -> [(ManagedWindow, CGRect)] {
        guard let screen = Geometry.screen(displayID: key.display) ?? NSScreen.main else { return [] }
        // The strip's own desktop's area (quitting puts back the windows of every desktop).
        let vp = scrollArea(screen, space: key.space).insetBy(dx: settings.outerGap, dy: settings.outerGap)
        var out: [(ManagedWindow, CGRect)] = []
        for row in strip.rows {
            for id in row.windows {
                guard let w = windows[id], w.parked || w.shrunk else { continue }
                let h = min(row.height, vp.height - offset)
                out.append((w, CGRect(x: vp.minX + offset, y: vp.minY + offset, width: vp.width - offset, height: max(h, 200))))
                offset = (offset + 28).truncatingRemainder(dividingBy: 280)
            }
        }
        return out
    }

    // MARK: Scroll indicator

    /// Shows where the view is in the strip while it scrolls (nothing when it all fits, or a
    /// window fills the screen).
    private func updateScrollIndicator(_ key: StripKey, strip: Strip, screen: NSScreen) {
        let display = key.display
        guard indicatedScroll[key] != strip.renderScrollY else { return }
        indicatedScroll[key] = strip.renderScrollY
        let vp = viewport(screen)
        let content = strip.contentHeight(gap: settings.gap)
        guard content > vp.height + 1, maximizedID(key) == nil else {
            scrollIndicators[display]?.hide()
            return
        }
        let thumb = max(36, (vp.height * vp.height / content).rounded())
        let progress = min(max(strip.renderScrollY / (content - vp.height), 0), 1)
        let y = (vp.minY + (vp.height - thumb) * progress).rounded()
        let x = scrollArea(screen).maxX - max(settings.outerGap / 2, 3) - ScrollIndicator.width / 2
        let indicator = scrollIndicators[display] ?? ScrollIndicator()
        scrollIndicators[display] = indicator
        indicator.show(CGRect(x: x.rounded(), y: y, width: ScrollIndicator.width, height: thumb))
    }

    private func hideScrollIndicators() {
        scrollIndicators.values.forEach { $0.hide() }
        indicatedScroll.removeAll()
    }

    // MARK: Undo

    /// Remembers the strip's arrangement before a change (unless it's the same as last time).
    private func recordUndo(_ key: StripKey) {
        guard let strip = strips[key] else { return }
        let state = strip.state()
        var stack = undoStacks[key] ?? []
        if stack.last == state { return }
        stack.append(state)
        if stack.count > Self.undoDepth { stack.removeFirst(stack.count - Self.undoDepth) }
        undoStacks[key] = stack
    }

    /// Puts the strip back as it was before its last change, sliding the windows there.
    /// Windows taken out of it since (dragged out, floated) come back; closed ones are skipped.
    private func undo(_ key: StripKey, strip s: Strip, viewportHeight vh: CGFloat) -> Bool {
        guard var stack = undoStacks[key] else { return false }
        // Skip states that are what's on screen now (a change that didn't change anything).
        var target: StripState?
        while let last = stack.popLast() {
            if last != s.state() { target = last; break }
        }
        undoStacks[key] = stack.isEmpty ? nil : stack
        guard let target else { return false }
        beginTransition(key, recordUndo: false)
        for saved in target.rows.flatMap(\.windows) where windows[saved.id] == nil {
            guard let w = floating[saved.id], manualFloat.contains(saved.id) else { continue }
            undock(saved.id)
            floating.removeValue(forKey: saved.id)
            manualFloat.remove(saved.id)
            windows[saved.id] = w
            s.insertRow(saved.id, height: vh / 2, before: nil)
            if settings.animationDuration > 0, let f = w.lastFrame { pendingFrom[key, default: [:]][saved.id] = f }
        }
        s.restore(target, maxHeight: vh) { w, used in s.contains(w.id) && !used.contains(w.id) ? w.id : nil }
        s.scrollY = s.clampScroll(s.scrollY, viewportHeight: vh, gap: settings.gap)
        Log.debug("undo: \(undoStacks[key]?.count ?? 0) step(s) left")
        relayout(key, animated: true)
        return true
    }

    // MARK: Housekeeping

    /// Keeps a long-running Oz small: drops empty strips left by looking at a desktop and the
    /// per-strip and per-window bookkeeping of things that are gone. (Snapshots of windows
    /// stay: they are freed when their window closes.)
    private func housekeeping() {
        guard enabled, !isMoving, !overviewActive else { return }
        let visible = visibleKeys()
        snapshots.forgetOldFailures()

        for (key, strip) in strips where strip.isEmpty && visible[key] == nil && animations[key] == nil {
            strips.removeValue(forKey: key)
        }
        let live = Set(strips.keys)
        for key in Array(undoStacks.keys) where !live.contains(key) { undoStacks.removeValue(forKey: key) }
        for key in Array(indicatedScroll.keys) where !live.contains(key) { indicatedScroll.removeValue(forKey: key) }
        for key in Array(maximized.keys) where !live.contains(key) { maximized.removeValue(forKey: key) }
        for key in Array(pendingActivation.keys) where !live.contains(key) { pendingActivation.removeValue(forKey: key) }
        let now = CACurrentMediaTime()
        for (id, t) in userDragged where now - t > 10 { userDragged.removeValue(forKey: id) }
        for (id, t) in userResized where now - t > 10 { userResized.removeValue(forKey: id) }
        for (id, t) in sizeEnforcedAt where now - t > 10 { sizeEnforcedAt.removeValue(forKey: id) }
        for (id, t) in lastResnap where now - t > 10 || windows[id] == nil { lastResnap.removeValue(forKey: id) }
        for (id, t) in dockPlacedAt where now - t > 10 { dockPlacedAt.removeValue(forKey: id) }
        for key in Array(docks.keys) where docks[key]?.isEmpty ?? true { docks.removeValue(forKey: key) }
        for id in Array(proxyShownAt.keys) where !proxied.contains(id) { proxyShownAt.removeValue(forKey: id) }
    }

    // MARK: Presets

    /// The desktop on `screen` as a preset: the apps of its windows (tiled and docked around
    /// the scroll area), their arrangement and the scroll area. nil for an empty desktop.
    func capturePreset(named name: String?, screen: NSScreen) -> Preset? {
        let key = visibleKey(for: screen)
        var state = strips[key]?.state(describe: describe) ?? StripState()
        for (region, ids) in docks[key] ?? [:] {
            state.docks[String(region)] = ids.compactMap(describe).map {
                StripState.Window(id: $0.id, app: $0.app, bundleID: $0.bundleID, title: $0.title)
            }
        }
        var apps: [Preset.App] = []
        var seen = Set<String>()
        for id in state.windowIDs {
            guard let w = windows[id] ?? floating[id], seen.insert(w.bundleID ?? w.appName).inserted else { continue }
            let path = NSRunningApplication(processIdentifier: w.pid)?.bundleURL?.path
            apps.append(Preset.App(bundleID: w.bundleID, name: w.appName, path: path))
        }
        guard !apps.isEmpty else { return nil }
        let area = scrollAreaFraction(screen).map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Preset(name: trimmed?.isEmpty == false ? trimmed! : Preset.defaultName(for: apps),
                      desktop: state, scrollArea: area, apps: apps)
    }

    /// Opens a preset on the desktop on `screen`: its scroll area, its apps (launched in the
    /// background if they aren't running), and its arrangement, applied as their windows show
    /// up (for 30 s). Apps already running are asked to reopen (what clicking them in the Dock
    /// does) unless they have a window on this desktop already.
    func openPreset(_ preset: Preset, screen: NSScreen) {
        guard enabled else { return }
        if !isTiled(screen: screen) { setSpaceTiled(true, screen: screen) }
        if let a = preset.scrollArea, a.count == 4 {
            setScrollArea(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), screen: screen)
        } else if scrollAreaFraction(screen) != nil {
            setScrollArea(nil, screen: screen)
        }
        let key = visibleKey(for: screen)
        openingPreset[key] = (preset, CACurrentMediaTime() + 30)
        let here = Set((strips[key]?.windowIDs ?? []) + (docks[key].map { Array($0.values.joined()) } ?? []))
        let appsHere = Set(here.compactMap { (windows[$0] ?? floating[$0]).map { $0.bundleID ?? $0.appName } })
        for app in preset.apps where !appsHere.contains(app.bundleID ?? app.name) {
            let url = app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                ?? app.path.map { URL(fileURLWithPath: $0) }
            guard let url else {
                Log.info("preset \(preset.name): \(app.name) not found")
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { Log.info("preset \(preset.name): could not open \(app.name): \(error.localizedDescription)") }
            }
        }
        Log.info("opening preset \(preset.name): \(preset.apps.map(\.name).joined(separator: ", "))")
        applyOpeningPreset(key)
    }

    /// Checks, once things have settled, that a window Oz just placed is really there: an app
    /// opening a window (Finder's opening animation, for one) can put it back where it wanted
    /// after Oz moved it, while Oz took that move for its own and ignored it. Twice, as some
    /// apps take a while.
    private func verifyPlacement(_ id: CGWindowID) {
        for delay in [0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let w = self.windows[id] else { return }
                self.scheduleFrameCheck(w)
            }
        }
    }

    /// Windows arrive one by one as apps start: arrange once they've settled for a moment.
    private func schedulePresetApply(_ key: StripKey) {
        guard openingPreset[key] != nil else { return }
        presetApplyWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyOpeningPreset(key) }
        presetApplyWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Puts the windows on this desktop where the preset has them (matched by app and, where
    /// it still fits, title); finished once every window of the preset is placed or time's up.
    private func applyOpeningPreset(_ key: StripKey) {
        presetApplyWork.removeValue(forKey: key)
        guard let (preset, until) = openingPreset[key] else { return }
        guard CACurrentMediaTime() < until, enabled else {
            openingPreset.removeValue(forKey: key)
            return
        }
        let strip = self.strip(key)
        let candidates = (strip.windowIDs + (docks[key].map { Array($0.values.joined()) } ?? [])).compactMap(describe)
        var used = Set<CGWindowID>()
        var docked: [Int: [CGWindowID]] = [:]
        for (region, list) in preset.desktop.docks {
            guard let i = Int(region) else { continue }
            for w in list {
                if let id = WindowMatcher.matchLoosely(w, in: candidates, excluding: used) {
                    used.insert(id)
                    docked[i, default: []].append(id)
                }
            }
        }
        beginTransition(key)
        for id in docked.values.joined() {
            guard let w = windows.removeValue(forKey: id) else { continue }
            strip.remove(id)
            floating[id] = w
            manualFloat.insert(id)
        }
        if !docked.isEmpty { docks[key] = docked }
        let vh = viewportHeight(key)
        let from = strip.renderScrollY
        let matched = strip.restore(preset.desktop, maxHeight: vh) { w, u in
            WindowMatcher.matchLoosely(w, in: candidates, excluding: u.union(used))
        }
        // Slide there from where it is.
        strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
        strip.renderScrollY = from
        relayout(key, animated: true)
        layoutDocks(key)
        matched.forEach(verifyPlacement)
        let placed = matched.count + docked.values.joined().count
        if placed >= preset.desktop.windowIDs.count {
            openingPreset.removeValue(forKey: key)
            Log.info("preset \(preset.name) open: \(placed) window(s) in place")
        }
    }

    // MARK: Saved layout

    private func describe(_ id: CGWindowID) -> WindowDescription? {
        (windows[id] ?? floating[id]).map { WindowDescription(id: $0.id, app: $0.appName, bundleID: $0.bundleID, title: $0.title) }
    }

    /// Height of a strip's own viewport (its desktop may not be the one on screen).
    private func viewportHeight(_ key: StripKey) -> CGFloat {
        guard let screen = Geometry.screen(displayID: key.display) ?? NSScreen.main else { return 800 }
        return scrollArea(screen, space: key.space).insetBy(dx: settings.outerGap, dy: settings.outerGap).height
    }

    /// Puts back the saved arrangement of every desktop whose windows are here now for the
    /// first time since Oz started: rows, heights, widths and places, scroll, focus, and the
    /// windows docked around the zone. Windows it doesn't know stay after them in their order.
    /// Returns the strips it rearranged.
    private func applyPendingRestores() -> Set<StripKey> {
        guard !pendingRestore.isEmpty else { return [] }
        let displays = Spaces.displays()
        var done = Set<StripKey>()
        for (key, strip) in strips {
            guard let name = Spaces.persistentKey(key.space, displays: displays), let saved = pendingRestore[name] else { continue }
            let candidates = strip.windowIDs.compactMap(describe)
            // Docked windows first: they were picked up as tiled; take them out of the strip.
            var used = Set<CGWindowID>()
            var docked: [Int: [CGWindowID]] = [:]
            for (region, list) in saved.docks {
                guard let i = Int(region) else { continue }
                for w in list {
                    if let id = WindowMatcher.match(w, in: candidates, excluding: used) {
                        used.insert(id)
                        docked[i, default: []].append(id)
                    }
                }
            }
            let vh = viewportHeight(key)
            let matched = strip.restore(saved, maxHeight: vh) { w, u in
                WindowMatcher.match(w, in: candidates, excluding: u.union(used))
            }
            // None of its windows here yet (another desktop, read later): try again next scan.
            guard !matched.isEmpty || !docked.isEmpty else { continue }
            for id in docked.values.joined() {
                guard let w = windows.removeValue(forKey: id) else { continue }
                strip.remove(id)
                floating[id] = w
                manualFloat.insert(id)
            }
            if !docked.isEmpty { docks[key] = docked }
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
            strip.renderScrollY = strip.scrollY
            pendingRestore[name] = nil
            done.insert(key)
            Log.info("restored desktop \(name): \(matched.count) tiled, \(docked.values.joined().count) docked")
            if strip.isEmpty { strips.removeValue(forKey: key) }
            layoutDocks(key)
        }
        return done
    }

    /// Writes every desktop's arrangement to disk if it changed (desktops not seen since the
    /// start keep what was saved for them).
    func saveLayout() {
        guard enabled else { return }
        let displays = Spaces.displays()
        var desktops = pendingRestore
        for (key, strip) in strips {
            guard let name = Spaces.persistentKey(key.space, displays: displays) else { continue }
            var state = strip.state(describe: describe)
            for (region, ids) in docks[key] ?? [:] {
                state.docks[String(region)] = ids.compactMap(describe).map {
                    StripState.Window(id: $0.id, app: $0.app, bundleID: $0.bundleID, title: $0.title)
                }
            }
            desktops[name] = state
        }
        for (key, regions) in docks where strips[key] == nil {
            guard let name = Spaces.persistentKey(key.space, displays: displays) else { continue }
            var state = StripState()
            for (region, ids) in regions {
                state.docks[String(region)] = ids.compactMap(describe).map {
                    StripState.Window(id: $0.id, app: $0.app, bundleID: $0.bundleID, title: $0.title)
                }
            }
            desktops[name] = state
        }
        guard let data = LayoutStore.encode(desktops), data != lastSavedLayout else { return }
        lastSavedLayout = data
        LayoutStore.write(data)
    }

    // MARK: Tiling per desktop

    /// Whether the desktop currently shown on `screen` is tiled.
    func isTiled(screen: NSScreen) -> Bool {
        !untiledIDs.contains(visibleKey(for: screen).space)
    }

    /// Re-reads which desktops are untiled and each display's scroll area (SpaceIDs change
    /// as desktops are added, removed or Oz restarts; the persistent names don't).
    private func refreshUntiledIDs(_ displays: [Spaces.Display] = Spaces.displays()) {
        var ids = Set<SpaceID>()
        for d in displays {
            for (id, name) in d.keys where untiledSpaces.contains(name) { ids.insert(id) }
        }
        untiledIDs = ids
        var areas: [SpaceID: CGRect] = [:]
        for d in displays {
            for (id, name) in d.keys { if let a = scrollAreas[name] { areas[id] = a } }
        }
        areaBySpace = areas
    }

    // MARK: Live peeks

    func setSmoothScroll(_ on: Bool) {
        settings.smoothScroll = on
        Log.info("smooth scrolling \(on ? "on" : "off")")
    }

    /// Windows peeking over an edge: streamed live (video keeps playing) or a still picture.
    func setLivePeek(_ on: Bool) {
        settings.livePeek = on
        overlays.setLive(on)
        Log.info("live peeks \(on ? "on" : "off")")
    }

    // MARK: Scroll area

    /// The current desktop's scroll area on `screen` as fractions of its visible frame, nil for all of it.
    func scrollAreaFraction(_ screen: NSScreen) -> CGRect? {
        areaBySpace[visibleKey(for: screen).space]
    }

    /// Sets (nil: clears) the scroll area of the desktop shown on `screen`. The strip slides
    /// into its new bounds; remembered across restarts.
    func setScrollArea(_ fraction: CGRect?, screen: NSScreen) {
        let displays = Spaces.displays()
        let key = visibleKey(for: screen, displays: displays)
        guard let name = Spaces.persistentKey(key.space, displays: displays) else { return }
        beginTransition(key)
        scrollAreas[name] = fraction
        UserDefaults.standard.set(scrollAreas.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: "scrollAreas")
        refreshUntiledIDs(displays)
        Log.info("scroll area for desktop \(name): \(fraction.map { "\($0)" } ?? "whole screen")")
        redock(key)
        guard let strip = strips[key] else {
            pendingFrom.removeValue(forKey: key)
            return
        }
        let vh = viewport(screen).height
        // Rows taller than the new area would never fit.
        for row in strip.rows { row.height = min(row.height, vh) }
        if let f = strip.focused {
            strip.scrollY = strip.scrollToReveal(f, viewportHeight: vh, gap: settings.gap)
        }
        strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
        relayout(key, animated: true)
        if Log.debugEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.dumpState(key) }
        }
    }

    /// Debug log: what Oz believes about each window vs where it really is.
    private func dumpState(_ key: StripKey) {
        guard let strip = strips[key], let screen = visibleScreen(key) else { return }
        let p = params(screen)
        Log.debug("[dump] area=\(scrollArea(screen)) hardTop=\(p.hardTop) hardBottom=\(p.hardBottom) cut=\(p.cutBottom) scroll=\(strip.scrollY)/\(strip.renderScrollY) moving=\(isMoving)")
        for item in strip.layout(p, scroll: strip.renderScrollY, minHeights: minHeights) {
            guard let w = windows[item.id] else { continue }
            let id = w.id, name = w.appName, parked = w.parked, shrunk = w.shrunk, last = w.lastFrame
            let overlay = overlays.isShowing(id), prox = proxied.contains(id), pin = pinned.contains(id)
            let element = w.element
            writer.perform(pid: w.pid) {
                let actual = AX.frame(element)
                Log.debug("[dump] \(id) \(name) want=\(item.placement) last=\(String(describing: last)) actual=\(String(describing: actual)) parked=\(parked) shrunk=\(shrunk) overlay=\(overlay) proxied=\(prox) pinned=\(pin)")
            }
        }
    }

    /// The part of `screen` (AX coordinates) its current desktop's strip scrolls in.
    /// `space`: another desktop's area on this screen than the one showing.
    private func scrollArea(_ screen: NSScreen, space: SpaceID? = nil) -> CGRect {
        let vf = Geometry.ax(screen.usableFrame)
        guard let f = areaBySpace[space ?? visibleKey(for: screen).space] else { return vf }
        return CGRect(x: vf.minX + f.minX * vf.width, y: vf.minY + f.minY * vf.height,
                      width: f.width * vf.width, height: f.height * vf.height).integral.intersection(vf)
    }

    /// Turns tiling on or off for the desktop shown on `screen`. Off: its windows stay
    /// where they are (hidden ones come back on screen) and Oz leaves them alone; on: they
    /// are picked up again like at startup. Remembered across restarts.
    func setSpaceTiled(_ on: Bool, screen: NSScreen) {
        let displays = Spaces.displays()
        let key = visibleKey(for: screen, displays: displays)
        guard let name = Spaces.persistentKey(key.space, displays: displays) else {
            Log.info("tiling per desktop: space \(key.space) not found")
            return
        }
        if on { untiledSpaces.remove(name) } else { untiledSpaces.insert(name) }
        UserDefaults.standard.set(Array(untiledSpaces).sorted(), forKey: "untiledSpaces")
        refreshUntiledIDs(displays)
        if on {
            scanAll(initial: false)
        } else {
            release(key)
        }
        Log.info("tiling \(on ? "on" : "off") for desktop \(name)")
        onEnabledChanged?(enabled)
        emit?("spaceTilingChanged", ["tiled": on, "space": key.space])
    }

    /// Stops tiling a strip without moving its visible windows.
    private func release(_ key: StripKey) {
        guard let strip = strips[key] else { return }
        if gesture?.key == key { gesture = nil }
        animations.removeValue(forKey: key)
        transitions.removeValue(forKey: key)
        maximizeSliding.removeValue(forKey: key)
        pendingFrom.removeValue(forKey: key)
        pendingActivation.removeValue(forKey: key)
        maximized.removeValue(forKey: key)
        docks.removeValue(forKey: key)
        undoStacks.removeValue(forKey: key)
        dirty.remove(key)
        var offset: CGFloat = 0
        let hidden = restoreFrames(strip, key: key, offset: &offset)
        for id in strip.windowIDs {
            pinned.remove(id)
            proxied.remove(id)
            pendingParks.removeValue(forKey: id)?.cancel()
            overlays.remove(id)
            snapshots.remove(id)
            minHeights.removeValue(forKey: id)
            windows.removeValue(forKey: id)?.frameCheck?.cancel()
        }
        // Queued after any pending move of the same window, so it wins.
        for (w, r) in hidden {
            writer.move(w.id, pid: w.pid, element: w.element, to: r, setSize: true)
        }
        strips.removeValue(forKey: key)
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            enabled = true
            // Back as it was when tiling was turned off.
            pendingRestore = LayoutStore.load()
            scanAll(initial: true)
        } else {
            saveLayout()
            restoreAll()
            enabled = false
            strips.removeAll()
            windows.removeAll()
            floating.removeAll()
            minHeights.removeAll()
            maximized.removeAll()
            zoomClick = nil
            manualFloat.removeAll()
            undoStacks.removeAll()
            userDragged.removeAll()
            dragging = nil
            dropPreview.hide()
            insertionLine.hide()
            pendingDrops.removeAll()
            docks.removeAll()
            gesture = nil
        }
        onEnabledChanged?(enabled)
    }

    func settingsChanged() {
        if settings.topOverflow == .slide { snapshots.requestPermissionOnce() }
        overlays.hideAll()
        overlays.live = settings.livePeek
        overlays.liveFPS = settings.livePeekFPS
        overlays.captureScale = settings.captureScale
        snapshots.scale = settings.captureScale
        for w in windows.values { w.lastFrame = nil; w.parked = false }
        layoutVisible(animated: false)
    }

    // MARK: Discovery

    private func managedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() && Self.hasWindows($0) }
    }

    /// Steam's main window belongs to "Steam Helper", a helper without a Dock icon.
    static let steamHelper = "com.valvesoftware.steam.helper"

    /// An app whose windows Oz tiles: a regular one (in the Dock), or Steam's helper.
    static func hasWindows(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular || app.bundleIdentifier == steamHelper
    }

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil,
              let o = AppObserver(pid: pid, schedule: { [writer] work in writer.perform(pid: pid, work) }) else { return }
        // Chromium/Electron animate every AX move while this is on, which makes scrolling sluggish.
        let app = o.app
        writer.perform(pid: pid) {
            if AX.bool(app, "AXEnhancedUserInterface") == true {
                AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse)
            }
        }
        o.handler = { [weak self] name, element, pid in
            self?.handle(notification: name, element: element, pid: pid)
        }
        observers[pid] = o
    }

    /// Finds all windows. At startup this blocks (nothing to keep smooth yet); on later
    /// rescans (Space switches) the reading happens in the background.
    func scanAll(initial: Bool) {
        guard enabled else { return }
        refreshUntiledIDs()
        let apps = managedApps()
        apps.forEach { ensureObserver($0.processIdentifier) }
        let pids = apps.filter { !$0.isHidden }.map(\.processIdentifier)
        if initial {
            finishScan(WindowProbe.readApps(pids), initial: true)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let probes = WindowProbe.readApps(pids)
                DispatchQueue.main.async { self?.finishScan(probes, initial: false) }
            }
        }
    }

    private func finishScan(_ probes: [WindowProbe], initial: Bool) {
        guard enabled else { return }
        let found = probes.sorted { a, b in
            let fa = a.frame ?? .zero, fb = b.frame ?? .zero
            return fa.minY != fb.minY ? fa.minY < fb.minY : fa.minX < fb.minX
        }
        let alive = Set(found.map(\.id))
        // One window-server query for all of them instead of one per window.
        let onServer = Self.existingWindowIDs()
        for id in Array(windows.keys) where !alive.contains(id) && !onServer.contains(id) {
            unmanage(id, focusNeighbor: false)
        }
        for id in Array(floating.keys) where !alive.contains(id) && !onServer.contains(id) {
            forgetFloating(id)
        }
        for p in found {
            if windows[p.id] != nil {
                if !p.manageable {
                    unmanage(p.id, focusNeighbor: false)
                } else {
                    reassignSpaceIfNeeded(p.id)
                }
            } else if floating[p.id] == nil && (initial || onServer.contains(p.id)) {
                add(p, mode: .scan)
            }
        }

        if initial, let fid = systemFocusedWindowID(), let (_, strip) = locate(fid) {
            strip.focused = fid
        }
        let restored = applyPendingRestores()
        for (key, strip) in strips where isVisible(key) && !restored.contains(key) {
            if let f = strip.focused, let screen = Geometry.screen(displayID: key.display) {
                let vh = viewport(screen).height
                strip.scrollY = strip.clampScroll(strip.scrollToReveal(f, viewportHeight: vh, gap: settings.gap),
                                                  viewportHeight: vh, gap: settings.gap)
            }
        }
        layoutVisible(animated: false)
        for key in openingPreset.keys { schedulePresetApply(key) }
        Log.info("scan: \(windows.count) tiled, \(floating.count) floating, \(strips.count) strip(s)")
    }

    /// Reads one app's windows on its queue and adds the new ones.
    private func scanApp(_ pid: pid_t, mode: AddMode) {
        guard enabled else { return }
        ensureObserver(pid)
        writer.perform(pid: pid) { [weak self] in
            let probes = WindowProbe.readApp(pid)
            DispatchQueue.main.async {
                guard let self else { return }
                probes.forEach { self.add($0, mode: mode) }
                if mode == .scan { self.layoutVisible(animated: false) }
            }
        }
    }

    /// Adds a window the app just reported (created / deminiaturized).
    private func addWindow(_ el: AXUIElement, pid: pid_t, mode: AddMode) {
        guard enabled else { return }
        writer.perform(pid: pid) { [weak self] in
            guard let probe = WindowProbe.read(el, pid: pid) else { return }
            DispatchQueue.main.async { self?.add(probe, mode: mode) }
        }
    }

    /// Every window the window server knows of, on any desktop.
    private static func existingWindowIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    private func add(_ probe: WindowProbe, mode: AddMode) {
        let wid = probe.id, pid = probe.pid, el = probe.element
        guard enabled, pid != getpid(), windows[wid] == nil, floating[wid] == nil, probe.manageable else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.isHidden == true { return }
        let w = ManagedWindow(id: wid, element: el, pid: pid, appName: app?.localizedName ?? "?",
                              bundleID: app?.bundleIdentifier, title: probe.title)
        let rule = rulesProvider?(w) ?? RuleResult()
        if rule.ignore { return }
        ensureObserver(pid)
        observers[pid]?.watch(window: el)

        // Blender's other windows (preferences, render, editors) look just like its main one;
        // only the main one has "Blender" in its title.
        // Steam draws its own title bar (no buttons): its main window is the one titled
        // "Steam"; its menus and notifications are other Steam Helper windows.
        let secondary = w.bundleID == Self.steamHelper ? probe.title != "Steam"
            : !probe.main || (w.bundleID == "org.blenderfoundation.blender" && !probe.title.contains("Blender"))
        if let m = minimizedFloating.removeValue(forKey: wid) {
            floating[wid] = w
            if m.manual { manualFloat.insert(wid) }
            if let d = m.dock {
                var list = (docks[d.key]?[d.region] ?? []).filter { floating[$0] != nil }
                list.insert(wid, at: min(d.index, list.count))
                docks[d.key, default: [:]][d.region] = list
                layoutDocks(d.key)
                checkDocked(w, key: d.key)
            }
            Log.debug("\(wid) \(w.appName) back from the Dock, floating\(m.dock != nil ? " (docked)" : "")")
            emit?("windowCreated", info(w))
            return
        }
        if rule.float || !probe.resizable || secondary {
            if secondary { Log.info("float \(wid) \(w.appName) '\(w.title)': not a main window") }
            floating[wid] = w
            emit?("windowCreated", info(w))
            return
        }
        if mode == .created && NSEvent.pressedMouseButtons & 1 != 0 && cursorMovedSinceMouseDown() {
            // Born under a dragging mouse: a tab torn off its window. Where it's let go decides
            // whether it joins the strip (inside a scroll area) or floats there (outside).
            floating[wid] = w
            manualFloat.insert(wid)
            pendingDrops.insert(wid)
            dragging = wid
            Log.debug("torn-off window \(wid) \(w.appName): waiting for the drop")
            // Let go before we saw it (a quick flick): place it now rather than leave it floating.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.resolveDrops() }
            }
            emit?("windowCreated", info(w))
            return
        }

        let frame = probe.frame
        let screen = frame.map { Geometry.screen(containingAX: CGPoint(x: $0.midX, y: $0.midY)) }
            ?? Geometry.screenUnderMouse()
        guard let screen else { return }
        let space = Spaces.space(of: wid) ?? Spaces.current(on: screen)
        if Spaces.isFullscreen(space) || untiledIDs.contains(space) { return }
        let key = StripKey(space: space, display: Geometry.displayID(screen))
        let strip = self.strip(key)
        let vh = viewport(screen).height

        let height: CGFloat
        if let r = rule.height {
            height = Strip.height(forRatio: r, viewportHeight: vh, gap: settings.gap)
        } else if mode == .scan && settings.keepInitialHeights, let f = frame {
            height = min(max(f.height, 120), vh).rounded()
        } else {
            height = Strip.height(forRatio: settings.defaultHeight, viewportHeight: vh, gap: settings.gap)
        }

        windows[wid] = w
        let position: InsertPosition = mode == .scan ? .end : settings.newWindowPosition
        strip.insert(wid, height: height, anchor: strip.focused, position: position)
        Log.debug("add \(wid) \(w.appName) '\(w.title)' -> space \(space) rows=\(strip.rows.count)")

        if mode == .created || strip.focused == nil {
            strip.focused = wid
        }
        if mode == .created {
            strip.scrollY = strip.scrollToReveal(wid, viewportHeight: vh, gap: settings.gap)
            // Move the new window once, straight to where it will end up, instead of letting it
            // ride the scroll animation (it would first be parked off screen, then slide in).
            if visibleScreen(key) != nil, abs(strip.renderScrollY - strip.scrollY) > 1,
               let item = strip.layout(params(screen), scroll: strip.scrollY, minHeights: minHeights)
                .first(where: { $0.id == wid }), case .frame(let r) = item.placement {
                writer.move(wid, pid: pid, element: el, to: r, setSize: true)
                w.lastFrame = r
                w.needsSizeCheck = true
                pinned.insert(wid)
                // Start moving the neighbours only once the app has actually moved the new
                // window (Finder takes ~60 ms); otherwise they clear the space first and the
                // desktop shows through for a frame or two.
                writer.perform(pid: pid) { [weak self] in
                    DispatchQueue.main.async { self?.relayout(key, animated: true) }
                }
            } else {
                relayout(key, animated: true)
            }
            emit?("windowCreated", info(w))
        }
        if mode == .created { verifyPlacement(wid) }
        schedulePresetApply(key)
    }

    private func unmanage(_ id: CGWindowID, focusNeighbor: Bool) {
        pinned.remove(id)
        proxied.remove(id)
        proxyShownAt.removeValue(forKey: id)
        pendingParks.removeValue(forKey: id)?.cancel()
        overlays.remove(id)
        snapshots.remove(id)
        forgetFloating(id)
        userDragged.removeValue(forKey: id)
        lastResnap.removeValue(forKey: id)
        userResized.removeValue(forKey: id)
        sizeEnforcedAt.removeValue(forKey: id)
        minHeights.removeValue(forKey: id)
        guard let w = windows.removeValue(forKey: id) else { return }
        w.frameCheck?.cancel()
        guard let (key, strip) = locate(id) else { return }
        if maximized[key] == id { maximized[key] = nil }
        let wasFocused = strip.focused == id
        let neighbor = strip.remove(id)
        if let screen = visibleScreen(key) {
            let vh = viewport(screen).height
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
            if let n = strip.focused {
                strip.scrollY = strip.scrollToReveal(n, viewportHeight: vh, gap: settings.gap)
            }
            relayout(key, animated: true)
            if focusNeighbor && wasFocused, let n = neighbor {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.focus(n)
                }
            }
        }
        if strip.isEmpty { strips.removeValue(forKey: key) }
    }

    private func reassignSpaceIfNeeded(_ id: CGWindowID) {
        guard let (key, strip) = locate(id), let space = Spaces.space(of: id), space != key.space else { return }
        if untiledIDs.contains(space) {
            // Moved to a desktop that isn't tiled: let it go.
            unmanage(id, focusNeighbor: false)
            return
        }
        strip.remove(id)
        if strip.isEmpty { strips.removeValue(forKey: key) }
        let target = self.strip(StripKey(space: space, display: key.display))
        let h = Strip.height(forRatio: settings.defaultHeight,
                             viewportHeight: viewport(Geometry.screen(displayID: key.display) ?? NSScreen.main!).height,
                             gap: settings.gap)
        target.insert(id, height: h, anchor: target.focused, position: .end)
        windows[id]?.lastFrame = nil
    }

    // MARK: Events

    private func handle(notification: String, element: AXUIElement, pid: pid_t) {
        guard enabled else { return }
        switch notification {
        case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
            // Probed on the app's queue, so it already waits for the app to answer.
            addWindow(element, pid: pid, mode: .created)
        case kAXFocusedWindowChangedNotification:
            focusChanged(element)
        // Known by element: asking the app about a window that's gone waits out the AX timeout
        // (a 250 ms stall), and an unknown one isn't ours anyway.
        case kAXUIElementDestroyedNotification:
            if let w = find(element, pid: pid, askApp: false) { unmanage(w.id, focusNeighbor: true) }
        case kAXWindowMiniaturizedNotification:
            guard let w = find(element, pid: pid, askApp: false) else { return }
            if floating[w.id] != nil { rememberMinimized(w.id) }
            unmanage(w.id, focusNeighbor: true)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // While scrolling these are our own moves, dozens per second: skip the lookup.
            guard !isMoving, let w = find(element, pid: pid) else { return }
            // Held down and moved away from where it was pressed: the user is dragging (or
            // resizing). Held still, a window moving is Oz's (or its app's) doing, not a drag.
            let mouseDown = NSEvent.pressedMouseButtons & 1 != 0 && cursorMovedSinceMouseDown()
            // Moved with the pointer on it: dragged. macOS moving windows aside (a click on the
            // wallpaper to show the desktop, and back) while the button happened to be down
            // was taken for a drag, and a window from a region was dropped into the strip.
            let dragged = mouseDown && notification == kAXWindowMovedNotification && pointerOn(w.id)
            if floating[w.id] != nil {
                // Dragging a window taken out of the strip: it may be dropped back in.
                let ours = CACurrentMediaTime() - (dockPlacedAt[w.id] ?? 0) < 0.6
                if dragged && manualFloat.contains(w.id) && !ours {
                    pendingDrops.insert(w.id)
                    dragging = w.id
                    updateDropPreview()
                }
                return
            }
            guard windows[w.id] != nil else { return }
            // The app zooming the window: not the user resizing a tile.
            if zoomClick?.id == w.id { return }
            // Filling the screen: no dragging into the strip, but put back if moved away.
            if isMaximized(w.id) {
                scheduleFrameCheck(w)
                return
            }
            if notification == kAXWindowResizedNotification && mouseDown {
                // Resizing, not moving: no landing place to show.
                resizeDrag = w.id
                userResized[w.id] = CACurrentMediaTime()
                if dragging == w.id { dragging = nil; dropPreview.hide() }
                trackLiveResize(w)
            }
            if dragged {
                userDragged[w.id] = CACurrentMediaTime()
                if liveResize == nil && resizeDrag != w.id {
                    dragging = w.id
                    updateDropPreview()
                }
            }
            scheduleFrameCheck(w)
        case kAXApplicationHiddenNotification:
            for w in windows.values where w.pid == pid { unmanage(w.id, focusNeighbor: false) }
        case kAXApplicationShownNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.scanApp(pid, mode: .scan)
            }
        default:
            break
        }
    }

    private func find(_ el: AXUIElement, pid: pid_t, askApp: Bool = true) -> ManagedWindow? {
        // CFEqual is a local comparison; asking the app for the window id is a round trip.
        if let w = windows.values.first(where: { $0.pid == pid && CFEqual($0.element, el) })
            ?? floating.values.first(where: { $0.pid == pid && CFEqual($0.element, el) }) {
            return w
        }
        if askApp, let wid = AX.windowID(el) { return windows[wid] ?? floating[wid] }
        return nil
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard enabled, Self.hasWindows(app) else { return }
        let pid = app.processIdentifier
        ensureObserver(pid)
        // The first window often exists before our observer is registered.
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scanApp(pid, mode: .created)
            }
        }
    }

    private func appTerminated(_ pid: pid_t) {
        observers.removeValue(forKey: pid)
        writer.forget(pid: pid)
        for w in windows.values where w.pid == pid { unmanage(w.id, focusNeighbor: false) }
        for w in floating.values where w.pid == pid { forgetFloating(w.id) }
    }

    private func appActivated(_ pid: pid_t) {
        guard enabled else { return }
        // A window picked in the overview: it is closing.
        if overviewActive { overviewClosing() }
        // Steam shows its window (made hidden at launch, by its helper) without a "window
        // created": look for it when Steam comes forward.
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.valvesoftware.steam" {
            for helper in NSRunningApplication.runningApplications(withBundleIdentifier: Self.steamHelper) {
                scanApp(helper.processIdentifier, mode: .created)
            }
        }
        writer.perform(pid: pid) { [weak self] in
            guard let el = AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return }
            DispatchQueue.main.async { self?.focusChanged(el) }
        }
    }

    private func focusChanged(_ el: AXUIElement) {
        // No round trip to the app here (a busy app stalled this for 200 ms): a window we
        // don't recognise by element is one we don't manage yet anyway.
        guard enabled, let pid = AX.pid(el), pid != getpid() else { return }
        guard let w = find(el, pid: pid, askApp: false) else {
            restoreMaximized(focusing: el, pid: pid)
            return
        }
        restoreMaximized(focusing: w)
        trackedFocus = w.id
        guard gesture == nil, windows[w.id] != nil, let (key, strip) = locate(w.id) else { return }
        let wid = w.id
        strip.focused = wid
        if NSEvent.pressedMouseButtons & 1 != 0 {
            // Clicked: scroll to it once the button is let go (unless it turns into a drag).
            revealOnMouseUp = wid
        } else {
            reveal(wid)
        }
        emit?("windowFocused", info(w))
    }

    private func mouseWentDown(doubleClick: Bool) {
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Geometry.primaryHeight - m.y)
        mouseDownAt = p
        revealOnMouseUp = nil
        // Pressing on a gliding strip stops it where it is (like touching a scrolling list),
        // so the window under the cursor doesn't move while it's held.
        stopGlide(at: p)
        if doubleClick { titleBarDoubleClick(at: p) } else { clickedFloating = floatingWindow(at: p) }
    }

    private func mouseWentUp() {
        let m = NSEvent.mouseLocation
        lastMouseUp = (CGPoint(x: m.x, y: Geometry.primaryHeight - m.y), CACurrentMediaTime())
        mouseDownAt = nil
        // A click (no drag) on a window that's partly out of view: show it now.
        if let id = revealOnMouseUp {
            revealOnMouseUp = nil
            if dragging == nil { reveal(id) }
        }
        endDragScroll()
        // A tiled window let go inside the zone: place it now rather than after the usual
        // settle delay, so it slides into the slot the line showed.
        if let id = dragging, let w = windows[id] {
            dropped = (id, CACurrentMediaTime())
            checkFrame(w)
        }
        dragging = nil
        resizeDrag = nil
        dropPreview.hide()
        insertionLine.hide()
        endLiveResize()
        resolveDrops()
    }

    /// Scrolls the window's strip so the window is fully in view (if it isn't).
    private func reveal(_ id: CGWindowID) {
        guard windows[id] != nil, let (key, strip) = locate(id), let screen = visibleScreen(key) else { return }
        let vh = viewport(screen).height
        let target = strip.scrollToReveal(id, viewportHeight: vh, gap: settings.gap)
        if abs(target - strip.scrollY) > 0.5 {
            strip.scrollY = target
            relayout(key, animated: true)
        }
    }

    /// The mouse pointer is on the window (as the window server has it now, with a few
    /// points to spare for its edge).
    private func pointerOn(_ id: CGWindowID) -> Bool {
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let array = CFArrayCreate(nil, &value, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] else { return false }
        var r = CGRect.zero
        CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
        let m = NSEvent.mouseLocation
        return r.insetBy(dx: -8, dy: -8).contains(CGPoint(x: m.x, y: Geometry.primaryHeight - m.y))
    }

    private func cursorMovedSinceMouseDown() -> Bool {
        // Pressed where Oz didn't see it: don't take window moves for a drag.
        guard let d = mouseDownAt else { return false }
        let m = NSEvent.mouseLocation
        return hypot(m.x - d.x, Geometry.primaryHeight - m.y - d.y) > 4
    }

    /// The left button went down at `p`: a strip gliding there (a swipe's momentum, a scroll
    /// animation) stops where it is. Rearrangements (windows sliding to new places) finish.
    private func stopGlide(at p: CGPoint) {
        guard let screen = Geometry.screen(containingAX: p), scrollArea(screen).contains(p) else { return }
        let key = visibleKey(for: screen)
        guard animations[key] != nil, transitions[key] == nil, gesture?.key != key,
              let strip = strips[key] else { return }
        strip.scrollY = strip.renderScrollY
        stopAnimation(key)
        if gesture == nil { releaseProxies(key) }
        settle(strip, screen: screen)
    }

    private func spaceChanged() {
        guard enabled else { return }
        // Animations target the old Space's windows; finish them instantly.
        for (_, a) in animations { a.strip.renderScrollY = a.to }
        animations.removeAll()
        transitions.removeAll()
        pendingFrom.removeAll()
        dirty.removeAll()
        // Keep the peeks on screen (they live on their own Space); just stop streaming.
        overlays.pauseMirrors()
        hideScrollIndicators()
        gesture = nil
        scanAll(initial: false)
        onEnabledChanged?(enabled)
        emit?("spaceChanged", [:])
    }

    private func screensChanged() {
        guard enabled else { return }
        refreshUntiledIDs()
        let live = Set(NSScreen.screens.map(Geometry.displayID))
        for (key, strip) in strips where !live.contains(key.display) {
            guard let main = NSScreen.main ?? NSScreen.screens.first else { break }
            let target = self.strip(StripKey(space: Spaces.current(on: main), display: Geometry.displayID(main)))
            for row in strip.rows { target.rows.append(row) }
            strips.removeValue(forKey: key)
        }
        for w in windows.values { w.lastFrame = nil; w.parked = false }
        layoutVisible(animated: false)
        for key in visibleKeys().keys { redock(key) }
    }

    private func scheduleFrameCheck(_ w: ManagedWindow) {
        w.frameCheck?.cancel()
        let item = DispatchWorkItem { [weak self, weak w] in
            guard let self, let w else { return }
            self.checkFrame(w)
        }
        w.frameCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Reacts to the user resizing or dragging a tiled window.
    private func checkFrame(_ w: ManagedWindow) {
        guard enabled, windows[w.id] === w, !w.parked else { return }
        if isMoving || liveResize != nil || NSEvent.pressedMouseButtons != 0 || writer.hasPending(pid: w.pid) {
            scheduleFrameCheck(w)
            return
        }
        let element = w.element
        writer.perform(pid: w.pid) { [weak self, weak w] in
            let actual = AX.frame(element)
            DispatchQueue.main.async {
                guard let self, let w, let actual else { return }
                self.compareFrame(w, actual)
            }
        }
    }

    private func compareFrame(_ w: ManagedWindow, _ actual: CGRect) {
        guard enabled, !isMoving, !overviewActive, windows[w.id] === w, !w.parked, let expected = w.lastFrame,
              zoomClick?.id != w.id else { return }
        if isMaximized(w.id) {
            // Filling the screen: if it was dragged or resized away, it goes back.
            if !actual.approxEqual(expected, tolerance: 3), let (key, _) = locate(w.id) {
                w.lastFrame = nil
                relayout(key, animated: true)
            }
            return
        }
        // Moved by the mouse (the check runs once the button is released), not by its app.
        // Taken only here, past the guard: a check put off until later must still see it.
        let now = CACurrentMediaTime()
        var dragged = userDragged.removeValue(forKey: w.id).map { now - $0 < 3 } ?? false
        if let d = dropped, d.id == w.id {
            dropped = nil
            dragged = dragged || now - d.at < 5
        }
        let moved = abs(actual.minX - expected.minX) > 3 || abs(actual.minY - expected.minY) > 3
        let resizedH = abs(actual.height - expected.height) > 3
        let resizedW = abs(actual.width - expected.width) > 3
        // Moved by its title bar (same size): dragging an edge moves the origin too, and must
        // not take the window out of the strip when the cursor ends up outside the zone.
        if moved && dragged && !resizedH && !resizedW && isOutsideScrollArea(dropPoint(actual)) {
            floatOut(w, at: actual)
            return
        }
        // Dropped elsewhere in its own zone: it moves to the slot the split line showed.
        if moved && dragged && !resizedH && !resizedW, let zs = zoneSlot(at: dropPoint(actual), dragging: w.id),
           let (key, strip) = locate(w.id) {
            if zs.key != key {
                // Another display's zone: it leaves this strip, keeping its row height.
                let h = strip.locate(w.id).map { strip.rows[$0.row].height } ?? actual.height
                beginTransition(key)
                strip.remove(w.id)
                if strip.isEmpty {
                    strips.removeValue(forKey: key)
                    pendingFrom.removeValue(forKey: key)
                } else {
                    relayout(key, animated: true)
                }
                insert(w, into: zs.key, slot: zs.slot, from: actual, height: h)
            } else {
                insert(w, into: zs.key, slot: zs.slot, from: actual)
            }
            return
        }
        guard let (key, strip) = locate(w.id), let (r, _) = strip.locate(w.id),
              let screen = Geometry.screen(displayID: key.display) else { return }
        let vh = viewport(screen).height
        // A narrowed window alone in its row, dropped in that same row: it stays in the row but
        // keeps the sideways place it was dropped at.
        if moved && dragged && !resizedH && !resizedW, strip.rows[r].windows.count == 1,
           strip.widthWeights[w.id] != nil, dropTarget(dropPoint(actual))?.0 == key {
            let (x0, rowWidth) = Strip.rowExtent(params(screen))
            beginTransition(key)
            strip.setLoneOffset(w.id, (actual.minX - x0) / rowWidth)
            if settings.animationDuration > 0 { pendingFrom[key, default: [:]][w.id] = actual }
            w.lastFrame = actual
            relayout(key, animated: true)
            return
        }
        // (Narrowing from the left edge moves the window sideways too: only its top must stay.)
        if moved || resizedW || resizedH { recordUndo(key) }
        let byUser = userResized.removeValue(forKey: w.id).map { now - $0 < 3 } ?? false
        if resizedW && !byUser {
            // The app changed the width itself (a window opening, an app's own resize): not
            // the user narrowing it. Put it back in its place at its size. An app that insists
            // on its width (asked again within 5 s) keeps it, but still goes back to its place
            // in the strip below, rather than being fought over every time.
            if now - (sizeEnforcedAt[w.id] ?? 0) > 5 {
                sizeEnforcedAt[w.id] = now
                Log.debug("window \(w.id) \(w.appName) moved/resized by its app; putting it back")
                w.lastFrame = nil
                relayout(key, animated: false)
                return
            }
        } else if resizedW && !resizedH && abs(actual.minY - expected.minY) <= 3 {
            // Width changed without the live path (a quick drag): same rules as live resizing.
            let rowWidth = viewport(screen).width * settings.width
            if strip.rows[r].windows.count > 1 {
                strip.setWidthFraction(w.id, actual.width / (rowWidth - settings.gap * CGFloat(strip.rows[r].windows.count - 1)))
            } else {
                setLoneFrame(w.id, actual, strip: strip, screen: screen)
            }
            w.lastFrame = nil
            relayout(key, animated: true)
            return
        }
        guard moved || resizedH else {
            w.lastFrame = actual
            return
        }

        if resizedH && !w.shrunk {
            strip.rows[r].height = min(max(actual.height, 60), vh).rounded()
            Log.debug("adopt height \(actual.height) for \(w.id)")
        } else if moved {
            let c = CGPoint(x: actual.midX, y: actual.midY)
            if let target = Geometry.screen(containingAX: c), Geometry.displayID(target) != key.display {
                strip.remove(w.id)
                if strip.isEmpty { strips.removeValue(forKey: key) }
                let tkey = StripKey(space: Spaces.current(on: target), display: Geometry.displayID(target))
                let ts = self.strip(tkey)
                ts.insert(w.id, height: min(strip.rows.indices.contains(r) ? strip.rows[r].height : actual.height,
                                            viewport(target).height),
                          anchor: ts.focused, position: .below)
                ts.focused = w.id
                w.lastFrame = nil
                ts.scrollY = ts.scrollToReveal(w.id, viewportHeight: viewport(target).height, gap: settings.gap)
                relayout(tkey, animated: true)
            }
        }
        w.lastFrame = nil
        relayout(key, animated: false)
    }

    // MARK: Dragging in and out of the scroll area

    private func rememberMinimized(_ id: CGWindowID) {
        var dock: (key: StripKey, region: Int, index: Int)?
        for (key, regions) in docks {
            for (i, ids) in regions {
                if let j = ids.firstIndex(of: id) { dock = (key, i, j) }
            }
        }
        minimizedFloating[id] = (manualFloat.contains(id), dock)
    }

    private func forgetFloating(_ id: CGWindowID) {
        undock(id)
        dockPlacedAt.removeValue(forKey: id)
        floating.removeValue(forKey: id)
        manualFloat.remove(id)
        pendingDrops.remove(id)
    }

    /// Dropped where a custom scroll area leaves the screen free (a whole-screen area has no outside).
    /// Where a drag that left the window at `frame` ended: the cursor when the button was let
    /// go (if that was just now), else the window's middle.
    private func dropPoint(_ frame: CGRect) -> CGPoint {
        if let up = lastMouseUp, CACurrentMediaTime() - up.at < 3 { return up.point }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func isOutsideScrollArea(_ c: CGPoint) -> Bool {
        guard let screen = Geometry.screen(containingAX: c), scrollAreaFraction(screen) != nil,
              isTiled(screen: screen) else { return false }
        return !scrollArea(screen).contains(c)
    }

    /// The scroll area (and its strip) a window dropped at `c` lands in, if any.
    private func dropTarget(_ c: CGPoint) -> (StripKey, NSScreen)? {
        guard let screen = Geometry.screen(containingAX: c), scrollArea(screen).contains(c) else { return nil }
        let key = visibleKey(for: screen)
        return untiledIDs.contains(key.space) ? nil : (key, screen)
    }

    /// A tiled window was dragged out of the scroll area: it stays where it was dropped,
    /// floating, untouched by scrolling, and the strip closes the gap.
    private func floatOut(_ w: ManagedWindow, at frame: CGRect) {
        guard let (key, strip) = locate(w.id) else { return }
        beginTransition(key)
        strip.remove(w.id)
        windows.removeValue(forKey: w.id)
        floating[w.id] = w
        manualFloat.insert(w.id)
        pinned.remove(w.id)
        proxied.remove(w.id)
        pendingParks.removeValue(forKey: w.id)?.cancel()
        overlays.remove(w.id)
        minHeights.removeValue(forKey: w.id)
        w.lastFrame = frame
        w.parked = false
        w.shrunk = false
        Log.debug("dragged out of the scroll area: \(w.id) \(w.appName)")
        if strip.isEmpty {
            strips.removeValue(forKey: key)
            pendingFrom.removeValue(forKey: key)
        } else if let screen = visibleScreen(key) {
            let vh = viewport(screen).height
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: vh, gap: settings.gap)
            relayout(key, animated: true)
        }
        emit?("windowFloated", info(w))
        dock(w, at: dropPoint(frame))
    }

    /// The mouse was let go: place the floating windows that were being dragged.
    private func resolveDrops() {
        guard !pendingDrops.isEmpty else { return }
        let ids = pendingDrops
        pendingDrops.removeAll()
        for id in ids {
            guard let w = floating[id] else { continue }
            let element = w.element
            writer.perform(pid: w.pid) { [weak self] in
                let frame = AX.frame(element)
                DispatchQueue.main.async { self?.drop(id, at: frame) }
            }
        }
    }

    /// A floating window was let go. Inside a scroll area it joins the strip at the row
    /// nearest to where it was dropped, sliding in from there; outside, in one of the regions
    /// around the zone, it is tiled in that region; anywhere else it stays put.
    private func drop(_ id: CGWindowID, at frame: CGRect?) {
        guard enabled, let frame, let w = floating[id], manualFloat.contains(id) else { return }
        // Where the user left it, not where Oz last put it: a window dropped back into its own
        // region still has to be fitted there again.
        w.lastFrame = frame
        let point = dropPoint(frame)
        guard let (key, screen) = dropTarget(point) else {
            if !dock(w, at: point) { undock(id) }
            return
        }
        undock(id)
        floating.removeValue(forKey: id)
        manualFloat.remove(id)
        windows[id] = w
        let slot = zoneSlot(at: point, dragging: id)?.slot ?? .row(before: nil)
        Log.debug("dropped into the scroll area: \(id) \(w.appName) \(slot)")
        insert(w, into: key, slot: slot, from: frame, height: min(max(frame.height, 120), viewport(screen).height).rounded())
        emit?("windowCreated", info(w))
    }

    /// The slot a window dragged to `p` (in a zone) would take, and the split line showing it:
    /// beside a window when the cursor is near its left or right edge, otherwise between the
    /// rows above or below the cursor. nil outside a zone, or when it would land where it is.
    private func zoneSlot(at p: CGPoint, dragging id: CGWindowID) -> (key: StripKey, slot: DropSlot, line: CGRect)? {
        guard let (key, screen) = dropTarget(p) else { return nil }
        let strip = strips[key] ?? Strip()
        guard let r = strip.dropSlot(at: p, dragging: id, params: params(screen), minHeights: minHeights,
                                     lineThickness: InsertionLine.thickness) else { return nil }
        return (key, r.slot, r.line)
    }

    /// Puts a window (tiled, or just made tiled) into `slot` of the strip and slides it there
    /// from `frame`, where it was let go.
    private func insert(_ w: ManagedWindow, into key: StripKey, slot: DropSlot, from frame: CGRect, height: CGFloat? = nil) {
        let strip = self.strip(key)
        beginTransition(key)
        var h = height ?? frame.height
        if let (r, _) = strip.locate(w.id) {
            if height == nil { h = strip.rows[r].height }
            strip.remove(w.id)
        }
        switch slot {
        case .row(let anchor):
            strip.insertRow(w.id, height: h, before: anchor)
        case .beside(let anchor, let right):
            if !strip.insertBeside(w.id, anchor: anchor, right: right) { strip.insertRow(w.id, height: h, before: nil) }
        }
        strip.focused = w.id
        if settings.animationDuration > 0 { pendingFrom[key, default: [:]][w.id] = frame }
        w.lastFrame = frame
        w.parked = false
        if let screen = visibleScreen(key) {
            let vh = viewport(screen).height
            strip.scrollY = strip.clampScroll(strip.scrollToReveal(w.id, viewportHeight: vh, gap: settings.gap),
                                              viewportHeight: vh, gap: settings.gap)
        }
        relayout(key, animated: true)
    }

    // MARK: Regions outside the zone

    /// The regions around the Oz zone on `screen`'s current desktop (none without a zone).
    private func outsideRegions(_ screen: NSScreen) -> [CGRect] {
        guard scrollAreaFraction(screen) != nil else { return [] }
        return OutsideRegions.compute(outer: Geometry.ax(screen.usableFrame), zone: scrollArea(screen))
    }

    /// Tiles a floating window in the region outside the zone that holds `point`: alone it
    /// fills the region; with others the region is shared equally along its long side, the
    /// new window going where the cursor is. False if no region is there.
    @discardableResult
    private func dock(_ w: ManagedWindow, at point: CGPoint) -> Bool {
        guard let plan = dockPlan(at: point, excluding: w.id) else { return false }
        undock(w.id, layout: false)
        var list = plan.others
        list.insert(w.id, at: plan.index)
        let key = plan.key, i = plan.region
        docks[key, default: [:]][i] = list
        floating[w.id] = w
        manualFloat.insert(w.id)
        Log.debug("docked \(w.id) \(w.appName) in region \(i) (\(list.count) there)")
        layoutDocks(key)
        checkDocked(w, key: key)
        return true
    }

    /// A moment after docking, the window may not be where Oz put it: macOS's own tiling
    /// (a window let go near a screen edge goes to that half) lands after Oz's move and
    /// left it over the strip. Read where it is and put it back if need be.
    private func checkDocked(_ w: ManagedWindow, key: StripKey) {
        let id = w.id, element = w.element
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.floating[id] != nil else { return }
            self.writer.perform(pid: w.pid) {
                let actual = AX.frame(element)
                DispatchQueue.main.async {
                    guard let actual, let w = self.floating[id], let placed = w.lastFrame,
                          !actual.approxEqual(placed, tolerance: 2) else { return }
                    Log.debug("docked \(id) moved to \(actual) by something else; back to \(placed)")
                    w.lastFrame = actual
                    self.layoutDocks(key)
                }
            }
        }
    }

    /// Where a window let go at `point` would be docked: the region under it, the windows
    /// already there (without this one), its place among them and the frame it would get.
    private func dockPlan(at point: CGPoint, excluding id: CGWindowID) -> (key: StripKey, region: Int, others: [CGWindowID], index: Int, frame: CGRect)? {
        guard enabled, let screen = Geometry.screen(containingAX: point), isTiled(screen: screen) else { return nil }
        let regions = outsideRegions(screen)
        guard let i = regions.firstIndex(where: { $0.contains(point) }) else { return nil }
        let key = visibleKey(for: screen)
        let others = (docks[key]?[i] ?? []).filter { $0 != id && floating[$0] != nil }
        let r = regions[i]
        let vertical = r.height >= r.width
        var index = others.count
        for (j, f) in OutsideRegions.frames(in: r, count: others.count, gap: settings.outerGap).enumerated()
        where vertical ? point.y < f.midY : point.x < f.midX {
            index = j
            break
        }
        let frame = OutsideRegions.frames(in: r, count: others.count + 1, gap: settings.outerGap)[index]
        return (key, i, others, index, frame)
    }

    /// Shows where the dragged window would land if let go now: its slot in a region outside
    /// the zone, or the zone itself for a floating window that would join the strip. Nothing
    /// for a tiled window still inside the zone (it just goes back to its place).
    private func updateDropPreview(force: Bool = false) {
        guard let id = dragging, NSEvent.pressedMouseButtons & 1 != 0 else {
            dropPreview.hide()
            insertionLine.hide()
            endDragScroll()
            return
        }
        let now = CACurrentMediaTime()
        guard force || now - lastPreviewUpdate > 1.0 / 60 else { return }
        lastPreviewUpdate = now
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Geometry.primaryHeight - m.y)
        var target: CGRect?
        var line: CGRect?
        if windows[id] != nil || (floating[id] != nil && manualFloat.contains(id)) {
            if dropTarget(p) != nil {
                // In the zone: the split line it would go in (none if it would stay put).
                line = zoneSlot(at: p, dragging: id)?.line
            } else if windows[id] == nil || isOutsideScrollArea(p) {
                target = dockPlan(at: p, excluding: id)?.frame
            }
        }
        if let target { dropPreview.show(target, below: id) } else { dropPreview.hide() }
        if let line { insertionLine.show(line) } else { insertionLine.hide() }
        updateDragScroll(at: p)
    }

    // MARK: Scrolling under a drag

    /// How fast a drag at `p` wants its zone's strip to scroll. Only the bands along the
    /// zone's top and bottom edges scroll (15% of its height, at least 60 pt), faster the
    /// deeper the cursor is in them, up to 1.5 screens a second at the edge. nil outside a
    /// zone; `inBand` false in its middle; velocity 0 where it can't scroll further.
    private func dragScrollVelocity(at p: CGPoint) -> (key: StripKey, velocity: CGFloat, inBand: Bool)? {
        guard let (key, screen) = dropTarget(p), let strip = strips[key] else { return nil }
        let vh = viewport(screen).height
        let v = DragScroll.velocity(cursorY: p.y, zone: scrollArea(screen), viewportHeight: vh, scroll: strip.renderScrollY,
                                    maxScroll: strip.maxScroll(viewportHeight: vh, gap: settings.gap))
        return (key, v.velocity, v.inBand)
    }

    /// Starts scrolling once the cursor has rested in an edge band for a moment, and only if
    /// this drag has been in the middle of the zone first; ends it when the drag leaves the zone.
    private func updateDragScroll(at p: CGPoint) {
        guard let ds = dragScrollVelocity(at: p) else {
            endDragScroll(keepArmed: true)
            return
        }
        if !ds.inBand {
            dragScrollArmed = true
            stopDwell()
            return
        }
        guard dragScrollArmed, autoScroll == nil, ds.velocity != 0 else { return }
        let now = CACurrentMediaTime()
        guard let since = bandSince else {
            bandSince = now
            // The cursor may rest without sending events: look again shortly.
            dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateDropPreview(force: true)
            }
            return
        }
        if now - since >= Self.bandDwell {
            stopDwell()
            startAutoScroll(ds.key)
        }
    }

    private func stopDwell() {
        bandSince = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    /// The drag ended or left the zone: stop scrolling (the real windows come back).
    private func endDragScroll(keepArmed: Bool = false) {
        stopDwell()
        stopAutoScroll()
        if !keepArmed { dragScrollArmed = false }
    }

    private func startAutoScroll(_ key: StripKey) {
        guard let strip = strips[key], visibleScreen(key) != nil else { return }
        stopAnimation(key)
        strip.scrollY = strip.renderScrollY
        autoScroll = (key, 0, CACurrentMediaTime())
        overlays.wake()
        prepareProxies(strip)
        driver.start()
        Log.debug("scrolling under a drag")
    }

    private func stopAutoScroll() {
        guard let a = autoScroll else { return }
        autoScroll = nil
        releaseProxies(a.key)
        if let strip = strips[a.key], let screen = visibleScreen(a.key) {
            strip.scrollY = strip.renderScrollY
            settle(strip, screen: screen)
        }
    }

    /// One display frame of scrolling under a drag. The speed is re-read from where the cursor
    /// is now (it may rest without sending events) and eased towards, so starting, stopping
    /// and changing pace are smooth. Off the zone (or the drag over) the session ends.
    private func stepAutoScroll(_ now: CFTimeInterval) {
        guard var a = autoScroll, let strip = strips[a.key], let screen = visibleScreen(a.key) else {
            autoScroll = nil
            return
        }
        let m = NSEvent.mouseLocation
        let want = dragging != nil && NSEvent.pressedMouseButtons & 1 != 0
            ? dragScrollVelocity(at: CGPoint(x: m.x, y: Geometry.primaryHeight - m.y)) : nil
        guard let want, want.key == a.key else {
            endDragScroll(keepArmed: true)
            return
        }
        let dt = CGFloat(min(now - a.last, 0.05))
        a.velocity += (want.velocity - a.velocity) * min(1, dt * 8)
        if want.velocity == 0 && abs(a.velocity) < 5 { a.velocity = 0 }
        a.last = now
        autoScroll = a
        guard a.velocity != 0 else { return }
        let vh = viewport(screen).height
        let next = strip.clampScroll(strip.renderScrollY + a.velocity * dt, viewportHeight: vh, gap: settings.gap)
        strip.scrollY = next
        strip.renderScrollY = next
        dirty.insert(a.key)
    }

    /// Takes a window out of its region; the rest of that region closes the gap.
    private func undock(_ id: CGWindowID, layout: Bool = true) {
        for (key, regions) in docks {
            for (i, ids) in regions where ids.contains(id) {
                let rest = ids.filter { $0 != id }
                docks[key]?[i] = rest.isEmpty ? nil : rest
                if docks[key]?.isEmpty == true { docks[key] = nil }
                if layout { layoutDocks(key) }
                return
            }
        }
    }

    /// Moves the docked windows of a desktop to their region frames.
    private func layoutDocks(_ key: StripKey) {
        guard let screen = visibleScreen(key), let byRegion = docks[key] else { return }
        let regions = outsideRegions(screen)
        let now = CACurrentMediaTime()
        for (i, ids) in byRegion where regions.indices.contains(i) {
            let live = ids.filter { floating[$0] != nil }
            for (id, f) in zip(live, OutsideRegions.frames(in: regions[i], count: live.count, gap: settings.outerGap)) {
                guard let w = floating[id] else { continue }
                if let lf = w.lastFrame, lf.approxEqual(f) { continue }
                dockPlacedAt[id] = now
                writer.move(id, pid: w.pid, element: w.element, to: f, setSize: true)
                w.lastFrame = f
            }
        }
    }

    /// The zone changed shape, so the regions did: put each docked window in the region now
    /// holding its middle (or the nearest one), in its old order; with no regions left they
    /// simply stay where they are.
    private func redock(_ key: StripKey) {
        guard let byRegion = docks.removeValue(forKey: key), let screen = visibleScreen(key) else { return }
        let regions = outsideRegions(screen)
        guard !regions.isEmpty else { return }
        var next: [Int: [CGWindowID]] = [:]
        for i in byRegion.keys.sorted() {
            for id in byRegion[i] ?? [] {
                guard let w = floating[id], let f = w.lastFrame else { continue }
                let c = CGPoint(x: f.midX, y: f.midY)
                let target = regions.firstIndex { $0.contains(c) } ?? regions.indices.min { a, b in
                    hypot(regions[a].midX - c.x, regions[a].midY - c.y) < hypot(regions[b].midX - c.x, regions[b].midY - c.y)
                }!
                next[target, default: []].append(id)
            }
        }
        docks[key] = next
        layoutDocks(key)
    }

    // MARK: Live resize

    /// The user is dragging an edge of `w`: read its frame (on the app's queue, so it comes
    /// after our own moves) and reflow everything else around it, at most once per read.
    private func trackLiveResize(_ w: ManagedWindow) {
        if let lr = liveResize, lr.id != w.id { return }
        guard !w.parked, !overlays.isShowing(w.id) else {
            Log.debug("live resize \(w.id) skipped: parked=\(w.parked) overlay=\(overlays.isShowing(w.id))")
            return
        }
        if liveReadInFlight {
            liveReadAgain = true
            return
        }
        liveReadInFlight = true
        let id = w.id
        let element = w.element
        writer.perform(pid: w.pid) { [weak self] in
            let frame = AX.frame(element)
            DispatchQueue.main.async { self?.liveResizeRead(id, frame) }
        }
    }

    private func liveResizeRead(_ id: CGWindowID, _ frame: CGRect?) {
        liveReadInFlight = false
        defer {
            if liveReadAgain, let w = windows[id] {
                liveReadAgain = false
                trackLiveResize(w)
            }
        }
        guard let f = frame, let w = windows[id], let (key, strip) = locate(id), let (r, _) = strip.locate(id),
              let screen = visibleScreen(key) else { return }
        if liveResize == nil {
            // A frame equal to what we set is just one of our own moves landing.
            guard let expected = w.lastFrame, !f.approxEqual(expected, tolerance: 2),
                  NSEvent.pressedMouseButtons & 1 != 0 else { return }
            liveResize = (id, key)
            recordUndo(key)
            Log.debug("live resize \(id) \(w.appName)")
        }
        let vp = viewport(screen)
        let row = strip.rows[r]
        row.height = min(max(f.height, 60), vp.height).rounded()
        w.savedHeight = nil
        let rowWidth = vp.width * settings.width
        if row.windows.count > 1 {
            let available = rowWidth - settings.gap * CGFloat(row.windows.count - 1)
            strip.setWidthFraction(id, f.width / available)
        } else {
            // Alone in its row: it may be narrowed, leaving room beside it, and it stays where
            // it's dragged to (narrowed from the left, it keeps its right edge).
            setLoneFrame(id, f, strip: strip, screen: screen)
        }
        // Keep the dragged window exactly where it is; the rest of the strip moves around it.
        strip.scrollY = strip.rowTop(r, gap: settings.gap) - (f.minY - vp.minY)
        strip.renderScrollY = strip.scrollY
        w.lastFrame = f
        markDirty(key)
    }

    /// Mouse released: settle into the exact layout (snaps width back for a lone window).
    /// A window alone in its row was resized to `frame`: its share of the row and its place
    /// in it both follow, so it stays exactly where the user left it.
    private func setLoneFrame(_ id: CGWindowID, _ frame: CGRect, strip: Strip, screen: NSScreen) {
        let (x0, rowWidth) = Strip.rowExtent(params(screen))
        strip.setLoneWidth(id, frame.width / rowWidth)
        if strip.widthWeights[id] != nil { strip.setLoneOffset(id, (frame.minX - x0) / rowWidth) }
    }

    private func endLiveResize() {
        guard let lr = liveResize else { return }
        liveResize = nil
        liveReadAgain = false
        windows[lr.id]?.lastFrame = nil
        if let strip = strips[lr.key], let screen = visibleScreen(lr.key) {
            strip.scrollY = strip.clampScroll(strip.scrollY, viewportHeight: viewport(screen).height, gap: settings.gap)
        }
        relayout(lr.key, animated: true)
    }

    // MARK: Gestures

    func handleGesture(_ e: GestureEvent) {
        if enabled, overviewActive, case .swipeBegan = e {
            if SystemActions.isOverviewShowing {
                // A swipe in Mission Control closes it, as macOS's own swipe would (the
                // three-finger swipe is Oz's, so macOS doesn't any more): it did nothing before.
                Log.info("swipe closes Mission Control")
                openOverview(SystemActions.missionControl)
                return
            }
            // Already gone (its window lingers a moment after it closes): carry on scrolling.
            closeOverview()
        }
        guard enabled, !overviewActive else {
            if case .swipeBegan = e { Log.info("swipe ignored: \(enabled ? "overview still open" : "Oz off")") }
            return
        }
        switch e {
        case .swipeBegan:
            guard settings.swipe.enabled, let screen = Geometry.screenUnderMouse() else { return }
            let key = visibleKey(for: screen)
            // A window fills the screen: there is nothing to scroll into view.
            guard let strip = strips[key], !strip.isEmpty else {
                Log.info("swipe ignored: no tiled windows on this desktop")
                return
            }
            guard maximizedID(key) == nil else {
                Log.info("swipe ignored: a window is maximized")
                return
            }
            guard !appFilledScreen(screen) else { return }
            stopAnimation(key)
            pendingActivation[key] = nil
            pinned.subtract(strip.windowIDs)
            strip.scrollY = strip.renderScrollY
            let vh = viewport(screen).height
            var range = 0...strip.maxScroll(viewportHeight: vh, gap: settings.gap)
            if settings.swipe.snap == .always {
                let s = strip.scrollY
                range = min(nextWindow(strip, from: s, -1, vh: vh), s)...max(nextWindow(strip, from: s, 1, vh: vh), s)
            }
            gesture = GestureState(key: key, strip: strip, screen: screen, startScroll: strip.scrollY, range: range,
                                   free: strip.scrollY)
            overlays.wake()
            prepareProxies(strip)
            Log.debug("swipe began")

        case .swipeChanged(let dy):
            guard let g = gesture else { return }
            gesture?.padTravel += dy
            let vh = viewport(g.screen).height
            let delta = CGFloat(dy * settings.swipe.sensitivity) * vh * (settings.swipe.natural ? 1 : -1)
            let free = g.free + delta
            gesture?.free = free
            // Stops: the next window for magnetic scrolling, hard; at the strip's ends there is
            // nothing further, so it gives a little against the push (less the further you
            // push, at most 8% of the screen) and springs back when you let go.
            let maxS = g.strip.maxScroll(viewportHeight: vh, gap: settings.gap)
            let give = vh * 0.08
            func resisted(_ over: CGFloat) -> CGFloat { give * over / (over + give) }
            var s = min(max(free, g.range.lowerBound), g.range.upperBound)
            if free < 0 && g.range.lowerBound <= 0.5 {
                s = -resisted(-free)
            } else if free > maxS && g.range.upperBound >= maxS - 0.5 {
                s = maxS + resisted(free - maxS)
            }
            g.strip.scrollY = s
            g.strip.renderScrollY = s
            markDirty(g.key)

        case .swipeEnded(let v):
            guard let g = gesture else { return }
            gesture = nil
            FrameStats.report("swipe")
            let vh = viewport(g.screen).height
            let velocity = CGFloat(v * settings.swipe.sensitivity) * vh * (settings.swipe.natural ? 1 : -1)
            let s = g.strip.scrollY
            let target: CGFloat
            switch settings.swipe.snap {
            case .always:
                // A very strong swipe (much of the trackpad's height, fast) moves three windows.
                // Fingers slow down before they lift, so the speed over the whole swipe counts
                // as well as the speed at the release.
                let average = abs(g.padTravel) / max(CACurrentMediaTime() - g.startTime, 0.05)
                let strong = abs(g.padTravel) >= Self.strongSwipeTravel && max(abs(v), average) >= Self.strongSwipeSpeed
                target = g.strip.snapTarget(from: s, velocity: velocity, start: g.startScroll, viewportHeight: vh,
                                            gap: settings.gap, steps: strong ? 3 : 1)
            case .near, .off:
                target = g.strip.restingScroll(from: s, velocity: velocity, viewportHeight: vh, gap: settings.gap,
                                               snapDistance: settings.swipe.snap == .near ? settings.swipe.snapDistance : 0,
                                               momentum: CGFloat(settings.swipe.momentum))
            }
            g.strip.scrollY = target
            // Ease-out starts at 3x its average speed: pick the duration that matches the
            // finger's release speed, so the glide continues the swipe without a jolt.
            let distance = abs(target - s)
            var duration = max(0.15, settings.animationDuration * 1.2)
            if abs(velocity) > 50 && distance > 1 {
                duration = min(max(Double(3 * distance / abs(velocity)), 0.15), 0.7)
            }
            // Magnetic: it carries on at the finger's speed into a spring on the next window,
            // so it swings past and settles like something with weight. The speed is held to
            // 1.5-2.5x the way from where the swipe began, so the swing grows with the way
            // (about 2-4% of it) whether the finger lifted slowly or threw it.
            var spring: Animation.Spring?
            if settings.swipe.snap == .always {
                let travel = target - g.startScroll
                if abs(travel) >= 1 {
                    let toward = travel > 0 ? max(velocity, 0) : max(-velocity, 0)
                    let speed = min(max(toward, abs(travel) * 1.5), abs(travel) * 2.5)
                    let sp = Animation.Spring(x0: Double(s - target), v0: Double(travel > 0 ? speed : -speed))
                    spring = sp
                    duration = sp.duration
                }
            }
            // Let go past an end: back at an easy pace, however fast the release.
            if s < -0.5 || s > g.strip.maxScroll(viewportHeight: vh, gap: settings.gap) + 0.5 {
                duration = max(duration, 0.3)
            }
            animate(g.key, duration: duration, spring: spring)
            if settings.swipe.focus {
                var focusID = g.strip.focused
                if focusID == nil || !g.strip.isFullyVisible(focusID!, scroll: target, viewportHeight: vh, gap: settings.gap),
                   let r = g.strip.topVisibleRow(scroll: target, viewportHeight: vh, gap: settings.gap) {
                    focusID = g.strip.rows[r].windows.first
                }
                // Our tracked focus is kept current by AX notifications; asking the system here
                // would be a blocking round trip right as the glide starts.
                if let id = focusID, id != g.strip.focused {
                    g.strip.focused = id
                    activateAfterScroll(id, key: g.key)
                }
            }
            Log.debug(String(format: "swipe ended v=%d (%.2f pads/s, %.2f pads) -> %d", Int(velocity), v, g.padTravel, Int(target)))
            emit?("swipeEnded", ["scroll": target])

        case .tap, .doubleTap:
            break
        }
    }

    // MARK: Layout

    private func strip(_ key: StripKey) -> Strip {
        if let s = strips[key] { return s }
        let s = Strip()
        strips[key] = s
        return s
    }

    private func locate(_ id: CGWindowID) -> (StripKey, Strip)? {
        for (k, s) in strips where s.contains(id) { return (k, s) }
        return nil
    }

    private func viewport(_ screen: NSScreen) -> CGRect {
        scrollArea(screen).insetBy(dx: settings.outerGap, dy: settings.outerGap)
    }

    private func params(_ screen: NSScreen) -> LayoutParams {
        let area = scrollArea(screen)
        // An area reaching the bottom of the usable screen lets windows run off it as before.
        let cut = area.maxY < Geometry.ax(screen.usableFrame).maxY - 1
        return LayoutParams(viewport: viewport(screen), hardTop: area.minY,
                            hardBottom: cut ? area.maxY : Geometry.ax(screen.frame).maxY, gap: settings.gap,
                            widthRatio: settings.width, topOverflow: settings.topOverflow,
                            minVisible: settings.minVisible, cutBottom: cut)
    }

    private func visibleKey(for screen: NSScreen, displays: [Spaces.Display]? = nil) -> StripKey {
        StripKey(space: Spaces.current(on: screen, displays: displays ?? Spaces.displays()),
                 display: Geometry.displayID(screen))
    }

    private func visibleKeys() -> [StripKey: NSScreen] {
        let d = Spaces.displays()
        var out: [StripKey: NSScreen] = [:]
        for s in NSScreen.screens { out[visibleKey(for: s, displays: d)] = s }
        return out
    }

    private func isVisible(_ key: StripKey) -> Bool { visibleScreen(key) != nil }

    private func visibleScreen(_ key: StripKey) -> NSScreen? {
        guard let screen = Geometry.screen(displayID: key.display),
              visibleKey(for: screen).space == key.space else { return nil }
        return screen
    }

    func layoutVisible(animated: Bool) {
        for (key, _) in visibleKeys() where strips[key] != nil {
            relayout(key, animated: animated)
        }
    }

    private func relayout(_ key: StripKey, animated: Bool) {
        guard let strip = strips[key], !overviewActive else { return }
        let driven = gesture?.key == key || autoScroll?.key == key
        guard let screen = visibleScreen(key), !driven else {
            // Not laid out now: start frames recorded for this change would go stale.
            pendingFrom.removeValue(forKey: key)
            if !driven { strip.renderScrollY = strip.scrollY }
            return
        }
        if animated && settings.animationDuration > 0
            && (abs(strip.renderScrollY - strip.scrollY) > 1 || pendingFrom[key] != nil) {
            animate(key, duration: settings.animationDuration)
        } else {
            pendingFrom.removeValue(forKey: key)
            stopAnimation(key)
            strip.renderScrollY = strip.scrollY
            apply(strip, screen: screen, key: key)
            settle(strip, screen: screen)
        }
    }

    /// Where a magnetic step from `s` (-1 up, +1 down) lands: the next window that way. Asked
    /// as a short nudge that way (a huge one ran into the strip's end, which is a resting
    /// place of its own, and answered "the end").
    private func nextWindow(_ strip: Strip, from s: CGFloat, _ dir: Int, vh: CGFloat) -> CGFloat {
        let d = CGFloat(dir)
        return strip.snapTarget(from: s + d * 40, velocity: d * vh * 0.2, start: s, viewportHeight: vh, gap: settings.gap)
    }

    /// One step up (-1) or down (+1), from a button (Settings › Mouse buttons): the next window
    /// with magnetic scrolling, half a screen otherwise. Presses in a row add up (each starts
    /// where the last is heading). Not while a window covers the strip, as with a swipe.
    func scrollStep(_ dir: Int) {
        guard enabled, !overviewActive, gesture == nil, let screen = Geometry.screenUnderMouse() else { return }
        let key = visibleKey(for: screen)
        guard let strip = strips[key], !strip.isEmpty, maximizedID(key) == nil, !appFilledScreen(screen) else { return }
        let vh = viewport(screen).height
        let from = strip.scrollY
        let target = settings.swipe.snap == .always
            ? nextWindow(strip, from: from, dir, vh: vh)
            : strip.clampScroll(from + CGFloat(dir) * vh / 2, viewportHeight: vh, gap: settings.gap)
        guard abs(target - from) > 0.5 else { return }
        strip.scrollY = target
        animate(key, duration: max(settings.animationDuration * 1.5, 0.25))
    }

    /// A magnetic swipe this strong moves three windows instead of one: the fingers went this
    /// much of the trackpad's height, at this many trackpad heights per second (on average
    /// or when they let go).
    private static let strongSwipeTravel = 0.5
    private static let strongSwipeSpeed = 2.0

    private func animate(_ key: StripKey, duration: Double, spring: Animation.Spring? = nil) {
        guard let strip = strips[key] else { return }
        // Retargeted mid-way: a pinned window's final frame is no longer final.
        if animations[key] != nil { pinned.subtract(strip.windowIDs) }
        if let from = pendingFrom.removeValue(forKey: key) {
            transitions[key] = from
        } else if transitions[key] != nil {
            // Retargeted mid-slide: carry on from where the windows are now.
            transitions[key] = visualFrames(key)
        }
        animations[key] = Animation(strip: strip, from: strip.renderScrollY, to: strip.scrollY,
                                    start: CACurrentMediaTime(), duration: duration, spring: spring)
        prepareProxies(strip)
        driver.start()
    }

    private func markDirty(_ key: StripKey) {
        dirty.insert(key)
        driver.start()
    }

    /// A command is about to rearrange the strip: remember where its windows are, so the
    /// animated relayout that follows slides them to their new places.
    private func beginTransition(_ key: StripKey, recordUndo record: Bool = true) {
        // Every rearrangement that slides starts here: remember how it was, for undo.
        if record { recordUndo(key) }
        // Already recorded for this command (e.g. before un-maximizing): keep the earlier frames.
        guard settings.animationDuration > 0, gesture?.key != key, pendingFrom[key] == nil,
              visibleScreen(key) != nil else { return }
        let from = visualFrames(key)
        if !from.isEmpty { pendingFrom[key] = from }
    }

    /// Progress (eased, 0...1) of the strip's running animation.
    private func progress(_ key: StripKey) -> CGFloat? {
        guard let a = animations[key] else { return nil }
        let t = min(1, (CACurrentMediaTime() - a.start) / max(a.duration, 0.001))
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// Full frames (ignoring the screen edges) of the strip's windows as currently shown:
    /// the layout at the rendered scroll, or part way along a running slide. Windows off
    /// screen have one too, so a move slides them in and out instead of making them pop.
    private func visualFrames(_ key: StripKey) -> [CGWindowID: CGRect] {
        guard let strip = strips[key], let screen = visibleScreen(key) else { return [:] }
        let from = transitions[key], t = progress(key), maxID = maximizedID(key)
        var out: [CGWindowID: CGRect] = [:]
        for item in strip.layout(params(screen), scroll: strip.renderScrollY, minHeights: minHeights) {
            let to = maxID == item.id ? fullScreenFrame(screen) : item.frame
            if let f = from?[item.id], let t {
                out[item.id] = f.interpolated(to: to, t)
            } else {
                out[item.id] = to
            }
        }
        return out
    }

    private func stopAnimation(_ key: StripKey) {
        animations.removeValue(forKey: key)
        transitions.removeValue(forKey: key)
        maximizeSliding.removeValue(forKey: key)
        if let id = pendingActivation.removeValue(forKey: key), let w = windows[id] ?? floating[id] {
            activate(w)
        }
        if let strip = strips[key] { pinned.subtract(strip.windowIDs) }
    }

    /// One display frame: advance animations, then lay out every strip that changed,
    /// at most once per frame however many swipe events arrived in between.
    private func frame() {
        if overviewActive {
            dirty.removeAll()
            driver.pause()
            return
        }
        let now = CACurrentMediaTime()
        if autoScroll != nil { stepAutoScroll(now) }
        var finished: [StripKey] = []
        for (key, a) in animations {
            let t = min(1, (now - a.start) / max(a.duration, 0.001))
            a.strip.renderScrollY = a.scroll(at: t)
            dirty.insert(key)
            if t >= 1 {
                animations.removeValue(forKey: key)
                transitions.removeValue(forKey: key)
                maximizeSliding.removeValue(forKey: key)
                finished.append(key)
            }
        }
        // The last frame of an animation lays out every window, including ones pinned for it.
        for key in finished { if let strip = strips[key] { pinned.subtract(strip.windowIDs) } }
        if gesture == nil { for key in finished { releaseProxies(key) } }
        for key in dirty {
            // Only the desktop on screen: a strip left behind by a desktop switch mid-animation
            // would be laid out with the new desktop's area (wrong widths, resized windows).
            guard let strip = strips[key], let screen = visibleScreen(key) else { continue }
            apply(strip, screen: screen, key: key)
            updateScrollIndicator(key, strip: strip, screen: screen)
        }
        dirty.removeAll()
        for key in finished {
            FrameStats.report("animation")
            if let id = pendingActivation.removeValue(forKey: key), let w = windows[id] ?? floating[id] {
                activate(w)
            }
            if let strip = strips[key], let screen = visibleScreen(key) {
                settle(strip, screen: screen)
            }
        }
        if autoScroll != nil {
            // The line follows the rows going by; at the end of the strip scrolling stops.
            updateDropPreview(force: true)
        }
        if animations.isEmpty && gesture == nil && autoScroll == nil { driver.pause() }
    }

    private func apply(_ strip: Strip, screen: NSScreen, key: StripKey) {
        FrameStats.measure {
            let p = params(screen)
            let resizing = liveResize?.id
            // Progress of the strip's slide, same easing as the scroll animation.
            let from = transitions[key], t = progress(key), maxID = maximizedID(key)
            for item in strip.layout(p, scroll: strip.renderScrollY, minHeights: minHeights) {
                // Never fight the user's drag: the window being resized stays where they put it.
                // Pinned (just opened) windows are already at their final frame.
                // Nor the one being dragged by the mouse (the strip may scroll under it).
                guard item.id != resizing, item.id != dragging, !pinned.contains(item.id),
                      let w = windows[item.id] else { continue }
                let full = maxID == item.id ? fullScreenFrame(screen) : nil
                if let f = from?[item.id], let t {
                    let r = f.interpolated(to: full ?? item.frame, t)
                    if maximizeSliding[key] == item.id {
                        // Growing to fill the screen or shrinking back: a real window all the way,
                        // over the zone's edges.
                        place(w, .frame(r), screen: screen, rowHeight: r.height, hardTop: p.hardTop)
                        continue
                    }
                    // Slide the whole frame, then show it like any other: on screen, peeking
                    // over the top edge, or parked once it's out of view.
                    place(w, Strip.placement(r, p, minHeight: minHeights[item.id]), screen: screen,
                          rowHeight: r.height, hardTop: p.hardTop, clipBottom: p.clipBottom)
                } else if let full {
                    place(w, .frame(full), screen: screen, rowHeight: full.height, hardTop: p.hardTop, clipBottom: p.clipBottom)
                } else if maxID != nil, case .overflow = item.placement {
                    // A peek would show over the window filling the screen.
                    place(w, .park, screen: screen, rowHeight: item.rowHeight, hardTop: p.hardTop, clipBottom: p.clipBottom)
                } else {
                    place(w, item.placement, screen: screen, rowHeight: item.rowHeight, hardTop: p.hardTop, clipBottom: p.clipBottom)
                }
            }
        }
    }

    private func place(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, rowHeight: CGFloat,
                       hardTop: CGFloat, clipBottom: CGFloat = .greatestFiniteMagnitude) {
        if proxyPlace(w, placement, screen: screen, hardTop: hardTop) { return }
        if case .overflow(let full) = placement {
            // Capture only now, as the window starts to peek (keeps the recording indicator off
            // otherwise). A real, unshrunk window can be captured wherever it is.
            // A parked window captures greyer (no wallpaper tint): keep an on-screen one if we have it.
            if !overlays.isShowing(w.id) && !w.shrunk && snapshots.age(w.id) > 0.3
                && !(w.parked && snapshots.isOnScreenCapture(w.id)) {
                snapshots.capture(w.id, size: full.size, onScreen: !w.parked)
            }
            var image = snapshots.image(w.id, size: full.size)
            if image == nil, !snapshots.isCapturing(w.id),
               let stale = overlays.currentImage(w.id) ?? snapshots.latestImage(w.id) {
                // Its size changed since the picture was taken (a resized scroll area, a width
                // change): keep showing the old picture, stretched a little, rather than hide
                // the window, and take a new one once nothing moves. Waiting for a matching
                // picture left such windows parked out of sight until scrolled past.
                image = stale
                if !isMoving { refreshSnapshot(w, size: full.size, screen: screen) }
            }
            if let image {
                // Draw the snapshot first, then move the real window away, so nothing flickers.
                // It stays as a clickable "peek" at rest too, since the real window can't sit there.
                let wasShowing = overlays.isShowing(w.id)
                if !wasShowing { Log.debug("overlay on \(w.id) \(w.appName)") }
                overlays.show(w.id, image: image, full: full, clipTop: hardTop, clipBottom: clipBottom,
                              trueColor: snapshots.isOnScreenCapture(w.id), moving: isMoving, below: dragging)
                // Park it (at its full row size, so the live mirror isn't squashed) only once
                // the stand-in is on screen: a fresh overlay needs a frame or two to appear.
                if w.parked || pendingParks[w.id] != nil {
                    // already away / about to go
                } else if wasShowing {
                    park(w, screen: screen, size: full.size)
                } else {
                    let size = full.size
                    let item = DispatchWorkItem { [weak self, weak w] in
                        guard let self, let w else { return }
                        self.pendingParks[w.id] = nil
                        if self.overlays.isShowing(w.id) { self.park(w, screen: screen, size: size) }
                    }
                    pendingParks[w.id] = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
                }
                return
            }
            // Snapshot on its way (a frame or two): leave the real window where it is meanwhile.
            if snapshots.isCapturing(w.id) && !w.shrunk { return }
            // No snapshot possible (no Screen Recording permission): pin to the top edge and
            // shrink, or hide if the app can't get that small.
            if !w.parked && !w.shrunk { Log.debug("no usable snapshot for \(w.id) \(w.appName), shrinking") }
            let top = max(full.minY, hardTop), visible = min(full.maxY, clipBottom) - top
            let needed = max(settings.minVisible, minHeights[w.id] ?? 0)
            let fallback: Placement = visible >= needed
                ? .frame(CGRect(x: full.minX, y: top, width: full.width, height: visible))
                : .park
            return place(w, fallback, screen: screen, rowHeight: rowHeight, hardTop: hardTop, clipBottom: clipBottom)
        }
        pendingParks.removeValue(forKey: w.id)?.cancel()
        if overlays.isShowing(w.id) {
            if case .frame(let r) = placement {
                // Bring the real window back, and keep the stand-in over it until it's there.
                placeReal(w, placement, screen: screen, rowHeight: rowHeight)
                handOver(w, to: r)
                return
            }
            overlays.hide(w.id)
        }
        placeReal(w, placement, screen: screen, rowHeight: rowHeight)
    }

    /// Windows being resized off screen for a new snapshot (see `refreshSnapshot`), and when
    /// each was last re-captured: an app that won't take the new size isn't asked every frame.
    private var resnapping = Set<CGWindowID>()
    private var lastResnap: [CGWindowID: CFTimeInterval] = [:]

    /// Re-captures a peeking window at its new size: a capture shows the window as it is,
    /// so a parked one is first resized (still off screen) and captured once that landed.
    private func refreshSnapshot(_ w: ManagedWindow, size: CGSize, screen: NSScreen) {
        let id = w.id
        let now = CACurrentMediaTime()
        guard now - (lastResnap[id] ?? 0) > 2, resnapping.insert(id).inserted else { return }
        lastResnap[id] = now
        if w.parked, let lf = w.lastFrame, abs(lf.width - size.width) > 0.5 || abs(lf.height - size.height) > 0.5 {
            w.parked = false
            park(w, screen: screen, size: size)
        }
        Log.debug("re-snapshot \(id) \(w.appName) at \(Int(size.width))x\(Int(size.height))")
        writer.perform(pid: w.pid) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.resnapping.remove(id)
                guard self.windows[id] != nil else { return }
                self.snapshots.capture(id, size: size, onScreen: false)
            }
        }
    }

    // MARK: Slow-app stand-ins

    /// Drawn by a snapshot while the strip moves: every window with smooth scrolling on,
    /// otherwise only those of apps slow to move their windows.
    private func isSlow(_ w: ManagedWindow) -> Bool {
        settings.smoothScroll
            || (settings.slowAppProxy && writer.moveLatency(pid: w.pid) > settings.slowAppThreshold)
    }

    /// Smooth scrolling on: at rest, keep a recent picture of the windows on screen, so the
    /// next swipe can draw them from its first frame (a capture takes a frame or two, and
    /// `prepareProxies` refreshes them as the motion starts).
    private func prewarmStandIns(_ strip: Strip) {
        guard settings.smoothScroll, !isMoving else { return }
        for id in strip.windowIDs {
            guard let w = windows[id], !w.parked, !w.shrunk, let f = w.lastFrame,
                  !overlays.isShowing(id), snapshots.age(id) > 2 else { continue }
            snapshots.capture(id, size: f.size, onScreen: true)
        }
    }

    /// Motion is starting: snapshot the visible windows of slow apps so they can be stood in for.
    private func prepareProxies(_ strip: Strip) {
        guard settings.slowAppProxy || settings.smoothScroll else { return }
        // Parked windows too: they may scroll into view, and the capture reads a window's own
        // content wherever it is.
        for id in strip.windowIDs {
            guard let w = windows[id], !w.shrunk, let f = w.lastFrame, isSlow(w),
                  snapshots.age(id) > 0.5, !(w.parked && snapshots.isOnScreenCapture(id)) else { continue }
            Log.debug(String(format: "proxy prepare %d %@ (moves take %.0f ms)", id, w.appName, writer.moveLatency(pid: w.pid)))
            snapshots.capture(id, size: f.size, onScreen: !w.parked)
        }
    }

    /// While moving, a slow app's window is drawn by its stand-in at the new frame every
    /// display frame, and the real window waits (parked) until the motion ends.
    private func proxyPlace(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, hardTop: CGFloat) -> Bool {
        guard isMoving else {
            // Laid out at rest (e.g. an animation was cut short): the normal path takes over.
            proxied.remove(w.id)
            return false
        }
        switch placement {
        case .frame(let r):
            if !proxied.contains(w.id) {
                guard isSlow(w), !w.shrunk,
                      let image = snapshots.image(w.id, size: r.size) ?? overlays.currentImage(w.id) else { return false }
                overlays.show(w.id, image: image, full: r, clipTop: hardTop,
                              trueColor: snapshots.isOnScreenCapture(w.id), stream: false, moving: true, below: dragging)
                proxied.insert(w.id)
                proxyShownAt[w.id] = CACurrentMediaTime()
                pendingParks.removeValue(forKey: w.id)?.cancel()
                placeReal(w, .frame(r), screen: screen, rowHeight: r.height)
                Log.debug("proxy on \(w.id) \(w.appName)")
                return true
            }
            // A fresh capture (requested as the motion started) replaces the warm-up picture.
            guard let image = snapshots.image(w.id, size: r.size) ?? overlays.currentImage(w.id) else { return false }
            overlays.show(w.id, image: image, full: r, clipTop: hardTop, stream: false, moving: true, below: dragging)
            if !w.parked {
                if CACurrentMediaTime() - (proxyShownAt[w.id] ?? 0) >= Self.standInSettle {
                    park(w, screen: screen, size: r.size)
                } else {
                    placeReal(w, .frame(r), screen: screen, rowHeight: r.height)
                }
            }
            return true
        case .overflow:
            // Becomes a regular top-edge peek (also a stand-in over a parked window).
            proxied.remove(w.id)
            return false
        case .park:
            if proxied.remove(w.id) != nil { overlays.hide(w.id) }
            return false
        }
    }

    /// Motion ended: move each stood-in window to its final frame in one go, and keep the
    /// stand-in on top until the app has actually moved it.
    private func releaseProxies(_ key: StripKey) {
        guard let strip = strips[key], let screen = visibleScreen(key) else { return }
        let ids = strip.windowIDs.filter { proxied.contains($0) }
        guard !ids.isEmpty else { return }
        proxied.subtract(ids)
        for id in ids { proxyShownAt.removeValue(forKey: id) }
        let p = params(screen)
        for item in strip.layout(p, scroll: strip.renderScrollY, minHeights: minHeights) where ids.contains(item.id) {
            guard let w = windows[item.id] else { continue }
            guard case .frame(let r) = item.placement else {
                place(w, item.placement, screen: screen, rowHeight: item.rowHeight, hardTop: p.hardTop, clipBottom: p.clipBottom)
                continue
            }
            placeReal(w, item.placement, screen: screen, rowHeight: item.rowHeight)
            handOver(w, to: r)
        }
    }

    /// The real window is being moved back to `r` under its stand-in: the stand-in stays on
    /// top, unclipped, until the app has applied the move (and the window server had a frame
    /// to show it), then fades. A fixed delay was too short for slow apps (100 ms and more),
    /// and the window vanished for a moment. Gives up waiting after 0.6 s.
    private func handOver(_ w: ManagedWindow, to r: CGRect) {
        overlays.handoff(w.id, to: r, delay: 0.6)
        guard handingOver.insert(w.id).inserted else { return }
        let id = w.id
        writer.perform(pid: w.pid) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self else { return }
                self.handingOver.remove(id)
                // Not if it became a stand-in or a peek again meanwhile.
                guard !self.proxied.contains(id), self.windows[id]?.parked == false else { return }
                self.overlays.fadeOut(id)
            }
        }
    }

    private func park(_ w: ManagedWindow, screen: NSScreen, size wanted: CGSize? = nil) {
        guard !w.parked else { return }
        var size = w.lastFrame?.size ?? AX.size(w.element) ?? CGSize(width: 800, height: 600)
        var setSize = false
        if let wanted, abs(wanted.width - size.width) > 0.5 || abs(wanted.height - size.height) > 0.5 {
            size = wanted
            setSize = true
        }
        let p = parkPoint(screen, size: size)
        writer.move(w.id, pid: w.pid, element: w.element, to: CGRect(origin: p, size: size), setSize: setSize)
        w.parked = true
        w.shrunk = false
        w.lastFrame = CGRect(origin: p, size: size)
    }

    private func placeReal(_ w: ManagedWindow, _ placement: Placement, screen: NSScreen, rowHeight: CGFloat) {
        switch placement {
        case .frame(let r):
            if !w.parked, let lf = w.lastFrame, lf.approxEqual(r) { return }
            let sizeChanged = w.lastFrame.map { abs($0.width - r.width) > 0.5 || abs($0.height - r.height) > 0.5 } ?? true
            w.shrunk = r.height < rowHeight - 1
            // Shrunk at the top edge: have the writer report it if the app refuses that height.
            writer.move(w.id, pid: w.pid, element: w.element, to: r, setSize: sizeChanged, checkMinHeight: w.shrunk)
            w.lastFrame = r
            w.parked = false
            if sizeChanged && !w.shrunk { w.needsSizeCheck = true }
        case .park:
            park(w, screen: screen)
        case .overflow:
            break
        }
    }

    var isMoving: Bool { gesture != nil || !animations.isEmpty || autoScroll != nil }

    private func setupSnapshots() {
        overlays.onClick = { [weak self] id in
            Log.debug("peek clicked \(id)")
            self?.focus(id)
        }
        // A snapshot arrived for a window that started peeking: draw it now.
        snapshots.onReady = { [weak self] id in
            guard let self, let (key, _) = self.locate(id) else { return }
            self.markDirty(key)
        }
    }



    /// Off-screen spot for windows outside the viewport (macOS keeps ≥1px of a window on screen).
    private func parkPoint(_ screen: NSScreen, size: CGSize) -> CGPoint {
        let sf = Geometry.ax(screen.frame)
        let others = NSScreen.screens.filter { $0 != screen }.map { Geometry.ax($0.frame) }
        let candidates = [
            CGPoint(x: sf.maxX - 1, y: sf.maxY - 1),
            CGPoint(x: sf.minX - size.width + 1, y: sf.maxY - 1),
        ]
        return candidates.first { c in
            let r = CGRect(origin: c, size: size).insetBy(dx: 2, dy: 2)
            return !others.contains { $0.intersects(r) }
        } ?? candidates[0]
    }

    /// After a layout comes to rest, check (off the main thread) whether resized windows
    /// actually took their new height; adopt the height of any that refused to get smaller.
    private func settle(_ strip: Strip, screen: NSScreen) {
        prewarmStandIns(strip)
        let vh = viewport(screen).height
        for row in strip.rows {
            for id in row.windows {
                guard let w = windows[id], w.needsSizeCheck, !w.parked, !w.shrunk, let lf = w.lastFrame else { continue }
                w.needsSizeCheck = false
                let expected = lf.height
                let element = w.element
                writer.perform(pid: w.pid) { [weak self] in
                    guard let actual = AX.size(element), actual.height > expected + 4, actual.height <= vh + 1 else { return }
                    DispatchQueue.main.async { self?.adoptHeight(id, actual.height) }
                }
            }
        }
    }

    private func adoptHeight(_ id: CGWindowID, _ height: CGFloat) {
        guard !isMoving, let (key, strip) = locate(id), let (r, _) = strip.locate(id),
              strip.rows[r].height < height else { return }
        Log.debug("window \(id) refused height \(Int(strip.rows[r].height)), adopting \(Int(height))")
        strip.rows[r].height = height.rounded()
        relayout(key, animated: false)
    }

    // MARK: Focus

    private func systemFocusedWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        guard let el = AX.element(appEl, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(el)
    }

    /// Focuses the window. Runs on the app's writer queue: after its pending moves, and
    /// without blocking the main thread on a slow app.
    private func activate(_ w: ManagedWindow) {
        trackedFocus = w.id
        let pid = w.pid
        let element = w.element
        let name = w.appName
        writer.perform(pid: pid) {
            let t0 = CACurrentMediaTime()
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
            AX.set(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, kCFBooleanTrue)
            AX.raise(element)
            Log.debug(String(format: "[focus] activating %@ took %.0f ms", name, (CACurrentMediaTime() - t0) * 1000))
        }
    }

    func focus(_ id: CGWindowID) {
        guard let w = windows[id] ?? floating[id] else { return }
        if let (key, strip) = locate(id) {
            strip.focused = id
            if let screen = visibleScreen(key) {
                strip.scrollY = strip.scrollToReveal(id, viewportHeight: viewport(screen).height, gap: settings.gap)
                relayout(key, animated: true)
                activateAfterScroll(id, key: key)
                return
            }
        }
        activate(w)
    }

    /// Focuses now if the strip is at rest, otherwise as soon as its animation ends.
    private func activateAfterScroll(_ id: CGWindowID, key: StripKey) {
        trackedFocus = id
        if animations[key] != nil {
            pendingActivation[key] = id
        } else if let w = windows[id] ?? floating[id] {
            pendingActivation[key] = nil
            activate(w)
        }
    }

    // MARK: Commands

    private struct Context {
        let key: StripKey
        let strip: Strip
        let screen: NSScreen
        let id: CGWindowID?
        var vh: CGFloat
    }

    /// Focused window: the one AX last reported, if it still belongs to the frontmost app
    /// (a local check); otherwise ask the app.
    private func focusedWindowID() -> CGWindowID? {
        if let id = trackedFocus, let w = windows[id] ?? floating[id],
           w.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return id
        }
        return systemFocusedWindowID()
    }

    private func context() -> Context? {
        if let fid = focusedWindowID(), let (key, strip) = locate(fid), let screen = visibleScreen(key) {
            strip.focused = fid
            return Context(key: key, strip: strip, screen: screen, id: fid, vh: viewport(screen).height)
        }
        guard let screen = Geometry.screenUnderMouse() else { return nil }
        let key = visibleKey(for: screen)
        if untiledIDs.contains(key.space) { return nil }
        let strip = self.strip(key)
        return Context(key: key, strip: strip, screen: screen, id: strip.focused, vh: viewport(screen).height)
    }

    @discardableResult
    func perform(_ name: String, arg: Any? = nil) -> Bool {
        guard let cmd = Command(rawValue: name) else {
            Log.info("unknown command: \(name)")
            return false
        }
        switch cmd {
        case .toggleTiling: setEnabled(!enabled); return true
        case .openSettings:
            openSettings?()
            return true
        case .editScrollArea:
            guard enabled, let screen = Geometry.screenUnderMouse() else { return false }
            editScrollArea?(screen)
            return true
        case .toggleSpaceTiling:
            guard enabled, let screen = Geometry.screenUnderMouse() else { return false }
            setSpaceTiled(!isTiled(screen: screen), screen: screen)
            return true
        case .reloadConfig: reloadConfig?(); return true
        case .missionControl: openOverview(SystemActions.missionControl); return true
        case .appExpose: openOverview(SystemActions.appExpose); return true
        case .showDesktop: SystemActions.showDesktop(); return true
        case .launchpad: SystemActions.launchpad(); return true
        case .retile:
            for w in windows.values { w.lastFrame = nil; w.parked = false }
            scanAll(initial: false)
            return true
        default: break
        }
        guard enabled, let c = context() else { return false }
        // A command that gives up half way (bad argument, nothing to move) must not leave
        // start frames behind for the next one; a completed one has used them already.
        defer { pendingFrom.removeValue(forKey: c.key) }
        let gap = settings.gap
        let s = c.strip

        func reveal(_ id: CGWindowID) {
            s.scrollY = s.scrollToReveal(id, viewportHeight: c.vh, gap: gap)
        }
        // Rearranging the strip brings a full-screen window back into it first.
        let keepsMaximized: Set<Command> = [.focusUp, .focusDown, .focusLeft, .focusRight, .focusFirst, .focusLast,
                                            .focusRow, .center, .alignTop, .scrollUp, .scrollDown, .scrollBy,
                                            .scrollToTop, .scrollToBottom, .closeWindow, .toggleMaximize, .undo]
        if maximizedID(c.key) != nil && !keepsMaximized.contains(cmd) {
            beginTransition(c.key)
            maximized[c.key] = nil
        }
        func number(_ v: Any?) -> CGFloat? {
            (v as? NSNumber).map { CGFloat($0.doubleValue) } ?? (v as? Double).map { CGFloat($0) }
        }

        switch cmd {
        case .focusUp, .focusDown, .focusLeft, .focusRight:
            guard let id = c.id else {
                if let first = s.rows.first?.windows.first { focus(first) }
                return true
            }
            let dir: Direction = [.focusUp: .up, .focusDown: .down, .focusLeft: .left, .focusRight: .right][cmd]!
            if let n = s.neighbor(of: id, dir) { focus(n) }
        case .focusFirst:
            if let n = s.rows.first?.windows.first { focus(n) }
        case .focusLast:
            if let n = s.rows.last?.windows.first { focus(n) }
        case .focusRow:
            // 1-based row number, like workspace numbers.
            guard let n = number(arg).map({ Int($0) }), n >= 1, n <= s.rows.count else { return false }
            if let id = s.rows[n - 1].windows.first { focus(id) }

        case .moveUp, .moveDown, .moveLeft, .moveRight, .moveFirst, .moveLast, .slurpIn, .barfOut,
             .joinUp, .joinDown:
            guard let id = c.id else { return false }
            beginTransition(c.key)
            switch cmd {
            // Into the next row when it has room beside its window, else past it.
            case .moveUp: if !s.joinIfFits(id, by: -1) { s.moveVertical(id, by: -1) }
            case .moveDown: if !s.joinIfFits(id, by: 1) { s.moveVertical(id, by: 1) }
            case .moveLeft: s.moveHorizontal(id, by: -1)
            case .moveRight: s.moveHorizontal(id, by: 1)
            case .moveFirst: s.moveToEdge(id, top: true)
            case .moveLast: s.moveToEdge(id, top: false)
            case .slurpIn: s.slurpIn(id)
            case .joinUp: s.joinVertical(id, by: -1)
            case .joinDown: s.joinVertical(id, by: 1)
            case .barfOut: s.barfOut(id)
            default: break
            }
            reveal(id)
            relayout(c.key, animated: true)

        case .cycleWidth, .cycleWidthBack, .setWidth, .resizeWidth, .equalizeRow:
            guard let id = c.id, let (r, _) = s.locate(id) else { return false }
            beginTransition(c.key)
            if s.rows[r].windows.count == 1 {
                // Alone in its row: the share is of the whole row, the rest stays empty.
                let cur = min(s.weight(id), 1)
                switch cmd {
                case .cycleWidth, .cycleWidthBack:
                    let presets = (settings.widths + [1]).sorted()
                    let next = cmd == .cycleWidth ? presets.first { $0 > cur + 0.01 } ?? presets.first!
                                                  : presets.last { $0 < cur - 0.01 } ?? presets.last!
                    s.setLoneWidth(id, next)
                case .setWidth:
                    guard let f = number(arg), f > 0, f <= 1 else { return false }
                    s.setLoneWidth(id, f)
                case .resizeWidth:
                    s.setLoneWidth(id, cur + (number(arg) ?? settings.resizeStep))
                default:
                    s.setLoneWidth(id, nil)
                }
                windows[id]?.lastFrame = nil
                relayout(c.key, animated: true)
                return true
            }
            switch cmd {
            case .cycleWidth, .cycleWidthBack:
                if let f = s.cycledWidthFraction(id, ratios: settings.widths, forward: cmd == .cycleWidth) {
                    s.setWidthFraction(id, f)
                }
            case .setWidth:
                guard let f = number(arg), f > 0, f < 1 else { return false }
                s.setWidthFraction(id, f)
            case .resizeWidth:
                let step = number(arg) ?? settings.resizeStep
                s.setWidthFraction(id, (s.widthFraction(id) ?? 0.5) + step)
            default:
                s.equalizeRow(of: id)
            }
            relayout(c.key, animated: true)

        case .cycleHeight, .cycleHeightBack, .setHeight, .toggleFullHeight, .resizeHeight:
            guard let id = c.id, let (r, _) = s.locate(id), let w = windows[id] else { return false }
            beginTransition(c.key)
            switch cmd {
            case .cycleHeight, .cycleHeightBack:
                if let h = s.cycledHeight(id, ratios: settings.heights, viewportHeight: c.vh, gap: gap,
                                          forward: cmd == .cycleHeight) {
                    s.rows[r].height = h
                }
                w.savedHeight = nil
            case .resizeHeight:
                let step = (number(arg) ?? settings.resizeStep) * c.vh
                s.rows[r].height = min(max(s.rows[r].height + step, 80), c.vh).rounded()
                w.savedHeight = nil
            case .setHeight:
                guard let ratio = number(arg), ratio > 0 else { return false }
                s.rows[r].height = ratio <= 1
                    ? Strip.height(forRatio: ratio, viewportHeight: c.vh, gap: gap)
                    : min(ratio, c.vh)
            default:
                if let saved = w.savedHeight {
                    s.rows[r].height = saved
                    w.savedHeight = nil
                } else {
                    w.savedHeight = s.rows[r].height
                    s.rows[r].height = c.vh
                }
            }
            reveal(id)
            relayout(c.key, animated: true)

        case .center, .alignTop:
            guard let id = c.id else { return false }
            s.scrollY = cmd == .center
                ? s.scrollToCenter(id, viewportHeight: c.vh, gap: gap)
                : s.scrollToTop(id, gap: gap)
            relayout(c.key, animated: true)

        case .scrollUp, .scrollDown, .scrollBy:
            var delta: CGFloat
            if cmd == .scrollBy {
                delta = number(arg) ?? 0
            } else {
                delta = (number(arg) ?? 0.5) * c.vh * (cmd == .scrollUp ? -1 : 1)
            }
            s.scrollY = s.clampScroll(s.scrollY + delta, viewportHeight: c.vh, gap: gap)
            relayout(c.key, animated: true)
        case .scrollToTop:
            s.scrollY = 0
            relayout(c.key, animated: true)
        case .scrollToBottom:
            s.scrollY = s.maxScroll(viewportHeight: c.vh, gap: gap)
            relayout(c.key, animated: true)

        case .toggleFloat:
            toggleFloat(c)
        case .undo:
            return undo(c.key, strip: s, viewportHeight: c.vh)
        case .toggleMaximize:
            guard let id = c.id else { return false }
            setMaximized(id, maximizedID(c.key) != id)
        case .closeWindow:
            guard let id = c.id ?? systemFocusedWindowID(), let w = windows[id] ?? floating[id],
                  let button = AX.element(w.element, kAXCloseButtonAttribute) else { return false }
            AX.press(button)
        case .moveToNextScreen:
            moveToNextScreen(c)
        default:
            return false
        }
        return true
    }

    // MARK: Mission Control

    /// Mission Control and App Exposé scale their thumbnails to fit every window where it
    /// really is, and Oz keeps most of the strip parked off screen, so they came out tiny.
    /// Bring the visible strips' windows on screen first, and tile again once it closes.
    /// (Opened some other way, e.g. a four-finger swipe, the overview can't be prepared.)
    private func openOverview(_ open: @escaping () -> Void) {
        guard enabled, !overviewActive, !SystemActions.isOverviewShowing else {
            open()
            // Ours and up: this closes it.
            if overviewActive { overviewClosing() }
            return
        }
        overviewActive = true
        gesture = nil
        for key in Array(animations.keys) { stopAnimation(key) }
        dirty.removeAll()
        driver.pause()
        for item in pendingParks.values { item.cancel() }
        pendingParks.removeAll()
        proxied.removeAll()
        overlays.hideAll()
        hideScrollIndicators()
        for (key, screen) in visibleKeys() {
            guard let strip = strips[key] else { continue }
            let vf = Geometry.ax(screen.usableFrame)
            for item in strip.layout(params(screen), scroll: strip.renderScrollY, minHeights: minHeights) {
                guard let w = windows[item.id] else { continue }
                // Where it belongs, pushed inside the screen: rows above pile up at the top,
                // rows below at the bottom; the overview spreads them out.
                let r = item.frame
                let width = min(r.width, vf.width), height = min(r.height, vf.height)
                let f = CGRect(x: min(max(r.minX, vf.minX), vf.maxX - width),
                               y: min(max(r.minY, vf.minY), vf.maxY - height), width: width, height: height)
                if !w.parked, !w.shrunk, let lf = w.lastFrame, lf.approxEqual(f) { continue }
                writer.move(w.id, pid: w.pid, element: w.element, to: f, setSize: true)
                w.lastFrame = f
                w.parked = false
                w.shrunk = false
            }
        }
        // The overview captures window positions when it opens: let the moves land first.
        writer.waitUntilIdle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            open()
            self?.watchOverview()
        }
    }

    /// Waits for the overview to appear and then to close (a window picked, Esc, another
    /// double tap); gives up if it never shows.
    private func watchOverview() {
        let start = CACurrentMediaTime()
        var seen = false
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, self.overviewActive else { t.invalidate(); return }
            if SystemActions.isOverviewShowing {
                seen = true
            } else if seen || CACurrentMediaTime() - start > 1.5 {
                t.invalidate()
                self.closeOverview()
            }
        }
    }

    /// The overview is going (closed with a double tap, or a window picked in it): put the
    /// windows back as soon as its closing animation is over (~0.2 s) rather than when its
    /// window goes, half a second later, the windows standing in a pile meanwhile.
    private func overviewClosing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.closeOverview() }
    }

    /// Puts every window from where the overview left it straight back into the strip, the
    /// one picked in the overview in view: each moves once. (Sliding them back meant taking a
    /// fresh picture of each and slow apps answering late: windows landed one by one, at 10 fps.)
    private func closeOverview() {
        guard overviewActive else { return }
        overviewActive = false
        let focused = systemFocusedWindowID()
        for (key, screen) in visibleKeys() {
            guard let strip = strips[key] else { continue }
            if let id = focused, strip.contains(id) {
                let vh = viewport(screen).height
                strip.scrollY = strip.clampScroll(strip.scrollToReveal(id, viewportHeight: vh, gap: settings.gap),
                                                  viewportHeight: vh, gap: settings.gap)
                strip.focused = id
            }
            relayout(key, animated: false)
        }
    }

    // MARK: Maximize

    /// What a window filling the screen covers: the whole usable screen (below the menu bar,
    /// beside the Dock), not just the Oz zone, with the usual margin.
    private func fullScreenFrame(_ screen: NSScreen) -> CGRect {
        Geometry.ax(screen.usableFrame).insetBy(dx: settings.outerGap, dy: settings.outerGap)
    }

    /// The frontmost window on `screen` was made to fill it by its app (title bar double
    /// click, or the app's full screen), whether the strip holds it or not, and Oz didn't
    /// notice: it covers the strip, so a swipe would only move windows nobody can see. (Oz's
    /// own placements keep the outer gap, so they never reach every edge.)
    private func appFilledScreen(_ screen: NSScreen) -> Bool {
        let area = Geometry.ax(screen.visibleFrame)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let b = info[kCGWindowBounds as String] else { continue }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            guard r.intersects(area) else { continue }
            // Only the frontmost window on this screen counts.
            guard r.width >= area.width - 4 && r.height >= area.height - 4 else { return false }
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let kind = windows[wid] != nil ? "in the strip" : floating[wid] != nil ? "in a region / floating" : "not Oz's"
            Log.info("swipe ignored: \(info[kCGWindowOwnerName as String] ?? "?") fills the screen (\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)), \(kind))")
            return true
        }
        return false
    }

    /// The strip's full-screen window, if it still belongs to the strip: it may have moved to
    /// another desktop or display, or stopped being tiled, without being restored first.
    private func maximizedID(_ key: StripKey) -> CGWindowID? {
        guard let id = maximized[key] else { return nil }
        if windows[id] != nil, strips[key]?.contains(id) == true { return id }
        maximized[key] = nil
        return nil
    }

    private func isMaximized(_ id: CGWindowID) -> Bool {
        guard let (key, _) = locate(id) else { return false }
        return maximizedID(key) == id
    }

    /// Makes the window fill the screen (over the rest of its strip, which stays as it is),
    /// or puts it back in its place in the strip.
    /// `current`: where the window really is now, if not where Oz put it (its app zoomed it).
    private func setMaximized(_ id: CGWindowID, _ on: Bool, current: CGRect? = nil) {
        guard let (key, strip) = locate(id), let screen = visibleScreen(key), let w = windows[id] else { return }
        guard on != (maximizedID(key) == id) else { return }
        stopAnimation(key)
        beginTransition(key)
        if let current { pendingFrom[key]?[id] = current }
        maximizeSliding[key] = id
        if on {
            maximized[key] = id
            strip.focused = id
            writer.perform(pid: w.pid) { AX.raise(w.element) }
        } else {
            maximized[key] = nil
            strip.scrollY = strip.clampScroll(strip.scrollToReveal(id, viewportHeight: viewport(screen).height, gap: settings.gap),
                                              viewportHeight: viewport(screen).height, gap: settings.gap)
        }
        w.needsSizeCheck = false
        Log.debug("\(on ? "maximize" : "restore") \(id) \(w.appName)")
        relayout(key, animated: true)
    }

    /// Another window got focus (Dock, ⌘Tab, a click): a window filling its screen goes back
    /// into the strip.
    private func restoreMaximized(focusing w: ManagedWindow) {
        for id in appZoomed.keys where id != w.id { unzoom(id) }
        if let (key, _) = locate(w.id) {
            if let id = maximizedID(key), id != w.id { setMaximized(id, false) }
            return
        }
        guard let frame = w.lastFrame else { return }
        restoreMaximized(at: frame, except: nil)
    }

    /// The same for a window Oz doesn't manage; a dialog of the full-screen window's own app
    /// (a save panel, say) leaves it as it is.
    private func restoreMaximized(focusing el: AXUIElement, pid: pid_t) {
        guard maximized.values.contains(where: { windows[$0].map { $0.pid != pid } ?? false })
              || appZoomed.keys.contains(where: { floating[$0].map { $0.pid != pid } ?? false }) else { return }
        writer.perform(pid: pid) { [weak self] in
            guard let frame = AX.frame(el) else { return }
            DispatchQueue.main.async { self?.restoreMaximized(at: frame, except: pid) }
        }
    }

    private func restoreMaximized(at frame: CGRect, except pid: pid_t?) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for (id, before) in appZoomed {
            guard let w = floating[id] else { appZoomed[id] = nil; continue }
            guard w.pid != pid, Geometry.ax(Geometry.screen(containingAX: CGPoint(x: before.midX, y: before.midY))?.frame ?? .zero)
                .contains(center) else { continue }
            unzoom(id)
        }
        for (key, screen) in visibleKeys() where Geometry.ax(screen.frame).contains(center) {
            guard let id = maximizedID(key), let m = windows[id], m.pid != pid else { continue }
            setMaximized(id, false)
        }
    }

    /// A floating or docked window's title bar was double clicked: if its app zooms it,
    /// remember where it was; if it unzooms it, forget.
    private func floatingWindow(at p: CGPoint) -> (id: CGWindowID, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let b = info[kCGWindowBounds as String] else { continue }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            guard r.contains(p) else { continue }
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, floating[id] != nil else { return nil }
            return (id, r)
        }
        return nil
    }

    private func floatingZoomClick(_ id: CGWindowID, before: CGRect) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let w = self.floating[id] else { return }
            let element = w.element
            self.writer.perform(pid: w.pid) {
                let actual = AX.frame(element)
                DispatchQueue.main.async {
                    guard let actual, self.floating[id] != nil else { return }
                    if self.appZoomed[id] != nil {
                        // A double click near the top that didn't unzoom it (Blender's own
                        // header is there) keeps it zoomed.
                        let zoomed = self.floating[id]?.zoomedFrame ?? actual
                        if actual.width * actual.height < zoomed.width * zoomed.height - 400 * 20 {
                            self.appZoomed[id] = nil
                            Log.info("app unzoomed floating \(id)")
                        }
                    } else if actual.width * actual.height > before.width * before.height + 400 * 20 {
                        self.appZoomed[id] = before
                        self.floating[id]?.zoomedFrame = actual
                        Log.info("app zoomed floating \(id)")
                    }
                }
            }
        }
    }

    /// Puts an app-zoomed floating window back where it was, shrinking it there over
    /// `animationDuration` (a slow app just shows fewer of the steps).
    private func unzoom(_ id: CGWindowID) {
        guard let before = appZoomed.removeValue(forKey: id), let w = floating[id] else { return }
        Log.info("unzoom floating \(id) \(w.appName)")
        let duration = settings.animationDuration > 0 ? max(settings.animationDuration, 0.25) : 0
        guard duration > 0, let from = w.zoomedFrame ?? w.lastFrame, !from.approxEqual(before) else {
            dockPlacedAt[id] = CACurrentMediaTime()
            writer.move(id, pid: w.pid, element: w.element, to: before, setSize: true)
            w.lastFrame = before
            return
        }
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.floating[id] === w, self.appZoomed[id] == nil else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            let e = CGFloat(1 - pow(1 - t, 3))  // ease out
            let f = CGRect(x: from.minX + (before.minX - from.minX) * e, y: from.minY + (before.minY - from.minY) * e,
                           width: from.width + (before.width - from.width) * e,
                           height: from.height + (before.height - from.height) * e).integral
            self.dockPlacedAt[id] = CACurrentMediaTime()
            self.writer.move(id, pid: w.pid, element: w.element, to: t < 1 ? f : before, setSize: true)
            w.lastFrame = t < 1 ? f : before
            if t >= 1 { timer.invalidate() }
        }
    }

    /// A double click on a tiled window's title bar makes macOS zoom it (or minimize it,
    /// depending on the system setting). If its app does resize it, take that as
    /// "maximize / restore" instead of a new row size.
    private func titleBarDoubleClick(at p: CGPoint) {
        guard enabled, !overviewActive else { return }
        // Topmost managed window under the click whose top strip (title bar / toolbar) was hit.
        let ids = Set(windows.keys)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let hit = list.first(where: { info in
            // Our own overlays (some kept in, transparent) are never the target.
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let b = info[kCGWindowBounds as String] else { return false }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            return r.contains(p)
        }), let wid = (hit[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return }
        if floating[wid] != nil {
            if let c = clickedFloating, c.id == wid, p.y - c.frame.minY <= 56 { floatingZoomClick(wid, before: c.frame) }
            return
        }
        guard ids.contains(wid), let w = windows[wid], let frame = w.lastFrame, !w.parked,
              p.y - frame.minY <= 56, let (key, _) = locate(wid) else { return }
        zoomClick = (wid, key, frame)
        // Give the app time to zoom, then read where the window ended up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let w = self.windows[wid] else { self?.zoomClick = nil; return }
            let element = w.element
            self.writer.perform(pid: w.pid) {
                let actual = AX.frame(element)
                DispatchQueue.main.async { self.finishZoomClick(wid, actual) }
            }
        }
    }

    private func finishZoomClick(_ id: CGWindowID, _ actual: CGRect?) {
        guard let zc = zoomClick, zc.id == id else { return }
        zoomClick = nil
        guard let actual, windows[id] != nil else { return }
        let resized = abs(actual.width - zc.frame.width) > 20 || abs(actual.height - zc.frame.height) > 20
        let isMax = isMaximized(id)
        if !resized && !isMax { return }  // a double click on a toolbar button, not a zoom
        // The app moved it somewhere of its own: our next placement must really move it back.
        windows[id]?.lastFrame = actual
        setMaximized(id, !isMax, current: actual)
        if isMaximized(id) || !isMax { return }
        // Restoring: the app's own un-zoom may land after ours; place it once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let (key, _) = self.locate(id) else { return }
            self.windows[id]?.lastFrame = nil
            self.relayout(key, animated: false)
        }
    }

    private func toggleFloat(_ c: Context) {
        guard let fid = systemFocusedWindowID() else { return }
        if let w = windows[fid] {
            // Tiled -> floating: take it out and center it.
            beginTransition(c.key)
            windows.removeValue(forKey: fid)
            c.strip.remove(fid)
            floating[fid] = w
            manualFloat.insert(fid)
            let vp = viewport(c.screen)
            let size = CGSize(width: min(vp.width * 0.6, 1200), height: min(vp.height * 0.7, 900))
            let origin = CGPoint(x: vp.midX - size.width / 2, y: vp.midY - size.height / 2)
            pendingParks.removeValue(forKey: fid)?.cancel()
            overlays.hide(fid)
            writer.move(fid, pid: w.pid, element: w.element, to: CGRect(origin: origin, size: size), setSize: true)
            let element = w.element
            writer.perform(pid: w.pid) { AX.raise(element) }
            c.strip.scrollY = c.strip.clampScroll(c.strip.scrollY, viewportHeight: c.vh, gap: settings.gap)
            relayout(c.key, animated: true)
        } else if let w = floating.removeValue(forKey: fid) {
            manualFloat.remove(fid)
            undock(fid)
            beginTransition(c.key)
            windows[fid] = w
            w.lastFrame = nil
            let h = Strip.height(forRatio: settings.defaultHeight, viewportHeight: c.vh, gap: settings.gap)
            c.strip.insert(fid, height: h, anchor: c.strip.focused, position: settings.newWindowPosition)
            c.strip.focused = fid
            c.strip.scrollY = c.strip.scrollToReveal(fid, viewportHeight: c.vh, gap: settings.gap)
            relayout(c.key, animated: true)
        }
    }

    private func moveToNextScreen(_ c: Context) {
        let screens = NSScreen.screens
        guard screens.count > 1, let id = c.id, let (r, _) = c.strip.locate(id),
              let i = screens.firstIndex(of: c.screen) else { return }
        let height = c.strip.rows[r].height
        let target = screens[(i + 1) % screens.count]
        c.strip.remove(id)
        let tkey = visibleKey(for: target)
        let ts = strip(tkey)
        ts.insert(id, height: min(height, viewport(target).height), anchor: ts.focused, position: .below)
        ts.focused = id
        windows[id]?.lastFrame = nil
        relayout(c.key, animated: true)
        focus(id)
    }

    // MARK: Introspection (for the JS config)

    func info(_ w: ManagedWindow) -> [String: Any] {
        var d: [String: Any] = [
            "id": Int(w.id), "app": w.appName, "bundleId": w.bundleID ?? "", "title": w.title,
            "floating": floating[w.id] != nil,
        ]
        if let (key, strip) = locate(w.id), let (r, c) = strip.locate(w.id) {
            d["row"] = r
            d["column"] = c
            d["height"] = strip.rows[r].height
            d["focused"] = strip.focused == w.id
            d["space"] = key.space
            d["display"] = key.display
        }
        return d
    }

    func allWindowsInfo() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (_, strip) in strips {
            for id in strip.windowIDs { if let w = windows[id] { out.append(info(w)) } }
        }
        out += floating.values.map(info)
        return out
    }

    func focusedInfo() -> [String: Any]? {
        guard let id = systemFocusedWindowID(), let w = windows[id] ?? floating[id] else { return nil }
        return info(w)
    }
}

extension CGRect {
    /// The rect `t` of the way (0...1) to `o`, on whole points.
    func interpolated(to o: CGRect, _ t: CGFloat) -> CGRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * t).rounded() }
        return CGRect(x: mix(minX, o.minX), y: mix(minY, o.minY), width: mix(width, o.width), height: mix(height, o.height))
    }

    func approxEqual(_ o: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}
