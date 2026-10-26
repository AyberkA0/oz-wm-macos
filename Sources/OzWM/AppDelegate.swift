import ApplicationServices
import Cocoa
import OzCore

let commandNotification = Notification.Name("dev.oz.wm.command")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wm = WindowManager()
    private lazy var config = ConfigEngine(wm: wm)
    private let gestures = GestureController()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var started = false
    private var signalSources: [DispatchSourceSignal] = []
    /// Keeps App Nap off: as a background agent Oz would otherwise get its timers and
    /// main-thread work throttled by hundreds of milliseconds (measured), which showed up
    /// as random hitches in swipes and animations.
    private var activity: NSObjectProtocol?
    private var areaEditor: ScrollAreaEditor?
    private let settingsWindow = SettingsWindowController()
    /// The settings as the config file has them, before the app's own changes go on top.
    private var configSettings = Settings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        installSignalHandlers()
        if AXIsProcessTrusted() {
            startOz()
        } else {
            requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        demo.closeAll()
        gestures.stop()
        if started {
            wm.saveLayout()
            wm.restoreAll()
        }
        restoreWallpaperTinting()
    }

    // MARK: Startup

    private func requestAccessibility() {
        Log.info("waiting for Accessibility permission")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.startOz()
        }
    }

    private func startOz() {
        guard !started else { return }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Window management reacts to gestures in real time")
        Watchdog.start()
        disableWallpaperTinting()

        wm.rulesProvider = { [unowned self] w in config.rules(for: w) }
        wm.emit = { [unowned self] event, payload in config.emit(event, payload) }
        wm.reloadConfig = { [unowned self] in config.load() }
        wm.onEnabledChanged = { [weak self] _ in self?.updateStatusIcon() }
        wm.editScrollArea = { [weak self] screen in self?.openScrollAreaEditor(screen) }
        wm.openSettings = { [weak self] in self?.openSettings() }
        config.onLoaded = { [unowned self] s in
            configSettings = s
            applySettings()
        }
        settingsWindow.apply = { [unowned self] _ in applySettings() }
        settingsWindow.editConfig = { [unowned self] in editConfig() }
        settingsWindow.listen = { [unowned self] done in scrollButtons.listen { done($0?.string) } }
        settingsWindow.stopListening = { [unowned self] in scrollButtons.stopListening() }
        scrollButtons.onScroll = { [unowned self] dir in wm.scrollStep(dir) }
        scrollButtons.onDesktop = { dir in SystemActions.switchDesktop(dir) }
        config.load()
        config.watch()
        wm.start()
        started = true

        gestures.handler = { [unowned self] e in
            switch e {
            case .doubleTap:
                // Still works over a pass-through app: it goes to the Dock, not to the app.
                runDoubleTap()
            case .swipeBegan:
                // A pass-through app in front gets the swipes made over its own window; over
                // the strip (its window off to the side, say) they still scroll it.
                swipeToApp = HotkeyCenter.shared.suspended && frontAppUnderMouse()
                if swipeToApp {
                    Log.info("swipe ignored: passed through to the app in front")
                } else {
                    wm.handleGesture(e)
                }
            default:
                if !swipeToApp { wm.handleGesture(e) }
            }
        }
        gestures.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.updatePassThrough()
        }
        updatePassThrough()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.gestures.restart() }
        }

        DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: nil,
                                                            queue: .main) { [weak self] n in
            guard let name = n.object as? String else { return }

            let arg = n.userInfo?["arg"] as? String
            self?.wm.perform(name, arg: arg.flatMap { Double($0) }.map { NSNumber(value: $0) } ?? arg)
        }

        Log.info("Oz started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerTrackpadSetup() }
    }

    /// The swipe going on was made over a pass-through app's window, and is left to it.
    private var swipeToApp = false

    /// The window under the mouse belongs to the frontmost app.
    private func frontAppUnderMouse() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Geometry.primaryHeight - m.y)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            // Oz's own (the boards span whole screens) are never what the user swipes on.
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let b = info[kCGWindowBounds as String] else { continue }
            var r = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(b as! CFDictionary, &r)
            if r.contains(p) { return (info[kCGWindowOwnerPID as String] as? pid_t) == front }
        }
        return false
    }

    /// A pass-through app in front (Moonlight, a remote desktop) gets every key, and the
    /// swipes made over its window.
    private func updatePassThrough() {
        let app = NSWorkspace.shared.frontmostApplication
        let pass = wm.settings.passesThrough(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        guard pass != HotkeyCenter.shared.suspended else { return }
        if pass { HotkeyCenter.shared.suspend() } else { HotkeyCenter.shared.resume() }
        Log.info("shortcuts \(pass ? "passed through to" : "back from") \(app?.localizedName ?? "?")")
    }

    private func runDoubleTap() {
        let action = wm.settings.doubleTap.action
        Log.info("double tap -> \(action)")
        if action.hasPrefix("binding:"), let id = Int(action.dropFirst("binding:".count)) {
            config.runBinding(id)
        } else {
            wm.perform(action)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Trackpad

    private func offerTrackpadSetup() {
        guard wm.settings.swipe.enabled, wm.settings.swipe.fingers == 3,
              TrackpadSetup.systemOwnsThreeFingerSwipe,
              !UserDefaults.standard.bool(forKey: "trackpadSetupDeclined") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Give the three-finger vertical swipe to Oz?"
        alert.informativeText = """
        Right now a three-finger swipe up opens Mission Control. Oz uses this gesture \
        to scroll the window strip.

        If you choose Apply:
        • Three fingers up/down → Oz scrolls the strip
        • Mission Control → three-finger double tap (also four fingers up and F3)
        • App Exposé → four fingers down

        You can undo this any time from the Oz menu in the menu bar.
        """
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn: applyTrackpad()
        case .alertThirdButtonReturn: UserDefaults.standard.set(true, forKey: "trackpadSetupDeclined")
        default: break
        }
    }

    @objc private func applyTrackpad() {
        TrackpadSetup.run("apply")
        gestures.restart()
    }

    @objc private func restoreTrackpad() {
        TrackpadSetup.run("restore")
    }

    // MARK: Wallpaper tinting

    /// macOS tints window backgrounds with the wallpaper colour behind them (System Settings ›
    /// Appearance › "Allow wallpaper tinting in windows"). Windows Oz parks off screen lose
    /// that tint, so the stand-ins drawn from their captures would look different from the
    /// real windows. Oz therefore keeps the tint off while it runs and restores the user's
    /// choice when it quits.
    private static let tintKey = "AppleReduceDesktopTinting" as CFString
    private static let savedTintKey = "tintingWasOnBeforeOz"

    private var wallpaperTintingOn: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return !(CFPreferencesCopyAppValue(AppDelegate.tintKey, kCFPreferencesAnyApplication) as? Bool ?? false)
    }

    private func disableWallpaperTinting() {
        guard wallpaperTintingOn else { return }
        UserDefaults.standard.set(true, forKey: AppDelegate.savedTintKey)
        SystemActions.run("/usr/bin/defaults", ["write", "-g", "AppleReduceDesktopTinting", "-bool", "true"])
        Log.info("macOS wallpaper tinting turned off (restored when Oz quits)")
    }

    private func restoreWallpaperTinting() {
        guard UserDefaults.standard.bool(forKey: AppDelegate.savedTintKey) else { return }
        UserDefaults.standard.removeObject(forKey: AppDelegate.savedTintKey)
        // Synchronous: this runs while quitting.
        _ = SystemActions.shellSync("/usr/bin/defaults write -g AppleReduceDesktopTinting -bool false")
        Log.info("macOS wallpaper tinting restored")
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Oz") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "oz"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }

        if !started {
            item("Waiting for Accessibility permission…", nil).isEnabled = false
            item("Open Accessibility Settings", #selector(openAccessibilitySettings))
        } else {
            let count = wm.allWindowsInfo().count
            item("Oz WM — \(count) window\(count == 1 ? "" : "s")", nil).isEnabled = false
            if let err = config.lastError {
                item("⚠︎ Config error: \(err)", nil).isEnabled = false
            }
            if wm.settings.topOverflow == .slide && !SnapshotCache.hasPermission {
                item("⚠︎ Allow Screen Recording for the slide-off effect…", #selector(openScreenRecordingSettings))
            }
            if TouchSource.shared.deviceCount == 0 {
                item("⚠︎ No trackpad found", nil).isEnabled = false
            }
            menu.addItem(.separator())
            item("Tiling Enabled", #selector(toggleTiling)).state = wm.enabled ? .on : .off
            if wm.enabled, let screen = Geometry.screenUnderMouse() {
                item("Tile This Desktop", #selector(toggleSpaceTiling)).state = wm.isTiled(screen: screen) ? .on : .off
                if wm.isTiled(screen: screen) {
                    item("Set Scroll Area…", #selector(setScrollArea))
                    if wm.scrollAreaFraction(screen) != nil {
                        item("Reset Scroll Area", #selector(resetScrollArea))
                    }
                }
            }
            item("Keep Windows Alive (Live Capture)", #selector(toggleLivePeek)).state = wm.settings.livePeek ? .on : .off
            item("Smooth Scrolling (Snapshots While Moving)", #selector(toggleSmoothScroll)).state = wm.settings.smoothScroll ? .on : .off
            item("Magnetic Scrolling (Stop at Windows)", #selector(toggleMagneticScroll)).state = wm.settings.swipe.snap == .always ? .on : .off
            item("Retile", #selector(retile))
            if wm.enabled { addPresetItems(to: menu) }
        }
        menu.addItem(.separator())
        item("Start at Login", #selector(toggleStartAtLogin)).state = LoginItem.isEnabled ? .on : .off
        item("Settings…", #selector(openSettings), key: ",")
        item("Edit Config", #selector(editConfig))
        item("Reload Config", #selector(reloadConfig))
        item("Show Config Folder", #selector(revealConfig))
        item("Open Log", #selector(openLog))
        menu.addItem(.separator())
        if TrackpadSetup.systemOwnsThreeFingerSwipe {
            item("Trackpad: Give Three-Finger Swipe to Oz", #selector(applyTrackpad))
        } else {
            item("Trackpad: Restore macOS Gestures", #selector(restoreTrackpad))
        }
        menu.addItem(.separator())
        item("Quit Oz", #selector(quit), key: "q")
    }

    /// The config file's settings with the app's own changes (Settings window, menu) on top.
    private func applySettings() {
        var s = configSettings
        s.apply(SettingsOverrides.all)
        wm.settings = s
        Log.debugEnabled = s.debug
        gestures.configure(s)
        if started { wm.settingsChanged(); updatePassThrough() }
        updateDemo(s.demoMode)
        scrollButtons.desktopModifier = [
            "shift": CGEventFlags.maskShift, "control": .maskControl, "option": .maskAlternate, "command": .maskCommand,
        ][s.desktopModifier]
        scrollButtons.set(up: InputTrigger(s.scrollUpButton), down: InputTrigger(s.scrollDownButton))
        settingsWindow.refresh(s)
    }

    /// Settings › Mouse buttons: buttons that scroll the strip a step.
    private let scrollButtons = ScrollButtons()

    // MARK: Demo mode

    private let demo = Demo.Launcher()
    /// Removes the demo shortcut (a config reload drops it on its own: it is set again then).
    private var removeDemoKey: (() -> Void)?
    private static let demoKey = "ctrl+alt+shift+o"

    private func updateDemo(_ on: Bool) {
        removeDemoKey?()
        removeDemoKey = nil
        if on {
            removeDemoKey = HotkeyCenter.shared.registerTemporary(Self.demoKey) { [weak self] in self?.demo.openWindow() }
            if removeDemoKey == nil { Log.info("demo mode: \(Self.demoKey) is taken") }
        } else {
            demo.closeAll()
        }
    }

    // MARK: Presets

    /// Saved desktops: one item per preset (click opens it), saving this desktop, deleting.
    private func addPresetItems(to menu: NSMenu) {
        let presets = PresetStore.load()
        menu.addItem(.separator())
        for (i, p) in presets.enumerated() {
            let it = NSMenuItem(title: "Open Preset: \(p.name)", action: #selector(openPreset(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.toolTip = p.apps.map(\.name).joined(separator: ", ")
            menu.addItem(it)
        }
        if presets.count < Preset.limit {
            let it = NSMenuItem(title: "Save This Desktop as Preset…", action: #selector(savePreset), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        } else {
            let it = NSMenuItem(title: "Save This Desktop as Preset (\(Preset.limit) saved, delete one first)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        guard !presets.isEmpty else { return }
        let delete = NSMenu()
        for (i, p) in presets.enumerated() {
            let it = NSMenuItem(title: p.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            delete.addItem(it)
        }
        let parent = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
        parent.submenu = delete
        menu.addItem(parent)
    }

    @objc private func savePreset() {
        guard let screen = Geometry.screenUnderMouse() else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let captured = wm.capturePreset(named: nil, screen: screen) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to save"
            alert.informativeText = "There are no windows on this desktop that Oz arranges."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save this desktop as a preset"
        alert.informativeText = "Apps: " + captured.apps.map(\.name).joined(separator: ", ")
            + "\n\nOpening it later starts these apps and puts their windows back where they are now."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = captured.name
        field.placeholderString = Preset.defaultName(for: captured.apps)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Captured again: the layout may have changed while the dialog was up.
        guard let preset = wm.capturePreset(named: field.stringValue, screen: screen) ?? Optional(captured) else { return }
        var presets = PresetStore.load()
        guard presets.count < Preset.limit else { return }
        presets.append(preset)
        PresetStore.save(presets)
        Log.info("saved preset \(preset.name): \(preset.apps.map(\.name).joined(separator: ", "))")
    }

    @objc private func openPreset(_ sender: NSMenuItem) {
        let presets = PresetStore.load()
        guard presets.indices.contains(sender.tag), let screen = Geometry.screenUnderMouse() else { return }
        wm.openPreset(presets[sender.tag], screen: screen)
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        var presets = PresetStore.load()
        guard presets.indices.contains(sender.tag) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete the preset \u{201C}\(presets[sender.tag].name)\u{201D}?"
        alert.informativeText = "The apps and their windows aren't affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presets.remove(at: sender.tag)
        PresetStore.save(presets)
    }

    @objc private func openSettings() {
        settingsWindow.show(current: wm.settings)
    }

    @objc private func toggleStartAtLogin() {
        LoginItem.set(!LoginItem.isEnabled)
        if LoginItem.needsApproval { LoginItem.openSystemSettings() }
        settingsWindow.refresh(wm.settings)
    }

    @objc private func toggleTiling() { wm.setEnabled(!wm.enabled) }
    @objc private func toggleSpaceTiling() { wm.perform("toggleSpaceTiling") }

    /// On: windows peeking over an edge are captured continuously (video keeps playing).
    /// Off: one picture when a window starts to peek, shown as is.
    @objc private func toggleLivePeek() {
        let on = !wm.settings.livePeek
        SettingsOverrides.set(["livePeek"], on)
        wm.setLivePeek(on)
        settingsWindow.refresh(wm.settings)
    }

    /// On: while the strip moves every window is a snapshot, the real ones move once at the end.
    @objc private func toggleSmoothScroll() {
        let on = !wm.settings.smoothScroll
        SettingsOverrides.set(["smoothScroll"], on)
        wm.setSmoothScroll(on)
        settingsWindow.refresh(wm.settings)
    }

    /// On: every swipe comes to rest with a window at the top of the scroll area. Off: free
    /// scrolling, as the config has it (by default it only settles on an edge it ends near).
    @objc private func toggleMagneticScroll() {
        if wm.settings.swipe.snap == .always {
            SettingsOverrides.remove(["swipe", "snap"])
            // The config may itself ask for it; then free means "near".
            if configSettings.swipe.snap == .always { SettingsOverrides.set(["swipe", "snap"], SnapMode.near.rawValue) }
        } else {
            SettingsOverrides.set(["swipe", "snap"], SnapMode.always.rawValue)
        }
        applySettings()
    }

    @objc private func setScrollArea() {
        guard let screen = Geometry.screenUnderMouse() else { return }
        openScrollAreaEditor(screen)
    }

    @objc private func resetScrollArea() {
        guard let screen = Geometry.screenUnderMouse() else { return }
        wm.setScrollArea(nil, screen: screen)
    }

    /// The editor covers the screen; the area is saved for the desktop shown there.
    private func openScrollAreaEditor(_ screen: NSScreen) {
        guard areaEditor == nil else { return }
        let editor = ScrollAreaEditor(screen: screen, fraction: wm.scrollAreaFraction(screen)) { [weak self] area in
            self?.wm.setScrollArea(area, screen: screen)
        }
        areaEditor = editor
        editor.onClose = { [weak self] in self?.areaEditor = nil }
        editor.show()
    }

    /// Dimmed while Oz doesn't tile what's on screen (off, or off for this desktop).
    private func updateStatusIcon() {
        let tiled = wm.enabled && (Geometry.screenUnderMouse().map(wm.isTiled) ?? true)
        statusItem.button?.appearsDisabled = !tiled
    }
    @objc private func retile() { wm.perform("retile") }
    @objc private func reloadConfig() { config.load() }

    @objc private func editConfig() {
        config.ensureConfigFile()
        SystemActions.run("/usr/bin/open", ["-t", ConfigEngine.configURL.path])
    }

    @objc private func revealConfig() {
        config.ensureConfigFile()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigEngine.configURL])
    }

    @objc private func openLog() {
        SystemActions.run("/usr/bin/open", ["-a", "Console", Log.url.path])
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
        wm.snapshots.requestPermissionOnce()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
