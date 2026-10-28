import Accelerate
import Cocoa
import QuartzCore

@_silgen_name("CGSHWCaptureWindowList")
private func CGSHWCaptureWindowList(_ cid: Int32, _ windows: UnsafeMutablePointer<UInt32>,
                                    _ count: UInt32, _ options: UInt32) -> CFArray?

/// Captures a window's own content, including the parts that are off screen (our parked
/// windows live almost entirely off screen). This is the private SkyLight call AltTab uses
/// for thumbnails: unlike ScreenCaptureKit it does not turn on the purple screen-recording
/// indicator in the menu bar. Still needs the Screen Recording permission.
enum WindowCapture {
    private static let ignoreClipShape: UInt32 = 1 << 11
    private static let fullWindow: UInt32 = 1 << 15
    /// One pixel per point instead of the Retina backing (a quarter of the pixels).
    private static let nominalResolution: UInt32 = 1 << 9

    /// A window-server connection of our own for capturing. A capture holds its connection's
    /// lock for its whole duration; on the main connection that blocked the main thread's
    /// Core Animation commits (measured: 0.5 s stalls, and a hitch on every live-peek frame).
    private static let connection: Int32 = {
        typealias NewConnection = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32
        if let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
           let sym = dlsym(sky, "SLSNewConnection") {
            var cid: Int32 = 0
            if unsafeBitCast(sym, to: NewConnection.self)(0, &cid) == 0, cid != 0 { return cid }
        }
        return Spaces.connection
    }()

    /// The window at `scale` of its own resolution (1: every pixel it has, lossless; the
    /// `captureScale` setting), and the size in points it shows. `expected`: the size the
    /// window should have, to tell its backing scale when screens differ. ~16 ms at full
    /// resolution; call it off the main thread.
    static func image(_ id: CGWindowID, scale: CGFloat, expected: CGSize = .zero) -> (image: CGImage, points: CGSize)? {
        let s = min(max(scale, 0.1), 1)
        let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        // When one pixel per point is enough, the window server captures that small itself
        // (a quarter of the work on Retina); otherwise at full resolution, scaled down after.
        let nominal = backing * s <= 1.001
        var wid = id
        let options = ignoreClipShape | fullWindow | (nominal ? nominalResolution : 0)
        guard let raw = (CGSHWCaptureWindowList(connection, &wid, 1, options) as? [CGImage])?.first else { return nil }
        let points = nominal ? CGSize(width: raw.width, height: raw.height) : pointSize(of: raw, near: expected)
        let factor = nominal ? backing * s : s
        return (factor >= 0.999 ? raw : downscaled(raw, by: factor) ?? raw, points)
    }

    /// The window at its full resolution with its shadow around it, as the window server
    /// draws it on screen (nil, or without the shadow, while it is off screen).
    static func withShadow(_ id: CGWindowID) -> CGImage? {
        var wid = id
        return (CGSHWCaptureWindowList(connection, &wid, 1, 1) as? [CGImage])?.first
    }

    /// The window size (points) a full-resolution capture shows: its pixels over the backing
    /// scale, which is the screens' common one, or else the whole number closest to pixels /
    /// expected points.
    static func pointSize(of image: CGImage, near expected: CGSize) -> CGSize {
        let scales = Set(NSScreen.screens.map(\.backingScaleFactor))
        var scale = scales.count == 1 ? scales.first! : 0
        if scale == 0 {
            scale = expected.width > 0 ? max(1, (CGFloat(image.width) / expected.width).rounded()) : 2
        }
        return CGSize(width: (CGFloat(image.width) / scale).rounded(), height: (CGFloat(image.height) / scale).rounded())
    }

    /// `image` at `factor` of its size, in the capture's own pixel format (the live colour
    /// correction works on that).
    private static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let cs = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// macOS refuses to put a window above the menu bar, so a row can't really
/// scroll off the top edge. While the strip is moving we instead hide the real
/// window and draw a snapshot of it in our own borderless window, clipped at
/// the top edge, so it looks like it slides off just like at the bottom.
/// Snapshots of windows that are sliding off the top edge. Captures happen only on
/// demand, the moment a window starts to peek, so macOS's screen-recording indicator
/// stays off the rest of the time. The capture reads the window's own content whatever
/// its position, so a window can be captured while moving or parked off screen, as
/// long as it has its real (unshrunk) size.
final class SnapshotCache {
    private struct Entry {
        let image: CGImage
        let size: CGSize
        let time: CFTimeInterval
        /// Taken while the window was on screen. A parked (off-screen) window loses the
        /// wallpaper tint macOS gives window backgrounds, so its capture looks greyer.
        let onScreen: Bool
    }
    private var entries: [CGWindowID: Entry] = [:]
    private var inFlight = Set<CGWindowID>()
    private var failedAt: [CGWindowID: CFTimeInterval] = [:]
    private var requestedPermission = false
    private let queue = DispatchQueue(label: "oz.snapshots", qos: .userInteractive)
    /// Capture resolution (the `captureScale` setting). Snapshots already taken keep theirs.
    var scale: CGFloat = 1

