import Cocoa

/// A panel whose glass always looks the way it does in the active app. Oz runs in the
/// background, and macOS draws the glass of inactive apps as a dense frosted material; real
/// Liquid Glass (clear, refracting what's behind it at the edges) only shows for the active
/// app. Activating Oz or making the panel key would take focus from the app whose window is
/// being dragged, so the window instead answers AppKit's "should this look active?" with
/// yes. (Private AppKit methods: if they stop being asked, the glass is just frosted again.)
private final class ActiveLookPanel: NSPanel {
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
}

/// The light on a pane of glass: a bright rim (strongest at the top left, where the light
/// comes from), a soft sheen across the top and a faint shade along the bottom, as the
/// thickness of the glass would give it. Drawn on top of the system glass, and on its own
/// over the frosted material before macOS 26.
private final class GlassLight: NSView {
    private let radius: CGFloat
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let shade = CAGradientLayer()
    private let sheenClip = CAShapeLayer()
    private let shadeClip = CAShapeLayer()

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        rim.colors = [NSColor(white: 1, alpha: 0.95).cgColor, NSColor(white: 1, alpha: 0.18).cgColor,
                      NSColor(white: 1, alpha: 0.55).cgColor]
        rim.locations = [0, 0.55, 1]
        rim.startPoint = CGPoint(x: 0, y: 1)
        rim.endPoint = CGPoint(x: 1, y: 0)
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.black.cgColor
        rimShape.lineWidth = 1.5
        rim.mask = rimShape
        sheen.colors = [NSColor(white: 1, alpha: 0.2).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.6)
        sheen.mask = sheenClip
        shade.colors = [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.1).cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0.3)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.mask = shadeClip
        for l in [sheen, shade, rim] {
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
        let full = CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for l in [rim, sheen, shade] as [CALayer] { l.frame = b }
        for m in [rimShape, sheenClip, shadeClip] { m.frame = b }
        rimShape.path = CGPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75,
                               cornerHeight: radius - 0.75, transform: nil)
        sheenClip.path = full
        shadeClip.path = full
        CATransaction.commit()
    }
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

        let radius: CGFloat = 24
        let light = GlassLight(radius: radius)
        let content: NSView
        if #available(macOS 26.0, *) {
            // Clear glass, untinted: the closest to the system's own Liquid Glass. (The regular
            // style stays frosted even when it looks active, and a tint clouds it.)
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = radius
            glass.contentView = light
            content = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            light.frame = blur.bounds
            light.autoresizingMask = [.width, .height]
            blur.addSubview(light)
            content = blur
        }
        window.contentView = content
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

        let radius = InsertionLine.thickness / 2
        let light = GlassLight(radius: radius)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = radius
            glass.contentView = light
            window.contentView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            light.frame = blur.bounds
            light.autoresizingMask = [.width, .height]
            blur.addSubview(light)
            window.contentView = blur
        }
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
