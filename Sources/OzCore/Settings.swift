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
    /// Held with those buttons, they switch desktop instead (up: the one on the left, down:
    /// the one on the right): "shift", "control", "option", "command", or "none".
    public var desktopModifier = "shift"
    public var debug = false

    public init() {}

    public init(json: [String: Any]) {
        self.init()
        apply(json)
    }

    /// Takes the values of a config object (`oz.set`, or the Settings window's own changes).
    /// Returns what it couldn't use, each as "name: what's wrong": settings it doesn't know
    /// and values it doesn't take, which stay as they were.
    @discardableResult
    public mutating func apply(_ j: [String: Any]) -> [String] {
        var r = ConfigReader(j)
        let share = "above 0, up to 1"
        if let v = r.number("gap") { gap = CGFloat(max(0, v)) }
        if let v = r.number("outerGap") { outerGap = CGFloat(max(0, v)) }
        if let v = r.number("width") { width = CGFloat(min(max(v, 0.1), 1)) }
        if let v = r.numbers("heights", share, where: { $0 > 0 && $0 <= 1 }) { heights = v.map { CGFloat($0) } }
        if let v = r.number("defaultHeight", share, where: { $0 > 0 && $0 <= 1 }) { defaultHeight = CGFloat(v) }
        if let v = r.numbers("widths", "above 0, below 1", where: { $0 > 0 && $0 < 1 }) { widths = v.map { CGFloat($0) } }
        if let v = r.number("resizeStep", "above 0, below 1", where: { $0 > 0 && $0 < 1 }) { resizeStep = CGFloat(v) }
        if let v = r.bool("keepInitialHeights") { keepInitialHeights = v }
        if let v = r.choice("newWindowPosition", InsertPosition.self) { newWindowPosition = v }
        if let v = r.number("animationDuration") { animationDuration = max(0, v) }
        if let v = r.choice("topOverflow", TopOverflow.self) { topOverflow = v }
        if let v = r.number("minVisible") { minVisible = CGFloat(max(0, v)) }
        if let v = r.bool("livePeek") { livePeek = v }
        if let v = r.number("livePeekFPS", "above 0", where: { $0 > 0 }) { livePeekFPS = min(v, 60) }
        if let v = r.number("captureScale", share, where: { $0 > 0 && $0 <= 1 }) { captureScale = CGFloat(max(v, 0.1)) }
        if let v = r.bool("slowAppProxy") { slowAppProxy = v }
        if let v = r.bool("smoothScroll") { smoothScroll = v }
        if let v = r.number("slowAppThreshold", "above 0", where: { $0 > 0 }) { slowAppThreshold = v }
        if let v = r.strings("passThroughApps") { passThroughApps = v }
        if let v = r.bool("demoMode") { demoMode = v }
        if var b = r.group("scrollButtons") {
            // An empty string clears one (the Settings window's Clear, over the config's).
            if let v = b.string("up") { scrollUpButton = v.isEmpty ? nil : v }
            if let v = b.string("down") { scrollDownButton = v.isEmpty ? nil : v }
            if let v = b.string("desktopModifier", oneOf: ["shift", "control", "option", "command", "none"]) { desktopModifier = v }
            r.take(b)
        }
        if let v = r.bool("debug") { debug = v }

        if var s = r.group("swipe") {
            if let v = s.bool("enabled") { swipe.enabled = v }
            if let v = s.number("fingers") { swipe.fingers = min(max(Int(v), 2), 5) }
            if let v = s.number("sensitivity", "above 0", where: { $0 > 0 }) { swipe.sensitivity = v }
            if let v = s.bool("natural") { swipe.natural = v }
            // A mode, or true / false for "always" / "off".
            if let v = s.choice("snap", SnapMode.self, orBool: { $0 ? .always : .off }) { swipe.snap = v }
            if let v = s.number("snapDistance") { swipe.snapDistance = CGFloat(max(0, v)) }
            if let v = s.number("momentum") { swipe.momentum = max(0, v) }
            if let v = s.bool("focus") { swipe.focus = v }
            if let v = s.number("threshold", "above 0", where: { $0 > 0 }) { swipe.threshold = v }
            r.take(s)
        }
        if var d = r.group("doubleTap") {
            if let v = d.bool("enabled") { doubleTap.enabled = v }
            if let v = d.number("fingers") { doubleTap.fingers = min(max(Int(v), 2), 5) }
            if let v = d.string("action"), !v.isEmpty { doubleTap.action = v }
            if let v = d.number("interval", "above 0", where: { $0 > 0 }) { doubleTap.interval = v }
            r.take(d)
        }
        return r.finish()
    }

    public func passesThrough(bundleID: String?, name: String?) -> Bool {
        let keys = [bundleID, name].compactMap { $0?.lowercased() }
        return passThroughApps.contains { keys.contains($0.lowercased()) }
    }

}

