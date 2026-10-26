import Cocoa

enum SystemActions {
    // Launching the "Mission Control" helper binary stopped triggering the overlay on
    // recent macOS (confirmed broken on macOS 27), and a synthesized F3 (kVK_F3) is not the
    // Mission Control media key either, so it does nothing. The Dock still listens to its
    // own private notifications (what the trackpad gestures send); keyboard shortcuts are
    // only the fallback when that symbol is missing.
    //   Mission Control: Control+Up Arrow.
    //   App Exposé:      Control+Down Arrow.
    //   Show Desktop:    F11.
    private enum Key {
        static let f11: CGKeyCode = 0x67
        static let upArrow: CGKeyCode = 0x7E
        static let downArrow: CGKeyCode = 0x7D
        static let leftArrow: CGKeyCode = 0x7B
        static let rightArrow: CGKeyCode = 0x7C
    }

    private typealias DockNotify = @convention(c) (CFString, Int32) -> Void
    private static let coreDockSendNotification: DockNotify? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "CoreDockSendNotification") else {
            Log.info("CoreDockSendNotification not found; using keyboard shortcuts")
            return nil
        }
        return unsafeBitCast(sym, to: DockNotify.self)
    }()

    /// Asks the Dock directly; false if the private API isn't available.
    private static func dock(_ name: String) -> Bool {
        guard let send = coreDockSendNotification else { return false }
        send(name as CFString, 0)
        return true
    }

    /// Same as the old three-finger swipe up / the Mission Control key.
    static func missionControl() {
        if !dock("com.apple.expose.awake") { postKey(Key.upArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]) }
    }
    /// Windows of the current app (old three-finger swipe down).
    static func appExpose() {
        if !dock("com.apple.expose.front.awake") { postKey(Key.downArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]) }
    }
    /// Mission Control / App Exposé are up: the Dock then covers a whole screen with its
    /// overview window (its Dock bar never does).
    static var isOverviewShowing: Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screens = NSScreen.screens.map { Geometry.ax($0.frame) }
        return list.contains { w in
            guard w[kCGWindowOwnerName as String] as? String == "Dock", (w[kCGWindowLayer as String] as? Int) == 20,
                  let b = w[kCGWindowBounds as String] else { return false }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            return screens.contains { r.width >= $0.width - 1 && r.height >= $0.height - 1 }
        }
    }

    /// The desktop (Space) on the left (-1) or right (+1): macOS's own "Move left/right a
    /// space" shortcut, ⌃← / ⌃→.
    static func switchDesktop(_ dir: Int) {
        postKey(dir < 0 ? Key.leftArrow : Key.rightArrow, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
    }

    static func showDesktop() {
        if !dock("com.apple.showdesktop.awake") { postKey(Key.f11) }
    }

    /// Sends a key press to the window server (no Accessibility/Input Monitoring needed
    /// beyond Oz's existing grant; it drives the same symbolic hotkeys as the keyboard).
    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func launchpad() {
        for path in ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { Log.info("failed to run \(path): \(error)") }
    }

    /// Runs a shell command in the background (oz.exec in the config).
    static func shell(_ command: String) {
        run("/bin/sh", ["-c", command])
    }

    /// Runs a shell command and returns stdout (oz.shell in the config).
    static func shellSync(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Frees the three-finger vertical swipe from Mission Control / App Exposé
/// (moves them to four fingers) so Oz can use it for scrolling.
enum TrackpadSetup {
    static var scriptPath: String? {
        if let p = Bundle.main.path(forResource: "trackpad-gestures", ofType: "sh") { return p }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/trackpad-gestures.sh").standardized.path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// True while macOS still owns the three-finger vertical swipe.
    static var systemOwnsThreeFingerSwipe: Bool {
        CFPreferencesAppSynchronize("com.apple.AppleMultitouchTrackpad" as CFString)
        let v = CFPreferencesCopyAppValue("TrackpadThreeFingerVertSwipeGesture" as CFString,
                                          "com.apple.AppleMultitouchTrackpad" as CFString) as? NSNumber
        return (v?.intValue ?? 2) != 0
    }

    @discardableResult
    static func run(_ action: String) -> String {
        guard let script = scriptPath else { return "trackpad-gestures.sh not found" }
        let out = SystemActions.shellSync("/bin/bash '\(script)' \(action) 2>&1")
        Log.info("trackpad \(action): \(out)")
        return out
    }
}