    /// Main thread: a requested snapshot is ready.
    var onReady: ((CGWindowID) -> Void)?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermissionOnce() {
        guard !requestedPermission, !SnapshotCache.hasPermission else { return }
        requestedPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// Latest snapshot, but only if it shows the window at this size. A window taller than
    /// asked (its app has a minimum height) still matches: the extra height is cropped.
    func image(_ id: CGWindowID, size: CGSize) -> CGImage? {
        guard let e = entries[id], abs(e.size.width - size.width) <= 3,
              e.size.height >= size.height - 3 else { return nil }
        return e.image
    }

    /// Latest snapshot whatever size it was taken at.
    func latestImage(_ id: CGWindowID) -> CGImage? { entries[id]?.image }

    /// The latest snapshot has the window's true on-screen colours.
    func isOnScreenCapture(_ id: CGWindowID) -> Bool { entries[id]?.onScreen ?? false }

    func age(_ id: CGWindowID) -> CFTimeInterval {
        entries[id].map { CACurrentMediaTime() - $0.time } ?? .infinity
    }

    func isCapturing(_ id: CGWindowID) -> Bool { inFlight.contains(id) }

    func remove(_ id: CGWindowID) {
        entries.removeValue(forKey: id)
        failedAt.removeValue(forKey: id)
    }

    /// Forgets capture failures older than a minute (the window may be capturable again).
    func forgetOldFailures() {
        let now = CACurrentMediaTime()
        for (id, t) in failedAt where now - t > 60 { failedAt.removeValue(forKey: id) }
    }

    func clear() { entries.removeAll() }

    /// Captures the window now (in the background, ~20 ms) at the given point size.
    func capture(_ id: CGWindowID, size: CGSize, onScreen: Bool) {
        guard SnapshotCache.hasPermission, !inFlight.contains(id),
              CACurrentMediaTime() - (failedAt[id] ?? 0) > 1 else { return }
        inFlight.insert(id)
        let scale = self.scale
        queue.async { [weak self] in
            var shot = WindowCapture.image(id, scale: scale, expected: size)
            if let s = shot, SnapshotCache.isBlank(s.image) { shot = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                guard let (image, actual) = shot else {
                    // Don't retry every frame (each attempt lights the recording indicator).
                    self.failedAt[id] = CACurrentMediaTime()
                    Log.debug("snapshot \(id) unusable")
                    return
                }
                // Filed under the size the window really had, not the one asked for: an app slow
                // to take a new size (or refusing it) was captured at its old one, and that
                // picture, fitted to the new frame, came out shrunk with gaps around it.
                if abs(actual.width - size.width) > 4 || abs(actual.height - size.height) > 4 {
                    Log.debug("snapshot \(id) is \(Int(actual.width))x\(Int(actual.height)), not \(Int(size.width))x\(Int(size.height))")
                }
                self.entries[id] = Entry(image: image, size: actual, time: CACurrentMediaTime(), onScreen: onScreen)
                self.onReady?(id)
            }
        }
    }

    /// Fingerprint of a frame's pixels, to tell whether two frames differ: every fourth row of
    /// its bytes folded together (a line of text spans 24+ rows on Retina). A few characters of
    /// new text count; an 8x8 thumbnail, sampling 64 points, missed them, so a terminal
    /// printing looked idle and its live peek froze. ~3 ms for a large window, off the main thread.
    static func signature(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let row = image.bytesPerRow, length = CFDataGetLength(data)
        let words = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt64.self)
        let perRow = row / 8, prime: UInt64 = 1_099_511_628_211
        // Four independent lanes: the multiplications don't wait on each other.
        var l0: UInt64 = 14_695_981_039_346_656_037, l1 = l0 &+ 1, l2 = l0 &+ 2, l3 = l0 &+ 3
        for y in stride(from: 0, to: image.height, by: 4) where (y + 1) * row <= length {
            let base = y * perRow
            var i = 0
            while i + 4 <= perRow {
                l0 = (l0 ^ words[base + i]) &* prime
                l1 = (l1 ^ words[base + i + 1]) &* prime
                l2 = (l2 ^ words[base + i + 2]) &* prime
                l3 = (l3 ^ words[base + i + 3]) &* prime
                i += 4
            }
            while i < perRow { l0 = (l0 ^ words[base + i]) &* prime; i += 1 }
        }
        return Int(truncatingIfNeeded: l0 ^ (l1 &* 3) ^ (l2 &* 5) ^ (l3 &* 7))
    }