/// Reads the values of a config object by name, noting what can't be used: a value of the
/// wrong kind or out of range and, once done, names nothing asked for (a misspelt setting).
struct ConfigReader {
    private let object: [String: Any]
    private let prefix: String
    private var asked = Set<String>()
    private var problems: [String] = []

    init(_ object: [String: Any], prefix: String = "") {
        self.object = object
        self.prefix = prefix
    }

    /// The value under `key`, if there is one (null counts as none).
    private mutating func value(_ key: String) -> Any? {
        asked.insert(key)
        guard let v = object[key], !(v is NSNull) else { return nil }
        return v
    }

    private mutating func reject(_ key: String, _ value: Any, _ expected: String) {
        problems.append("\(prefix)\(key): \(Self.show(value)) is not \(expected)")
    }

    /// A number (not true / false), which `ok` accepts; `range` says what that takes.
    mutating func number(_ key: String, _ range: String? = nil, where ok: (Double) -> Bool = { _ in true }) -> Double? {
        guard let v = value(key) else { return nil }
        guard let n = Self.number(v), ok(n) else {
            reject(key, v, "a number" + (range.map { " " + $0 } ?? ""))
            return nil
        }
        return n
    }

    /// A list of such numbers, not empty.
    mutating func numbers(_ key: String, _ range: String, where ok: (Double) -> Bool) -> [Double]? {
        guard let v = value(key) else { return nil }
        guard let a = v as? [Any], !a.isEmpty, case let n = a.compactMap(Self.number).filter(ok), n.count == a.count else {
            reject(key, v, "a list of numbers \(range)")
            return nil
        }
        return n
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let v = value(key) else { return nil }
        guard let b = v as? Bool else {
            reject(key, v, "true or false")
            return nil
        }
        return b
    }

    mutating func string(_ key: String, oneOf options: [String]? = nil) -> String? {
        guard let v = value(key) else { return nil }
        guard let s = v as? String, options?.contains(s) ?? true else {
            reject(key, v, options.map(Self.oneOf) ?? "text")
            return nil
        }
        return s
    }

    mutating func strings(_ key: String) -> [String]? {
        guard let v = value(key) else { return nil }
        guard let a = v as? [Any], case let s = a.compactMap({ $0 as? String }), s.count == a.count else {
            reject(key, v, "a list of texts")
            return nil
        }
        return s
    }

    /// One of an enum's names; `orBool` also takes true / false for two of them.
    mutating func choice<T: RawRepresentable & CaseIterable>(_ key: String, _: T.Type, orBool: ((Bool) -> T)? = nil) -> T?
    where T.RawValue == String {
        guard let v = value(key) else { return nil }
        if let s = v as? String, let c = T(rawValue: s) { return c }
        if let orBool, Self.number(v) == nil, let b = v as? Bool { return orBool(b) }
        reject(key, v, Self.oneOf(T.allCases.map(\.rawValue)) + (orBool == nil ? "" : ", true or false"))
        return nil
    }

    /// A group of settings under `key` ("swipe"): read it, then hand it back with `take`.
    mutating func group(_ key: String) -> ConfigReader? {
        guard let v = value(key) else { return nil }
        guard let d = v as? [String: Any] else {
            reject(key, v, "a group of settings ({ ... })")
            return nil
        }
        return ConfigReader(d, prefix: prefix + key + ".")
    }

    /// Takes over what a group read with `group` found.
    mutating func take(_ group: ConfigReader) {
        var g = group
        problems += g.finish()
    }

    /// Everything that couldn't be used, the names nothing asked for among them.
    mutating func finish() -> [String] {
        for key in object.keys.sorted() where !asked.contains(key) {
            problems.append("\(prefix)\(key): no such setting")
        }
        return problems
    }

    private static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func oneOf(_ options: [String]) -> String {
        "one of " + options.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// A value as the config would write it, short.
    private static func show(_ v: Any) -> String {
        switch v {
        case let s as String: return "\"\(s)\""
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : "\(n)"
        case is [Any]: return "that list"
        case is [String: Any]: return "that group"
        default: return "that"
        }
    }
}
