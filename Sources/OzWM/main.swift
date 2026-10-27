import Cocoa

let version = "0.3.2beta"

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "msg":
    // OzWM msg <command> [arg]  — drive a running Oz from the shell (skhd, scripts, ...).
    guard args.count >= 2 else {
        FileHandle.standardError.write("usage: OzWM msg <command> [arg]\n".data(using: .utf8)!)
        exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(
        commandNotification, object: args[1],
        userInfo: args.count >= 3 ? ["arg": args[2]] : nil, deliverImmediately: true)
    exit(0)
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
    if let e = engine.lastError {
        print("ERROR: \(e)")
        exit(1)
    }
    print("OK")
    exit(0)
case "--version":
    print("Oz WM \(version)")
    exit(0)
default:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
