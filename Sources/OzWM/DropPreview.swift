import Cocoa

/// A panel whose glass always looks the way it does in the active app. Oz runs in the
/// background, and macOS draws the glass of inactive apps as a dense frosted material; real
/// Liquid Glass (light, refracting what's behind it at the edges) only shows for the active
/// app. Activating Oz or making the panel key would take focus from the app whose window is
/// being dragged, so the window instead answers AppKit's "should this look active?" with
/// yes. (Private AppKit methods: if they stop being asked, the glass is just frosted again.)
private final class ActiveLookPanel: NSPanel {
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
}

/// The light on a pane of glass, as Liquid Glass catches it: glints where the edge faces the
/// light (strongest at the top left, fainter at the opposite corner, as light passes through
/// and catches the far side), fading to almost nothing along the straight edges; a softer band
/// just inside the edge, the light bent by the glass's thickness; and a faint sheen across the
/// top. Drawn on top of the system glass, and on its own over the frosted material before macOS 26.
private final class GlassLight: NSView {
    private let radius: CGFloat
    private let edge = CAGradientLayer()
    private let edgeShape = CAShapeLayer()
    private let band = CAGradientLayer()
    private let bandShape = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let sheenClip = CAShapeLayer()

    /// How bright the light is around the edge, from the top left corner (0) round to it again
    /// (1): a glint there, a fainter one at the bottom right (0.5), little in between.
    private static let glints: [(at: NSNumber, alpha: CGFloat)] = [
        (0, 0.6), (0.1, 0.32), (0.2, 0.1), (0.3, 0.1), (0.4, 0.22), (0.5, 0.38),
        (0.6, 0.22), (0.7, 0.1), (0.8, 0.1), (0.9, 0.32), (1, 0.6),
    ]

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        // Measured round the middle from the top left corner: whichever way the angle turns,
        // the glints land on that corner and the one opposite.
        for (l, scale) in [(edge, 0.7), (band, 0.12)] as [(CAGradientLayer, CGFloat)] {
            l.type = .conic
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 0, y: 1)
            l.colors = Self.glints.map { NSColor(white: 1, alpha: $0.alpha * scale).cgColor }
            l.locations = Self.glints.map(\.at)
        }
        for m in [edgeShape, bandShape] {
            m.fillColor = nil
            m.strokeColor = NSColor.black.cgColor
        }
        edgeShape.lineWidth = 1
        edge.mask = edgeShape
        band.mask = bandShape
        sheen.colors = [NSColor(white: 1, alpha: 0.08).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.7)
        sheen.mask = sheenClip
        for l in [sheen, band, edge] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        for l in [edge, band, sheen] as [CALayer] { l.frame = b }
        for m in [edgeShape, bandShape, sheenClip] { m.frame = b }
        func inset(_ d: CGFloat) -> CGPath {
            CGPath(roundedRect: b.insetBy(dx: d, dy: d), cornerWidth: max(radius - d, 0), cornerHeight: max(radius - d, 0), transform: nil)
        }
        edgeShape.path = inset(0.5)
        // The band reaches a few points in (less on a thin rod), from the edge inwards.
        let w = min(5, radius * 0.6)
        bandShape.lineWidth = w
        bandShape.path = inset(w / 2)
        sheenClip.path = inset(0)
        CATransaction.commit()
    }
}

/// A pane of glass `radius` round with its light: clear Liquid Glass with a see-through
/// layer of blur over it, or the frosted material alone before macOS 26. The clear style alone
/// bends what's behind it like a lens at the edges, and the regular one is thickly frosted:
/// the blur, more than half there, frosts it a little, and across `edgeBand` points from the
/// edge rises to nearly whole, hiding most of the bending there. Without a band (a thin rod,
/// all edge) it is nearly whole throughout.
private func glassPane(radius: CGFloat, edgeBand: CGFloat? = nil) -> NSView {
    let light = GlassLight(radius: radius)
    let blur = NSVisualEffectView()
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.masksToBounds = true
    guard #available(macOS 26.0, *) else {
        blur.material = .hudWindow
        light.frame = blur.bounds
        light.autoresizingMask = [.width, .height]
        blur.addSubview(light)
        return blur
    }
    blur.material = .popover
    if let edgeBand {
        blur.maskImage = blurMask(radius: radius, band: edgeBand, inner: 0.6, edge: 0.95)
    } else {
        blur.alphaValue = 0.9
    }
    // The light beside the blur, not in it: the blur's see-through-ness would dim it too.
    let content = NSView()
    for v in [blur, light] as [NSView] {
        v.frame = content.bounds
        v.autoresizingMask = [.width, .height]
        content.addSubview(v)
    }
    let glass = NSGlassEffectView()
    glass.style = .clear
    glass.cornerRadius = radius
    glass.contentView = content
    return glass
}

