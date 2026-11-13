import Cocoa

/// The app's version, from its Info.plist ("dev" for a bare binary, which has none).
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "msg":
    // OzWM msg <command> [arg]  — drive a running Oz from the shell (skhd, scripts, ...).
    guard args.count >= 2 else {
        FileHandle.standardError.write("usage: OzWM msg <command> [arg]\n".data(using: .utf8)!)
        exit(1)
    }
    // Oz answers on a name of this process's own: whether it knew the command and did it.
    let center = DistributedNotificationCenter.default()
    let reply = "dev.oz.wm.reply.\(getpid())"
    var answer: String?
    let observer = center.addObserver(forName: Notification.Name(reply), object: nil, queue: nil) { answer = $0.object as? String }
    var info = ["reply": reply]
    if args.count >= 3 { info["arg"] = args[2] }
    center.postNotificationName(commandNotification, object: args[1], userInfo: info, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(1)
    while answer == nil, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    center.removeObserver(observer)
    func fail(_ message: String, _ status: Int32) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(status)
    }
    switch answer {
    case "ok": exit(0)
    case "unknown": fail("Oz has no command named '\(args[1])'", 1)
    case nil: fail("no answer from Oz: it isn't running (or is still waiting for Accessibility)", 2)
    default: fail("Oz had nothing to do for '\(args[1])' (no window to act on, or a value it doesn't take)", 1)
    }
case "demo":
    // The demo app: Wizard of Oz windows for demo mode, started by Oz itself.
    Demo.runApp(firstTheme: args.count >= 2 ? Int(args[1]) ?? 0 : 0)
case "--print-default-config":
    print(DefaultConfig.source)
    exit(0)
case "--check-config":
    // Load the config without touching any windows and report what it did.
    let engine = ConfigEngine(wm: WindowManager())
    engine.dryRun = true
    engine.load()
    let s = engine.settings
    print("config: \(ConfigEngine.configURL.path)")
    print("gap=\(s.gap) outerGap=\(s.outerGap) width=\(s.width) heights=\(s.heights) defaultHeight=\(s.defaultHeight)")
    print("swipe: enabled=\(s.swipe.enabled) fingers=\(s.swipe.fingers) sensitivity=\(s.swipe.sensitivity) natural=\(s.swipe.natural) snap=\(s.swipe.snap)")
    print("doubleTap: enabled=\(s.doubleTap.enabled) fingers=\(s.doubleTap.fingers) action=\(s.doubleTap.action)")
    print("bindings (\(engine.boundCombos.count)): \(engine.boundCombos.joined(separator: ", "))")
    engine.warnings.forEach { print("WARNING: \($0)") }
    if let e = engine.lastError {
        print("ERROR: \(e)")
        exit(1)
    }
    if !engine.warnings.isEmpty { exit(1) }
    print("OK")
    exit(0)
case CrashRecovery.rescueFlag:
    // Started by an Oz that crashed for the second time in a row.
    CrashRecovery.runRescue()
case "--version":
    print("Oz WM \(version)")
    exit(0)
default:
    break
}

// One Oz at a time: two would each move the windows, against each other. The lock is on
// the file for as long as this process lives, however it ends.
let instanceLock: Int32 = {
    let path = LayoutStore.url.deletingLastPathComponent().appendingPathComponent("oz.lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    // Can't tell: start anyway.
    guard fd >= 0 else { return -1 }
    // The one before may still be on its way out (a restart): give it a moment. One that
    // crashed takes longer to go (macOS writes its crash report first).
    for _ in 0..<(args.contains(CrashRecovery.afterCrashFlag) ? 300 : 30) {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        usleep(100_000)
    }
    return -2
}()
if instanceLock == -2 {
    Log.info("another Oz is already running: this one quits")
    Log.flush()
    exit(0)
}

CrashRecovery.install(afterCrash: args.contains(CrashRecovery.afterCrashFlag))
if CrashRecovery.startedAfterCrash { Log.info("the Oz before this one crashed: started again in its place") }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