    /// True if the image is (almost) fully transparent.
    private static func isBlank(_ image: CGImage) -> Bool {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var alpha = 0
        for i in stride(from: 3, to: pixels.count, by: 4) { alpha += Int(pixels[i]) }
        return alpha < n * n * 255 / 4
    }
}

/// Re-captures a (parked) window at a fixed frame rate, so a peeking window keeps
/// playing video, scrolling text, etc. instead of showing a still.
final class LiveMirror {
    let id: CGWindowID
    /// Main thread: (frame, signature for change detection). The frame is nil when the
    /// window hasn't changed since the last one (nothing to correct or draw).
    var onFrame: ((CGImage?, Int) -> Void)?
    private let fps: Double
    private let scale: CGFloat
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var reference: [UInt8]?
    private var bias: [Int16]?
    /// Frames since the colour shift was last measured, and whether a clear reading exists.
    private var sinceMeasure = 0
    private var measured = false
    /// Signature of the last captured frame as captured (before any colour correction).
    private var lastRaw: Int?

    /// True-colour snapshot of the window: every frame's colours are measured against it
    /// and corrected (see ColorShift) before delivery.
    func setReference(_ image: CGImage?) {
        let grid = image.flatMap(ColorShift.grid)
        lock.lock(); reference = grid; lock.unlock()
    }
    private static let queue = DispatchQueue(label: "oz.mirror", qos: .userInteractive)

    init(id: CGWindowID, fps: Double, scale: CGFloat) {
        self.id = id
        self.fps = min(max(fps, 1), 60)
        self.scale = scale
    }

    func start() {
        let id = self.id, scale = self.scale
        let t = DispatchSource.makeTimerSource(queue: LiveMirror.queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(4))
        // Frames never pile up: the handler runs serially and skips ticks while busy.
        let measureEvery = Int(fps * 2)
        t.setEventHandler { [weak self] in
            guard var image = WindowCapture.image(id, scale: scale)?.image else { return }
            // Unchanged since the last frame (most of the time, for anything but video): skip
            // the colour work and the redraw, just report it so an idle stream can stop.
            let raw = SnapshotCache.signature(image)
            if let self, raw == self.lastRaw {
                DispatchQueue.main.async { self.onFrame?(nil, raw) }
                return
            }
            self?.lastRaw = raw
            if let self {
                self.lock.lock(); let ref = self.reference; self.lock.unlock()
                // Measured until there is a clear reading (the window parks a moment after
                // streaming starts, and only a parked window loses its tint), then every 2 s
                // rather than every frame. Unclear readings (the content itself changed a
                // lot) keep the previous correction. With wallpaper tinting off (Oz turns
                // it off) there is usually no shift, and nothing is corrected at all.
                self.sinceMeasure += 1
                if let ref, !self.measured || self.sinceMeasure >= measureEvery, let grid = ColorShift.grid(image) {
                    self.sinceMeasure = 0
                    switch ColorShift.measure(reference: ref, frame: grid) {
                    case .shift(let s): self.bias = s; self.measured = true
                    case .none: self.bias = nil; self.measured = true
                    case .unclear: break
                    }
                }
                if let b = self.bias, let corrected = ColorShift.apply(b, to: image) { image = corrected }
            }
            let frame = image
            DispatchQueue.main.async { self?.onFrame?(frame, raw) }
        }
        t.resume()
        timer = t
        Log.debug("live mirror \(id) started at \(Int(fps)) fps")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onFrame = nil
    }
}

/// The wallpaper tint a window loses while parked off screen is, in practice, a small constant
/// shift of the encoded channel values (measured on Finder: R -1, G +4, B +5). We measure it
/// once per stream (true-colour snapshot vs first parked frame) and add it back to every frame.
enum ColorShift {
    enum Reading { case shift([Int16]), none, unclear }

    /// Median per-channel difference `reference - frame` in the frames' byte order (B, G, R, A),
    /// accepted only when most of the window agrees on it: a uniform tint, not new content.
    static func measure(reference a: [UInt8], frame b: [UInt8]) -> Reading {
        guard a.count == b.count, !a.isEmpty else { return .unclear }
        var shift: [Int16] = []
        for c in 0..<3 {
            var d: [Int] = []
            for i in stride(from: c, to: a.count, by: 4) { d.append(Int(a[i]) - Int(b[i])) }
            d.sort()
            let median = d[d.count / 2]
            let agreeing = d.filter { abs($0 - median) <= 1 }.count
            guard agreeing * 10 >= d.count * 6, abs(median) <= 16 else { return .unclear }
            shift.append(Int16(median))
        }
        return shift.contains(where: { abs($0) >= 2 }) ? .shift(shift + [0]) : .none
    }

