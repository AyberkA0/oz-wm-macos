import Cocoa
import QuartzCore

/// macOS's own window shadow for a picture on a board. The board can't have the window server
/// work it out (it would, from the whole board, every frame, a frame late: it flickered), so a
/// window off screen is given the picture's corners, the window server draws its shadow, and
/// that shadow is captured once and stretched around the picture like a nine-part image.
final class ShadowMaker {
    /// Pictures of the same size and corners get the same shadow.
    struct Key: Hashable {
        let corners: Int, scale: Int
        /// How far the corners are taken in from each side (pixels of the picture).
        let reach: Int

        init(image: CGImage, scale: CGFloat) {
            self.scale = Int((scale * 100).rounded())
            reach = Int(min(CGFloat(image.width) / 2, CGFloat(image.height) / 2, 48 * scale).rounded(.down))
            corners = ShadowMaker.cornerSignature(image, reach: reach)
        }
    }

    struct Shadow {
        let key: Key
        /// The shadow alone (the picture's place in it left clear), and its pixels per point.
        let image: CGImage
        let scale: CGFloat
        /// How far it reaches past the picture's sides, in points.
        let left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
        /// The part that stretches (`contentsCenter`).
        let center: CGRect
    }

    private var done: [Key: Shadow] = [:]
    private var waiting: [Key: [(Shadow) -> Void]] = [:]
    private var queue: [(Key, CGImage)] = []
    private var busy = false

    private lazy var panel: StandInPanel = {
        let p = StandInPanel.titled(contentRect: NSRect(x: -30000, y: -30000, width: 10, height: 10))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(shape)
        p.contentView = view
        return p
    }()
    private let shape: CALayer = {
        let l = CALayer()
        l.contentsGravity = .resize
        return l
    }()

    func make(_ key: Key, from image: CGImage, then: @escaping (Shadow) -> Void) {
        if let s = done[key] { return then(s) }
        if waiting[key] != nil { waiting[key]!.append(then); return }
        waiting[key] = [then]
        queue.append((key, image))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let (key, image) = queue.removeFirst()
        guard let corners = Self.corners(of: image, reach: key.reach) else {
            waiting[key] = nil
            return next()
        }
        busy = true
        let scale = CGFloat(key.scale) / 100
        let size = CGSize(width: CGFloat(corners.width) / scale, height: CGFloat(corners.height) / scale)
        // Off every screen: the window server still draws it, and its shadow, for a capture.
        panel.setFrame(NSRect(origin: CGPoint(x: -30000, y: -30000), size: size), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: .zero, size: size)
        shape.contents = corners
        CATransaction.commit()
        panel.orderFrontRegardless()
        CATransaction.flush()
        panel.invalidateShadow()
        attempt(key, corners: corners, size: size, tries: 0)
    }