/// How much of the blur shows, as a mask that stretches to any size: `inner` in the middle,
/// rising to `edge` over the `band` points along the edge.
private func blurMask(radius: CGFloat, band: CGFloat, inner: CGFloat, edge: CGFloat) -> NSImage {
    let cap = ceil(max(radius, band)) + 1
    let side = cap * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        // Each inset rounded rect replaces what the larger one left: a ramp inwards.
        ctx.setBlendMode(.copy)
        let steps = max(Int(band * 2), 1)
        for i in 0...steps {
            let d = band * CGFloat(i) / CGFloat(steps)
            let t = 1 - CGFloat(i) / CGFloat(steps)
            let r = max(radius - d, 0)
            ctx.setFillColor(NSColor(white: 0, alpha: inner + (edge - inner) * t * t).cgColor)
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: d, dy: d), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
        return true
    }
    image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    image.resizingMode = .stretch
    return image
}

/// While a window is dragged, shows where it will land when let go: a pane of Liquid Glass
/// (frosted glass before macOS 26) over the slot it will take, just below the dragged window.
final class DropPreview {
    private let window: NSPanel
    /// Shown frame, AX coordinates.
    private var shown: CGRect?
    private var below: CGWindowID?

    init() {
        window = ActiveLookPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // No window shadow: macOS draws it with a dark outline along the edge, a black line
        // around the glass. The light rim gives the edge instead.
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        window.alphaValue = 0

        window.contentView = glassPane(radius: 24, edgeBand: 18)
    }

    /// Shows (or moves) the preview over `frame` (AX coordinates), ordered just below the
    /// window being dragged so that one stays on top.
    func show(_ frame: CGRect, below id: CGWindowID) {
        let ns = NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        if shown == nil {
            window.setFrame(ns, display: true)
            window.order(.below, relativeTo: Int(id))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1
            }
        } else if shown != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(ns, display: true)
            }
        }
        if below != id {
            window.order(.below, relativeTo: Int(id))
            below = id
        }
        shown = frame
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        below = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shown == nil else { return }  // shown again meanwhile
            self.window.orderOut(nil)
            // A region-sized pane of glass keeps a backing store that size: let it go.
            self.window.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        })
    }
}

/// Inside the scroll area the landing place is a split line: between two rows (horizontal) or
/// beside a window in its row (vertical). A rod of clear Liquid Glass, like the drop preview,
/// above the windows; it jumps straight to each slot (one that slides lags behind the cursor).
final class InsertionLine {
    private let window: NSPanel
    private var shown: CGRect?

    static let thickness: CGFloat = 8

    init() {
        window = ActiveLookPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]

        window.contentView = glassPane(radius: InsertionLine.thickness / 2)
    }

    /// `frame`: the rod, AX coordinates.
    func show(_ frame: CGRect) {
        guard shown != frame else { return }
        window.setFrame(NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY, width: frame.width, height: frame.height),
                        display: true)
        if shown == nil { window.orderFrontRegardless() }
        shown = frame
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        window.orderOut(nil)
    }
}

/// Where the view is in the strip: a thin rounded bar along the zone's right edge, sized like
/// the visible part of the strip and placed like it. Shown while the strip moves, faded out a
/// moment after it stops (like macOS's overlay scrollers).
final class ScrollIndicator {
    private let window: NSPanel
    private var visible = false
    private var hideWork: DispatchWorkItem?

    static let width: CGFloat = 5

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        window.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        // Grey reads on light and dark content alike; the thin light rim separates it from both.
        view.layer?.backgroundColor = NSColor(white: 0.45, alpha: 0.65).cgColor
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.cornerRadius = ScrollIndicator.width / 2
        window.contentView = view
    }

    /// Shows the bar at `frame` (AX coordinates) and fades it out once it hasn't moved for a bit.
    func show(_ frame: CGRect) {
        window.setFrame(NSRect(x: frame.minX, y: Geometry.primaryHeight - frame.maxY, width: frame.width, height: frame.height),
                        display: false)
        if !visible {
            visible = true
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            self.window.orderOut(nil)
        })
    }
}