    /// Adds `bias` to every pixel (saturating), keeping the image's format and colour space.
    /// One table lookup per byte, in the frame's own byte order: the matrix multiply used
    /// before went through 16-bit planar copies and (un)premultiplying, several times the work.
    static func apply(_ bias: [Int16], to image: CGImage) -> CGImage? {
        guard bias.count == 4, image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let format = vImage_CGImageFormat(cgImage: image),
              var buffer = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { buffer.free() }
        let tables = bias.map { b in (0..<256).map { Pixel_8(clamping: $0 + Int(b)) } }
        let err = vImageTableLookUp_ARGB8888(&buffer, &buffer, tables[0], tables[1], tables[2], tables[3],
                                             vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        return try? buffer.createCGImage(format: format)
    }

    /// 32x32 thumbnail in the image's own byte layout (no colour conversion).
    static func grid(_ image: CGImage) -> [UInt8]? {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cs = image.colorSpace,
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return px
    }
}

/// A stand-in's window: always exactly where it is put. AppKit otherwise pushes a window
/// that reaches into the menu bar down below it: the picture jumped down, then slid back as
/// it faded (a flicker).
final class StandInPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A window with a title bar, which doesn't show: macOS gives it the shadow real windows
    /// have. A borderless one gets a smaller, lighter one, and a stand-in's shadow shrank and
    /// grew as the strip moved off the real window and back.
    static func titled(contentRect: NSRect) -> StandInPanel {
        let p = StandInPanel(contentRect: contentRect, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        p.isMovable = false
        return p
    }
}

/// The board's content: a click (not a press that turns into a drag) on it.
private final class BoardView: NSView {
    var onClick: ((CGPoint) -> Void)?
    private var downAt: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard let d = downAt else { return }
        let p = event.locationInWindow
        if hypot(p.x - d.x, p.y - d.y) <= 4 { onClick?(convert(p, from: nil)) }
    }
}

/// Click target for a peeking window: clicking the visible strip brings the real window back.
/// A click, not a press: acting on mouse down started scrolling while the button was still
/// held, and a press that turns into a drag isn't a click.
private final class PeekView: NSView {
    var onClick: (() -> Void)?
    private var downAt: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = NSEvent.mouseLocation }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard let d = downAt else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - d.x, p.y - d.y) <= 4 { onClick?() }
    }
}

/// One transparent window over a whole screen that every stand-in is drawn into while the
/// strip moves: each frame moves layers inside it, in one Core Animation commit, instead of
/// moving one window per stand-in (each a separate trip to the window server, so they didn't
/// all land in the same frame). It follows the Space you are on and stays out of Mission
/// Control (`.transient`). While it holds pictures it takes clicks on them (a picture still up
/// after a scroll is the window as far as the user can tell; let through, the click hit the
/// desktop behind and macOS took it for "show desktop"); its transparent rest lets clicks
/// through to whatever is below.
private final class Board {
    let window: StandInPanel
    let root: CALayer
    let displayID: CGDirectDisplayID
    /// The window it was last ordered just below (a window being dragged), if any.
    var orderedBelow: CGWindowID?
    var ordered = false
    /// A click at this point (the board's layer coordinates).
    var onClick: ((CGPoint) -> Void)? {
        get { (window.contentView as? BoardView)?.onClick }
        set { (window.contentView as? BoardView)?.onClick = newValue }
    }

    init(screen: NSScreen) {
        displayID = Geometry.displayID(screen)
        screenFrame = screen.frame
        window = StandInPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // No window shadow: worked out again from the whole board every frame, it lagged the
        // pictures and flickered. Each picture has macOS's shadow drawn under it instead.
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        let view = BoardView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        root = view.layer!
        // The layers keep the screen's coordinates whatever size the window is.
        view.autoresizingMask = []
        cover(false)
    }

    /// The screen it covers while it draws (AppKit coordinates).
    let screenFrame: NSRect

    /// `r` (AX coordinates) in the board's layer coordinates.
    func local(_ r: CGRect) -> CGRect {
        let f = Geometry.ax(screenFrame)
        return CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Over the whole screen while it draws, a pixel in a corner while it holds nothing:
    /// even transparent and click-through, a window over the wallpaper made macOS stop taking
    /// a click on the wallpaper for one (no more "click wallpaper to reveal desktop").
    func cover(_ on: Bool) {
        let frame = on ? screenFrame : NSRect(x: screenFrame.minX, y: screenFrame.minY, width: 1, height: 1)
        if window.ignoresMouseEvents == on { window.ignoresMouseEvents = !on }
        guard window.frame != frame else { return }
        window.setFrame(frame, display: false)
    }

    var isEmpty: Bool { root.sublayers?.isEmpty ?? true }

    /// In front of the windows (or just below one being dragged). `again`: windows may have
    /// come forward since (an app activated), so order it even if nothing changed.
    func order(below: CGWindowID?, again: Bool = false) {
        guard again || !ordered || orderedBelow != below else { return }
        if let below {
            window.order(.below, relativeTo: Int(below))
        } else {
            window.orderFrontRegardless()
        }
        ordered = true
        orderedBelow = below
    }
}

final class OverlayManager {
    /// Called with the window id when the user clicks a peeking window.
    var onClick: ((CGWindowID) -> Void)?
    /// Stream live content into peeks instead of showing a still snapshot.
    var live = true
    var liveFPS = 24.0
    /// Resolution of live frames (the `captureScale` setting).
    var captureScale: CGFloat = 1