    /// The shadow is worked out a moment after the content is up (until then it is the last
    /// shape's, or none): capture once it is there.
    private func attempt(_ key: Key, corners: CGImage, size: CGSize, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0.15 : 0.05)) { [self] in
            if let shadow = Self.capture(panel, key: key, corners: corners, size: size) {
                done[key] = shadow
                for then in waiting.removeValue(forKey: key) ?? [] { then(shadow) }
            } else if tries < 10 {
                return attempt(key, corners: corners, size: size, tries: tries + 1)
            } else {
                Log.debug("no shadow for a picture's shape")
                waiting[key] = nil
            }
            busy = false
            next()
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    /// `CGWindowListCreateImage`, gone from the SDK but not from the system: the one capture
    /// that includes a window's shadow. Only our own window is captured, which needs no permission.
    private static let createImage: CreateImage? = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    /// The key window's shadow is a bigger, darker one, which no window of ours can have (it
    /// would have to be the key window): taken from that window itself while it is on screen.
    private var activeDone: [Key: Shadow] = [:]
    private var activeTried: [Key: CFTimeInterval] = [:]

    /// The key window's shadow for this shape, once one was taken.
    func active(_ key: Key) -> Shadow? { activeDone[key] }

    /// Takes the shadow of window `id` (the key window, of `size` points, whose picture is
    /// `image`), off the main thread; `then` gets it if the window was on screen with it.
    func takeActive(_ key: Key, window id: CGWindowID, size: CGSize, image: CGImage, then: @escaping (Shadow) -> Void) {
        let now = CACurrentMediaTime()
        guard activeDone[key] == nil, now - (activeTried[key] ?? 0) > 0.5 else { return }
        activeTried[key] = now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let raw = WindowCapture.withShadow(id), let corners = Self.corners(of: image, reach: key.reach),
                  let shadow = Self.cutOut(raw, key: key, corners: corners, size: size, opaque: { _, _, a in a == 255 })
            else { return }
            DispatchQueue.main.async {
                self?.activeDone[key] = shadow
                then(shadow)
            }
        }
    }

    private static func capture(_ panel: NSPanel, key: Key, corners: CGImage, size: CGSize) -> Shadow? {
        let includingWindow: UInt32 = 1 << 3
        guard let create = createImage,
              let raw = create(.null, includingWindow, UInt32(panel.windowNumber), 0)?.takeRetainedValue() else { return nil }
        // The window in it: the opaque white of the corners' middle.
        return cutOut(raw, key: key, corners: corners, size: size, opaque: { r, _, a in r > 250 && a > 250 })
    }

    /// The shadow alone from a capture of a window of `size` points with its shadow: the
    /// window found along the middle row and column where pixels are `opaque` (red, green,
    /// alpha), and its place cut out in the shape of `corners`.
    private static func cutOut(_ raw: CGImage, key: Key, corners: CGImage, size: CGSize,
                               opaque: (UInt8, UInt8, UInt8) -> Bool) -> Shadow? {
        let w = raw.width, h = raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        // The window's edges in the capture (memory rows run top down).
        func inside(_ x: Int, _ y: Int) -> Bool { let i = (y * w + x) * 4; return opaque(px[i], px[i + 1], px[i + 3]) }
        guard let left = (0..<w).first(where: { inside($0, h / 2) }),
              let last = (0..<w).last(where: { inside($0, h / 2) }),
              let top = (0..<h).first(where: { inside(w / 2, $0) }),
              let lowest = (0..<h).last(where: { inside(w / 2, $0) }) else { return nil }
        let ww = last + 1 - left, wh = lowest + 1 - top
        let s = CGFloat(ww) / size.width
        // Something see-through inside the window (a sidebar) cut the edges short.
        guard abs(CGFloat(wh) / size.height - s) < 0.03 * s else { return nil }
        let right = w - ww - left, bottom = h - wh - top
        // No shadow yet: the capture is the window alone.
        guard left > 0, top > 0, right > 0, bottom > 0, px[((h / 2) * w + left / 2) * 4 + 3] > 0 else { return nil }
        // Leave the picture's own place clear: only the shadow (and its rim) stays.
        ctx.setBlendMode(.destinationOut)
        ctx.draw(corners, in: CGRect(x: left, y: bottom, width: ww, height: wh))
        guard let image = ctx.makeImage() else { return nil }
        // Stretched: the middle two pixels of each side.
        let center = CGRect(x: (CGFloat(left) + CGFloat(ww) / 2 - 1) / CGFloat(w),
                            y: (CGFloat(bottom) + CGFloat(wh) / 2 - 1) / CGFloat(h),
                            width: 2 / CGFloat(w), height: 2 / CGFloat(h))
        return Shadow(key: key, image: image, scale: s, left: CGFloat(left) / s, right: CGFloat(right) / s,
                      top: CGFloat(top) / s, bottom: CGFloat(bottom) / s, center: center)
    }

    /// The picture's four corners (`reach` pixels in from each side) put together, white where
    /// the picture is: the shape the shadow is made for, without the rest of the picture.
    private static func corners(of image: CGImage, reach r: Int) -> CGImage? {
        guard r > 0, let ctx = CGContext(data: nil, width: 2 * r, height: 2 * r, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = image.width, h = image.height
        // Crops are in image coordinates (top down); the context draws bottom up.
        for (cx, cy, dx, dy) in [(0, 0, 0, r), (w - r, 0, r, r), (0, h - r, 0, 0), (w - r, h - r, r, 0)] {
            guard let part = image.cropping(to: CGRect(x: cx, y: cy, width: r, height: r)) else { return nil }
            ctx.draw(part, in: CGRect(x: dx, y: dy, width: r, height: r))
        }
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r))
        return ctx.makeImage()
    }

    /// The corners' transparency, to tell shapes apart cheaply: which pixels along the top
    /// and bottom rows and down the sides near the corners are see-through.
    private static func cornerSignature(_ image: CGImage, reach r: Int) -> Int {
        guard let c = corners(of: image, reach: min(r, 24)), let data = c.dataProvider?.data,
              let p = CFDataGetBytePtr(data) else { return 0 }
        var hasher = Hasher()
        let n = c.width, stride = c.bytesPerRow
        for y in 0..<c.height { for x in 0..<n where x < 24 || x >= n - 24 || y < 24 || y >= c.height - 24 {
            hasher.combine(p[y * stride + x * 4 + 3] > 127)
        } }
        return hasher.finalize()
    }
}

