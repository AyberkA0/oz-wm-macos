import Cocoa

// What the signal handler uses, made ready beforehand: in it nothing may be allocated and
// little may be called (the crash may have happened anywhere, with any lock held).
private var openPath: UnsafeMutablePointer<CChar>?
private var respawnArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var rescueArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var spawnEnvironment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
/// 1 while a crash would be the second in a row (this Oz was started after one, just now).
private var crashedBefore: Int32 = 0
private var handlingCrash: Int32 = 0

/// A signal that ends the process (a crash): another Oz is started before it does, then the
/// signal goes on to do what it always does, so macOS still writes its crash report.
private func onFatalSignal(_ sig: Int32) {
    if handlingCrash == 0 {
        handlingCrash = 1
        var pid: pid_t = 0
        _ = posix_spawn(&pid, openPath, nil, nil, crashedBefore != 0 ? rescueArgv : respawnArgv, spawnEnvironment)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// When Oz crashes, most windows are where it parked them: out of view at a corner of the
/// screen, and nothing brings them back. So a crashing Oz starts another one, which finds
/// the windows and the saved layout and carries on (`--after-crash`). If that one crashes
/// too within a minute, starting a third would likely go the same way: instead a rescue
/// (`--rescue`) puts every window back on screen, says so, and leaves Oz closed.
/// A forced quit (SIGKILL) can't be caught: then opening Oz again is what brings them back.
enum CrashRecovery {
    static let afterCrashFlag = "--after-crash"
    static let rescueFlag = "--rescue"
    /// This Oz was started by one that crashed.
    private(set) static var startedAfterCrash = false

    static func install(afterCrash: Bool) {
        startedAfterCrash = afterCrash
        // Run from its app bundle only: `open` starts that again (a bare binary is a
        // developer's run, with a debugger or a terminal to see it stop).
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { return }
        func arguments(_ flag: String) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
            let items = ["open", "-n", "-a", bundle, "--args", flag]
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: items.count + 1)
            for (i, item) in items.enumerated() { argv[i] = strdup(item) }
            argv[items.count] = nil
            return argv
        }
        openPath = strdup("/usr/bin/open")
        respawnArgv = arguments(afterCrashFlag)
        rescueArgv = arguments(rescueFlag)
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: environment.count + 1)
        for (i, item) in environment.enumerated() { envp[i] = strdup(item) }
        envp[environment.count] = nil
        spawnEnvironment = envp
        if afterCrash {
            crashedBefore = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { crashedBefore = 0 }
        }
        // A stack of its own for the handler: a crash from running out of stack has none left.
        let size = max(Int(SIGSTKSZ), 64 * 1024)
        var stack = stack_t(ss_sp: malloc(size), ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
        var action = sigaction()
        action.__sigaction_u.__sa_handler = onFatalSignal
        action.sa_flags = SA_ONSTACK
        sigemptyset(&action.sa_mask)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] { sigaction(sig, &action, nil) }
    }

    /// Oz crashed twice in a row: every window that is out of view comes back on screen,
    /// macOS's wallpaper tinting is as it was, and Oz stays closed.
    static func runRescue() -> Never {
        Log.info("Oz crashed twice in a row: putting the windows back on screen, not starting again")
        let moved = bringWindowsBack()
        AppDelegate.restoreWallpaperTinting()
        Log.info("rescue: \(moved) window(s) back on screen")
        Log.flush()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Without this the alert's modal session ends as soon as it starts.
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Oz stopped unexpectedly, twice in a row"
        alert.informativeText = """
        It hasn't started again. \(moved == 0 ? "No window was out of view." : "\(moved) window\(moved == 1 ? "" : "s") it had moved out of view \(moved == 1 ? "is" : "are") back on screen.")

        Oz's log and macOS's crash report say what went wrong. Opening Oz starts it as usual.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Log")
        if alert.runModal() == .alertSecondButtonReturn {
            SystemActions.run("/usr/bin/open", ["-a", "Console", Log.url.path])
        }
        exit(0)
    }

    /// Moves every app window of which (almost) nothing is on any screen back onto the screen
    /// it is nearest to, one a little below and right of the other. Returns how many.
    private static func bringWindowsBack() -> Int {
        guard AXIsProcessTrusted() else { return 0 }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != getpid() && WindowManager.hasWindows($0) && !$0.isHidden }
            .map(\.processIdentifier)
        let screens = NSScreen.screens.map { Geometry.ax($0.frame) }
        var moved = 0
        var offset: CGFloat = 0
        for probe in WindowProbe.readApps(pids) where probe.manageable {
            guard let frame = probe.frame else { continue }
            // In view: a piece of it someone could grab, on some screen.
            let inView = screens.contains { s in
                let part = s.intersection(frame)
                return !part.isNull && part.width >= 40 && part.height >= 40
            }
            guard !inView, let screen = Geometry.screen(containingAX: frame.origin) else { continue }
            let area = Geometry.ax(screen.visibleFrame).insetBy(dx: 20, dy: 20)
            let size = CGSize(width: min(frame.width, area.width - offset), height: min(frame.height, area.height - offset))
            AX.setPosition(probe.element, CGPoint(x: area.minX + offset, y: area.minY + offset))
            AX.setSize(probe.element, size)
            offset = (offset + 28).truncatingRemainder(dividingBy: 280)
            moved += 1
        }
        return moved
    }
}