    /// A window's stand-in: its picture, drawn either in a window of its own (at rest, where
    /// it takes clicks) or on its screen's board (while things move). Both hold a layer with
    /// the same picture, so moving from one to the other never leaves a frame without it.
    private final class Overlay {
        let id: CGWindowID
        let window: NSPanel
        let imageLayer = CALayer()
        /// The same picture on a board: a clipping layer (the visible part) holding it, over
        /// its shadow, both in one layer.
        let boardItem = CALayer()
        let boardClip = CALayer()
        let boardImage = CALayer()
        let boardShadow = CALayer()
        /// The shadow made for the picture's shape and size, and the one being made.
        var shadow: ShadowMaker.Shadow?
        var shadowWanted: ShadowMaker.Key?
        /// The shape worked out for pictures of this size (a window's corners don't change;
        /// working it out again for every live frame cost a hitch).
        var shapeKey: (size: CGSize, key: ShadowMaker.Key)?
        var image: CGImage?
        var mirror: LiveMirror?
        /// Set once live frames arrive; the still snapshot is no longer drawn.
        var isLive = false
        /// The mirror was stopped because nothing changed; the last frame stays up.
        var mirrorIdle = false
        var lastSignature: Int?
        var unchangedFrames = 0
        /// Row size the stand-in represents (the window may be taller if the app refused).
        var expectedSize = CGSize.zero
        /// Where the whole window lies in the visible part shown (its own coordinates, y up):
        /// the part outside is cut off.
        var contentFrame = CGRect.zero
        /// Drawn and clickable. A hidden overlay stays ordered in, transparent and click-through:
        /// taking a window off screen (`orderOut`) and back is a window-server round trip that
        /// stalled the main thread for up to half a second, many times per swipe.
        var shown = false
        /// Drawn in its own window (at rest), or on this board (moving).
        var inWindow = false
        var board: Board?
        /// The window it was last ordered just below (a window being dragged), if any.
        var orderedBelow: CGWindowID?
        var fading = false
        /// The real window is right under it with its own shadow (not parked yet, or back):
        /// the stand-in has none, or the two would darken each other.
        var realBelow = false
        /// Snapshot with true on-screen colours, to calibrate the live stream against.
        var reference: CGImage?

        init(id: CGWindowID) {
            self.id = id
            window = StandInPanel.titled(contentRect: .zero)
            window.isOpaque = false
            window.backgroundColor = .clear
            // macOS's own window shadow, the one real windows have (`StandInPanel.titled`).
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.alphaValue = 0
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            // Not .transient: that would make it follow you to other Spaces. It belongs to the
            // Space of the strip it stands in for, so switching away and back needs no redraw.
            window.collectionBehavior = [.ignoresCycle, .fullScreenNone]
            let view = PeekView()
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            for layer in [imageLayer, boardImage] {
                layer.contentsGravity = .resize
                layer.actions = still
            }
            boardClip.masksToBounds = true
            for layer in [boardItem, boardClip, boardShadow] {
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "contents": NSNull()]
            }
            boardClip.addSublayer(boardImage)
            boardItem.addSublayer(boardShadow)
            boardItem.addSublayer(boardClip)
            view.layer?.addSublayer(imageLayer)
            window.contentView = view
        }

        /// The picture changed since the window shadow was last worked out.
        var shadowStale = true

        func setImage(_ image: CGImage?) {
            if (image?.width, image?.height) != (self.image?.width, self.image?.height) { shadowStale = true }
            self.image = image
            imageLayer.contents = image
            boardImage.contents = image
        }
    }

    private var overlays: [CGWindowID: Overlay] = [:]
    private var pendingHide: [CGWindowID: DispatchWorkItem] = [:]
    private var boards: [CGDirectDisplayID: Board] = [:]

    private func board(for r: CGRect) -> Board? {
        guard let screen = Geometry.screen(containingAX: CGPoint(x: r.midX, y: r.midY)) else { return nil }
        let id = Geometry.displayID(screen)
        if let b = boards[id], b.screenFrame == screen.frame { return b }
        boards[id]?.window.orderOut(nil)
        let b = Board(screen: screen)
        b.onClick = { [weak self, weak b] p in
            guard let self, let b else { return }
            // The topmost picture there, as clicking that window.
            let hit = self.overlays.first { _, o in
                o.board === b && o.shown && o.boardItem.superlayer != nil && o.boardItem.frame.contains(p)
            }
            if let (id, _) = hit { self.onClick?(id) }
        }
        boards[id] = b
        return b
    }

