import CoreGraphics
import Foundation

public struct SwipeSettings {
    public var enabled = true
    public var fingers = 3
    /// 1.0 = swiping the full trackpad height scrolls one screen height.
    public var sensitivity = 1.5
    /// Fingers up -> strip moves up (reveals windows below), like natural scrolling.
    public var natural = true
    /// How a swipe comes to rest (see SnapMode).
    public var snap = SnapMode.near
    /// "near" mode: snap when released within this many points of a window edge.
    public var snapDistance: CGFloat = 70
    /// Scales how far a flick keeps gliding after release.
    public var momentum = 1.0
    /// Focus the top window after a swipe. Off by default: scrolling only looks around,
    /// focus moves when you click or use a focus command.
    public var focus = false
    public var threshold = 0.02
    public init() {}
}

public struct DoubleTapSettings {
    public var enabled = true
    public var fingers = 3
    /// "missionControl", "appExpose", "showDesktop", "launchpad", any command name,
    /// or "binding:<id>" for a JS function.
    public var action = "missionControl"
    public var interval = 0.4
    public init() {}
}

public struct Settings {
    public var gap: CGFloat = 10
    public var outerGap: CGFloat = 10
    /// Row width as a fraction of the screen width.
    public var width: CGFloat = 1
    /// Height presets for cycleHeight (fractions of the screen height). PaperWM: window_ratios.
    public var heights: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]
    public var defaultHeight: CGFloat = 0.5
    /// Width presets for cycleWidth when several windows share a row (fractions of the row).
    public var widths: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3]
    /// Step for resizeWidth / resizeHeight when no argument is given (fraction of row / screen).
    public var resizeStep: CGFloat = 0.05
    /// Keep the height windows already have when Oz starts.
    public var keepInitialHeights = true
    public var newWindowPosition: InsertPosition = .below
    public var animationDuration = 0.2
    public var topOverflow: TopOverflow = .slide
    public var minVisible: CGFloat = 80
    /// Peeking (top-overflowing) windows stream live content (video keeps playing).
    public var livePeek = true
    /// Frame rate of the live peek.
    public var livePeekFPS = 12.0
    /// Resolution of window captures (snapshots and live frames) as a fraction of the window's
    /// own: 1 keeps every pixel (lossless), 0.75 / 0.5 / 0.25 use less memory and capture work.
    public var captureScale: CGFloat = 1
    /// While scrolling, draw windows of apps that are slow to move (see slowAppThreshold)
    /// from a snapshot and move the real window once, when the scroll ends.
    public var slowAppProxy = true
    /// While the strip moves (swipes, animations), draw every window from a snapshot and move
    /// the real windows once, when the motion ends: smooth however slowly apps answer, at the
    /// cost of content standing still during the motion.
    public var smoothScroll = true
    /// An app is "slow" when it takes longer than this (ms, averaged) to apply a move.
    public var slowAppThreshold = 30.0
    public var swipe = SwipeSettings()
    public var doubleTap = DoubleTapSettings()
    /// While one of these apps is frontmost (bundle id or name, case-insensitive) Oz lets
    /// go of its shortcuts, and of swipes made over its window, so the app gets them (the
    /// double tap keeps working): remote desktops, game streaming.
    public var passThroughApps = [
        "com.moonlight-stream.Moonlight", "tv.parsec.www", "com.microsoft.rdc.macos",
        "com.apple.ScreenSharing", "com.realvnc.vncviewer", "com.p5sys.jump.mac.viewer",
        "com.teamviewer.TeamViewer", "com.anydesk.anydeskmacos", "com.nvidia.gfnpc.mall",
    ]
    /// Demo mode: a shortcut (ctrl+alt+shift+o) opens stand-in Wizard of Oz windows.
    public var demoMode = false
    /// Buttons (a mouse's side buttons, a key, a media key) that scroll the strip one step up
    /// or down, as stored by the Settings window: "mouse:3", "key:<code>:<modifiers>", "media:<code>".
    public var scrollUpButton: String?
    public var scrollDownButton: String?
    public var debug = false

    public init() {}

    public init(json: [String: Any]) {
        self.init()
        apply(json)
    }

    public mutating func apply(_ j: [String: Any]) {
        let num = Settings.number
        if let v = num(j["gap"]) { gap = CGFloat(max(0, v)) }
        if let v = num(j["outerGap"]) { outerGap = CGFloat(max(0, v)) }
        if let v = num(j["width"]) { width = CGFloat(min(max(v, 0.1), 1)) }
        if let a = j["heights"] as? [Any] {
            let r = a.compactMap(num).filter { $0 > 0 && $0 <= 1 }.map { CGFloat($0) }
            if !r.isEmpty { heights = r }
        }
        if let v = num(j["defaultHeight"]), v > 0, v <= 1 { defaultHeight = CGFloat(v) }
        if let a = j["widths"] as? [Any] {
            let r = a.compactMap(num).filter { $0 > 0 && $0 < 1 }.map { CGFloat($0) }
            if !r.isEmpty { widths = r }
        }
        if let v = num(j["resizeStep"]), v > 0, v < 1 { resizeStep = CGFloat(v) }
        if let v = j["keepInitialHeights"] as? Bool { keepInitialHeights = v }
        if let v = j["newWindowPosition"] as? String, let p = InsertPosition(rawValue: v) { newWindowPosition = p }
        if let v = num(j["animationDuration"]) { animationDuration = max(0, v) }
        if let v = j["topOverflow"] as? String, let t = TopOverflow(rawValue: v) { topOverflow = t }
        if let v = num(j["minVisible"]) { minVisible = CGFloat(max(0, v)) }
        if let v = j["livePeek"] as? Bool { livePeek = v }
        if let v = num(j["livePeekFPS"]), v > 0 { livePeekFPS = min(v, 60) }
        if let v = num(j["captureScale"]), v > 0, v <= 1 { captureScale = CGFloat(max(v, 0.1)) }
        if let v = j["slowAppProxy"] as? Bool { slowAppProxy = v }
        if let v = j["smoothScroll"] as? Bool { smoothScroll = v }
        if let v = num(j["slowAppThreshold"]), v > 0 { slowAppThreshold = v }
        if let a = j["passThroughApps"] as? [Any] { passThroughApps = a.compactMap { $0 as? String } }
        if let v = j["demoMode"] as? Bool { demoMode = v }
        if let b = j["scrollButtons"] as? [String: Any] {
            // An empty string clears one (the Settings window's Clear, over the config's).
            if let v = b["up"] as? String { scrollUpButton = v.isEmpty ? nil : v }
            if let v = b["down"] as? String { scrollDownButton = v.isEmpty ? nil : v }
        }
        if let v = j["debug"] as? Bool { debug = v }

        if let s = j["swipe"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { swipe.enabled = v }
            if let v = num(s["fingers"]) { swipe.fingers = min(max(Int(v), 2), 5) }
            if let v = num(s["sensitivity"]), v > 0 { swipe.sensitivity = v }
            if let v = s["natural"] as? Bool { swipe.natural = v }
            if let v = s["snap"] as? String, let m = SnapMode(rawValue: v) {
                swipe.snap = m
            } else if let v = s["snap"] as? Bool {
                swipe.snap = v ? .always : .off
            }
            if let v = num(s["snapDistance"]) { swipe.snapDistance = CGFloat(max(0, v)) }
            if let v = num(s["momentum"]) { swipe.momentum = max(0, v) }
            if let v = s["focus"] as? Bool { swipe.focus = v }
            if let v = num(s["threshold"]), v > 0 { swipe.threshold = v }
        }
        if let d = j["doubleTap"] as? [String: Any] {
            if let v = d["enabled"] as? Bool { doubleTap.enabled = v }
            if let v = num(d["fingers"]) { doubleTap.fingers = min(max(Int(v), 2), 5) }
            if let v = d["action"] as? String, !v.isEmpty { doubleTap.action = v }
            if let v = num(d["interval"]), v > 0 { doubleTap.interval = v }
        }
    }

    public func passesThrough(bundleID: String?, name: String?) -> Bool {
        let keys = [bundleID, name].compactMap { $0?.lowercased() }
        return passThroughApps.contains { keys.contains($0.lowercased()) }
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