    /// Shows `image` as if the window were at `full` (AX coordinates), cut off above `clipTop`
    /// and below `clipBottom`. Also used as a stand-in for a whole window (a slow app's window
    /// while scrolling): then `full` lies between the two and nothing is cut off.
    /// `stream`: keep it live (if live peeks are on); stand-ins during a scroll don't.
    /// `moving`: drawn on the screen's board, in step with every other stand-in; at rest in
    /// a window of its own, which takes clicks.
    /// `below`: a window being dragged, which must stay on top of the stand-ins.
    func show(_ id: CGWindowID, image: CGImage, full: CGRect, clipTop: CGFloat,
              clipBottom: CGFloat = .greatestFiniteMagnitude, trueColor: Bool = false,
              stream: Bool = true, moving: Bool = false, below: CGWindowID? = nil) {
        if let o = overlays[id], o.fading {
            // Shown again while fading out: replace the running fade, or it would carry on to
            // zero and leave the stand-in invisible over a parked window (the window "vanished").
            o.fading = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                o.window.animator().alphaValue = o.inWindow ? 1 : 0
            }
            o.window.alphaValue = o.inWindow ? 1 : 0
            o.boardItem.removeAllAnimations()
            o.boardItem.opacity = 1
        }
        let top = max(clipTop, full.minY)
        let bottom = min(clipBottom, full.maxY)
        guard bottom - top > 0 else { return hide(id) }
        pendingHide.removeValue(forKey: id)?.cancel()
        let o: Overlay
        if let existing = overlays[id] {
            o = existing
        } else {
            o = Overlay(id: id)
            (o.window.contentView as? PeekView)?.onClick = { [weak self] in self?.onClick?(id) }
            overlays[id] = o
        }
        o.expectedSize = full.size
        if trueColor && o.reference == nil { o.reference = image }
        if live && stream && o.mirror == nil && !o.mirrorIdle { startMirror(o, id: id) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !o.isLive && o.image !== image { o.setImage(image) }
        o.shown = true
        place(o, full: full, top: top, bottom: bottom, onBoard: moving, below: below)
        CATransaction.commit()
    }

    /// Streams the window into the overlay. After ~2 s of identical frames (nothing
    /// playing) the stream stops and the last frame stays, so the screen-recording
    /// indicator goes away; `wake` restarts it on the next swipe.
    private func startMirror(_ o: Overlay, id: CGWindowID) {
        let mirror = LiveMirror(id: id, fps: liveFPS, scale: captureScale)
        let idleLimit = Int(liveFPS * 2)
        mirror.setReference(o.reference)
        mirror.onFrame = { [weak o] image, signature in
            guard let o, o.shown else { return }
            guard let image, signature != o.lastSignature else {
                o.unchangedFrames += 1
                if o.unchangedFrames >= idleLimit {
                    Log.debug("live mirror \(id) idle, stopping")
                    o.mirror?.stop()
                    o.mirror = nil
                    o.mirrorIdle = true
                }
                return
            }
            o.lastSignature = signature
            o.unchangedFrames = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            o.setImage(image)
            OverlayManager.layoutImage(o)
            CATransaction.commit()
            o.isLive = true
        }
        o.mirror = mirror
        mirror.start()
    }

    /// Fills the window's frame with the picture, top-left aligned, cropping what sticks out:
    /// a picture of the right size fits exactly; one taken at another size (a stale stand-in,
    /// a window taller than asked) is cropped rather than shrunk, so there are never gaps
    /// around it or tiny text.
    private static func layoutImage(_ o: Overlay) {
        guard let image = o.image, image.width > 0, image.height > 0 else { return }
        let row = o.contentFrame
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(row.width / iw, row.height / ih)
        let w = (iw * scale).rounded(), h = (ih * scale).rounded()
        let frame = CGRect(x: row.minX, y: row.maxY - h, width: w, height: h)
        o.imageLayer.frame = frame
        o.boardImage.frame = frame
    }

    /// Draws the visible part (`top`...`bottom`) of a window at `full` (AX coordinates): on
    /// its screen's board, or in its own window. Switching from the board to the window, the
    /// board's copy goes a moment after the window shows, so no frame is without it. In a
    /// Core Animation transaction.
    private func place(_ o: Overlay, full: CGRect, top: CGFloat, bottom: CGFloat, onBoard: Bool, below: CGWindowID?) {
        o.contentFrame = CGRect(x: 0, y: bottom - full.maxY, width: full.width, height: full.height)
        OverlayManager.layoutImage(o)
        let visible = CGRect(x: full.minX, y: top, width: full.width, height: bottom - top)
        if onBoard, let b = board(for: visible) {
            // The first stand-in of a motion: bring the board forward again.
            let first = b.root.sublayers?.isEmpty ?? true
            if o.board !== b {
                o.boardItem.removeFromSuperlayer()
                b.root.addSublayer(o.boardItem)
                o.board = b
            }
            o.boardItem.opacity = 1
            o.boardShadow.isHidden = o.realBelow
            o.boardImage.contentsScale = b.window.backingScaleFactor
            o.boardItem.frame = b.local(visible)
            o.boardClip.frame = o.boardItem.bounds
            placeShadow(o)
            if first { b.cover(true) }
            b.order(below: below, again: first)
            if o.inWindow {
                // Moving on: the window's copy goes (the board's is already up, this commit).
                o.inWindow = false
                o.window.alphaValue = 0
                o.window.ignoresMouseEvents = true
            }
            return
        }
        o.imageLayer.contentsScale = o.window.backingScaleFactor
        // Layer-backed content: no need to force a synchronous redraw every frame.
        let frame = NSRect(x: full.minX, y: Geometry.primaryHeight - bottom, width: full.width, height: bottom - top)
        if o.window.frame.size != frame.size { o.shadowStale = true }
        o.window.setFrame(frame, display: false)
        if o.window.hasShadow == o.realBelow { o.window.hasShadow = !o.realBelow }
        if o.shadowStale || !o.inWindow {
            // Worked out once this commit is out (from an empty window it would stay missing).
            o.shadowStale = false
            DispatchQueue.main.async { [weak o] in o?.window.invalidateShadow() }
        }
        if !o.inWindow {
            o.inWindow = true
            o.window.alphaValue = 1
            // Takes clicks: at rest a stand-in is the window as far as the user can tell.
            o.window.ignoresMouseEvents = false
            o.orderedBelow = nil
            if let below {
                o.window.order(.below, relativeTo: Int(below))
            } else {
                o.window.orderFrontRegardless()
            }
            o.orderedBelow = below
            if o.board != nil {
                // The window takes a frame or so to show: the board's copy stays until then,
                // but not its shadow, which would darken the window's own one (twice over).
                o.boardShadow.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak o] in
                    guard let o, o.inWindow else { return }
                    let b = o.board
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    o.boardItem.removeFromSuperlayer()
                    CATransaction.commit()
                    o.board = nil
                    if let b, b.isEmpty { b.cover(false) }
                }
            }
        } else if let below, o.orderedBelow != below {
            // Already showing when a drag started: tuck it under the dragged window once.
            o.window.order(.below, relativeTo: Int(below))
            o.orderedBelow = below
        }
    }

    private let shadows = ShadowMaker()
    /// Whether a window is the key window, which macOS gives a bigger, darker shadow.
    var isKey: ((CGWindowID) -> Bool)?

    /// The picture's shadow on the board: macOS's own, made for its shape (once per shape and
    /// size), stretched around the visible part.
    private func placeShadow(_ o: Overlay) {
        guard let image = o.image, o.expectedSize.width > 0 else { return }
        let size = CGSize(width: image.width, height: image.height)
        let key: ShadowMaker.Key
        if let k = o.shapeKey, k.size == size {
            key = k.key
        } else {
            key = ShadowMaker.Key(image: image, scale: CGFloat(image.width) / o.expectedSize.width)
            o.shapeKey = (size, key)
        }
        if o.shadow?.key != key && o.shadowWanted != key {
            o.shadowWanted = key
            shadows.make(key, from: image) { [weak self, weak o] shadow in
                guard let o, o.shadowWanted == key else { return }
                o.shadowWanted = nil
                o.shadow = shadow
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.placeShadow(o)
                CATransaction.commit()
            }
        }
        var active: ShadowMaker.Shadow?
        if isKey?(o.id) == true {
            active = shadows.active(key)
            if active == nil {
                shadows.takeActive(key, window: o.id, size: o.expectedSize, image: image) { [weak self, weak o] _ in
                    guard let o, o.boardItem.superlayer != nil else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self?.placeShadow(o)
                    CATransaction.commit()
                }
            }
        }
        guard let shadow = active ?? o.shadow else { return }
        let b = o.boardItem.bounds
        o.boardShadow.contents = shadow.image
        o.boardShadow.contentsScale = shadow.scale
        o.boardShadow.contentsCenter = shadow.center
        o.boardShadow.frame = CGRect(x: -shadow.left, y: -shadow.bottom, width: b.width + shadow.left + shadow.right,
                                     height: b.height + shadow.top + shadow.bottom)
    }

    /// Stops every live stream but keeps the stand-ins (with their last frame) in place, e.g.
    /// when switching Spaces. The next layout of a visible strip starts its streams again.
    func pauseMirrors() {
        for o in overlays.values {
            o.mirror?.stop()
            o.mirror = nil
            o.mirrorIdle = false
            o.unchangedFrames = 0
        }
    }

    /// Turns live peeks on or off for the overlays already showing too. Off: each keeps the
    /// picture it has and nothing is captured any more (no recording indicator).
    func setLive(_ on: Bool) {
        live = on
        if on {
            for (id, o) in overlays where o.shown && o.mirror == nil {
                o.mirrorIdle = false
                o.unchangedFrames = 0
                startMirror(o, id: id)
            }
        } else {
            pauseMirrors()
        }
    }

    /// Restart idle live mirrors (the user is interacting again).
    func wake() {
        for (id, o) in overlays where o.mirrorIdle && o.shown {
            o.mirrorIdle = false
            o.unchangedFrames = 0
            if live { startMirror(o, id: id) }
        }
    }

    /// The real window is coming back at `frame`: keep the stand-in on top of it, unclipped,
    /// for a moment so there is no blank frame while the window server catches up. It stays
    /// where it is drawn (board or window).
    func handoff(_ id: CGWindowID, to frame: CGRect, delay: TimeInterval = 0.12) {
        guard let o = overlays[id], o.shown else { return }
        o.expectedSize = frame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(o, full: frame, top: frame.minY, bottom: frame.maxY, onBoard: !o.inWindow, below: o.orderedBelow)
        CATransaction.commit()
        if o.inWindow { o.window.display() }
        guard pendingHide[id] == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.fadeOut(id) }
        pendingHide[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Whether the real window is right under the stand-in (see `Overlay.realBelow`).
    func setRealBelow(_ id: CGWindowID, _ on: Bool) {
        guard let o = overlays[id], o.realBelow != on else { return }
        o.realBelow = on
        guard !o.inWindow else {
            o.window.hasShadow = !on && !o.fading
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        o.boardShadow.isHidden = on || o.fading
        CATransaction.commit()
    }

    /// Hands over to the real window with a short cross-fade: macOS tints window
    /// backgrounds with the wallpaper colour, which a capture can't fully reproduce, so a
    /// hard cut would show a small colour jump.
    func fadeOut(_ id: CGWindowID, duration: TimeInterval = 0.18) {
        pendingHide.removeValue(forKey: id)?.cancel()
        guard let o = overlays[id], o.shown else { return }
        stopLive(o, keepImage: true)
        o.fading = true
        // The real window is up underneath with its own shadow; the stand-in's on top of it
        // would darken it while fading.
        o.window.hasShadow = false
        o.boardShadow.isHidden = true
        let done = { [weak self] in
            guard o.fading else { return }  // shown again meanwhile
            o.fading = false
            o.shown = false
            self?.release(o)
        }
        if o.inWindow {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                o.window.animator().alphaValue = 0
            }, completionHandler: done)
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock(done)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            o.boardItem.add(fade, forKey: "fade")
            o.boardItem.opacity = 0
            CATransaction.commit()
        }
    }

    /// Image currently shown for this window (latest live frame or the snapshot).
    func currentImage(_ id: CGWindowID) -> CGImage? { overlays[id]?.image }

    func hide(_ id: CGWindowID) {
        pendingHide.removeValue(forKey: id)?.cancel()
        guard let o = overlays[id], o.shown || o.fading else { return }
        o.fading = false
        o.shown = false
        stopLive(o)
        release(o)
    }

    private func stopLive(_ o: Overlay, keepImage: Bool = false) {
        o.mirror?.stop()
        o.mirror = nil
        o.reference = nil
        o.isLive = false
        o.mirrorIdle = false
        o.unchangedFrames = 0
        o.lastSignature = nil
        if !keepImage { o.image = nil }
    }

    /// A hidden overlay holds nothing: off its board, and its window (still ordered in, see
    /// `Overlay.shown`) transparent, click-through and 1x1, so its backing store shrinks too.
    private func release(_ o: Overlay) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        o.boardItem.removeAllAnimations()
        o.boardItem.removeFromSuperlayer()
        o.boardItem.opacity = 1
        o.setImage(nil)
        CATransaction.commit()
        if let b = o.board, b.isEmpty { b.cover(false) }
        o.board = nil
        o.realBelow = false
        if o.inWindow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                o.window.animator().alphaValue = 0
            }
        }
        o.inWindow = false
        o.window.alphaValue = 0
        o.window.ignoresMouseEvents = true
        o.window.setFrame(NSRect(x: o.window.frame.minX, y: o.window.frame.minY, width: 1, height: 1), display: false)
    }

    func isShowing(_ id: CGWindowID) -> Bool {
        overlays[id]?.shown ?? false
    }

    func remove(_ id: CGWindowID) {
        guard let o = overlays.removeValue(forKey: id) else { return }
        pendingHide.removeValue(forKey: id)?.cancel()
        stopLive(o)
        o.boardItem.removeFromSuperlayer()
        if let b = o.board, b.isEmpty { b.cover(false) }
        o.window.orderOut(nil)
    }

    /// Hides every overlay and really takes them off screen: before Mission Control (it would
    /// show the transparent ones) and on quit.
    func hideAll() {
        for (id, o) in overlays {
            hide(id)
            o.window.orderOut(nil)
        }
    }
}
