import Cocoa
import OzCore
import SwiftUI

/// Settings changed in the app (the Settings window, the menu's toggles), kept apart from the
/// config file and applied on top of it: `~/.config/oz/config.js` stays as the user wrote it.
/// Same shape as the config's `oz.set({...})` object, nested `swipe` / `doubleTap` included.
enum SettingsOverrides {
    private static let key = "settingsOverrides"

    static var all: [String: Any] {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        // The menu toggles used to be stored on their own.
        for legacy in ["livePeek", "smoothScroll"] {
            if d[legacy] == nil, let v = UserDefaults.standard.object(forKey: legacy) as? Bool { d[legacy] = v }
        }
        return d
    }

    /// Sets one value; `path` is its place in the config object, e.g. ["swipe", "sensitivity"].
    static func set(_ path: [String], _ value: Any) {
        var d = all
        if path.count == 2 {
            var inner = d[path[0]] as? [String: Any] ?? [:]
            inner[path[1]] = value
            d[path[0]] = inner
        } else if let k = path.first {
            d[k] = value
        }
        UserDefaults.standard.set(d, forKey: key)
        ["livePeek", "smoothScroll"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    /// Drops one value, so the config file's applies again.
    static func remove(_ path: [String]) {
        var d = all
        if path.count == 2, var inner = d[path[0]] as? [String: Any] {
            inner.removeValue(forKey: path[1])
            d[path[0]] = inner.isEmpty ? nil : inner
        } else if let k = path.first {
            d.removeValue(forKey: k)
        }
        UserDefaults.standard.set(d, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        ["livePeek", "smoothScroll"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}

/// The values the Settings window shows and edits.
final class SettingsModel: ObservableObject {
    @Published var s: OzCore.Settings
    /// Called after a change (debounced by the owner).
    var onChange: (() -> Void)?

    init(_ s: OzCore.Settings) { self.s = s }

    /// Picks a scroll button: the next button pressed goes to the callback (nil: cancelled).
    var listen: ((@escaping (String?) -> Void) -> Void)?
    var stopListening: (() -> Void)?
    /// Waiting for a button for scrolling up (-1) or down (+1).
    @Published var listening: Int?

    func pickButton(_ dir: Int) {
        if listening != nil { stopListening?() }
        listening = dir
        listen? { [weak self] value in
            guard let self, self.listening == dir else { return }
            self.listening = nil
            if let value { self.setButton(dir, value) }
        }
    }

    func cancelPick() {
        stopListening?()
        listening = nil
    }

    func setButton(_ dir: Int, _ value: String?) {
        if dir < 0 { s.scrollUpButton = value } else { s.scrollDownButton = value }
        SettingsOverrides.set(["scrollButtons", dir < 0 ? "up" : "down"], value ?? "")
        onChange?()
    }

    /// Not a config setting: macOS keeps it (a login item), so it is read from there.
    @Published var startAtLogin = LoginItem.isEnabled
    @Published var loginNeedsApproval = LoginItem.needsApproval

    var startAtLoginBinding: Binding<Bool> {
        Binding(get: { self.startAtLogin }, set: { on in
            LoginItem.set(on)
            self.refreshLogin()
        })
    }

    func refreshLogin() {
        startAtLogin = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
    }

    /// A binding that writes through to the overrides under `path` (`json` turns the value into
    /// what the config would hold).
    func binding<T>(_ kp: WritableKeyPath<OzCore.Settings, T>, _ path: [String], json: @escaping (T) -> Any) -> Binding<T> {
        Binding(get: { self.s[keyPath: kp] }, set: { v in
            self.s[keyPath: kp] = v
            SettingsOverrides.set(path, json(v))
            self.onChange?()
        })
    }

    func number(_ kp: WritableKeyPath<OzCore.Settings, CGFloat>, _ path: [String]) -> Binding<Double> {
        Binding(get: { Double(self.s[keyPath: kp]) }, set: { v in
            self.s[keyPath: kp] = CGFloat(v)
            SettingsOverrides.set(path, v)
            self.onChange?()
        })
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onReset: () -> Void
    var onEditConfig: () -> Void

    private let heights: [(String, Double)] = [("1/3", 1.0 / 3), ("1/2", 0.5), ("2/3", 2.0 / 3), ("Full", 1)]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at login", isOn: model.startAtLoginBinding)
                if model.loginNeedsApproval {
                    HStack {
                        Text("macOS wants Oz allowed as a login item.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                    }
                }
            }
            Section("Layout") {
                slider("Gap between windows", model.number(\.gap, ["gap"]), 0...40, step: 1, unit: "pt")
                slider("Zone margin", model.number(\.outerGap, ["outerGap"]), 0...40, step: 1, unit: "pt")
                slider("Row width", model.number(\.width, ["width"]), 0.5...1, step: 0.05, percent: true)
                Picker("New window height", selection: model.binding(\.defaultHeight, ["defaultHeight"], json: { Double($0) })) {
                    ForEach(heights, id: \.1) { Text($0.0).tag(CGFloat($0.1)) }
                }
                Picker("New windows open", selection: model.binding(\.newWindowPosition, ["newWindowPosition"], json: { $0.rawValue })) {
                    Text("Below the focused one").tag(InsertPosition.below)
                    Text("Above the focused one").tag(InsertPosition.above)
                    Text("At the end").tag(InsertPosition.end)
                    Text("At the start").tag(InsertPosition.start)
                }
                slider("Animation length", model.binding(\.animationDuration, ["animationDuration"], json: { $0 }), 0...0.6, step: 0.05, unit: "s")
            }
            Section("Scrolling") {
                slider("Swipe sensitivity", model.binding(\.swipe.sensitivity, ["swipe", "sensitivity"], json: { $0 }), 0.5...3, step: 0.1)
                Toggle("Natural direction", isOn: model.binding(\.swipe.natural, ["swipe", "natural"], json: { $0 }))
                Picker("Coming to rest", selection: model.binding(\.swipe.snap, ["swipe", "snap"], json: { $0.rawValue })) {
                    Text("Settle on a window edge when close").tag(SnapMode.near)
                    Text("Always a window at the top").tag(SnapMode.always)
                    Text("Wherever it stops").tag(SnapMode.off)
                }
                slider("Glide after a flick", model.binding(\.swipe.momentum, ["swipe", "momentum"], json: { $0 }), 0...2, step: 0.1)
                Toggle("Smooth scrolling (snapshots while moving)", isOn: model.binding(\.smoothScroll, ["smoothScroll"], json: { $0 }))
            }
            Section("Windows at the edges") {
                Picker("Cut off at an edge", selection: model.binding(\.topOverflow, ["topOverflow"], json: { $0.rawValue })) {
                    Text("Slide off (drawn from a capture)").tag(TopOverflow.slide)
                    Text("Shrink to the visible part").tag(TopOverflow.shrink)
                    Text("Hide").tag(TopOverflow.hide)
                }
                Toggle("Keep them alive (live capture)", isOn: model.binding(\.livePeek, ["livePeek"], json: { $0 }))
                slider("Live capture rate", model.binding(\.livePeekFPS, ["livePeekFPS"], json: { $0 }), 4...30, step: 1, unit: "fps")
                    .disabled(!model.s.livePeek)
                Picker("Capture resolution", selection: model.binding(\.captureScale, ["captureScale"], json: { Double($0) })) {
                    Text("1x (same as the window, lossless)").tag(CGFloat(1))
                    Text("0.75x").tag(CGFloat(0.75))
                    Text("0.5x").tag(CGFloat(0.5))
                    Text("0.25x").tag(CGFloat(0.25))
                    if ![1, 0.75, 0.5, 0.25].contains(model.s.captureScale) {
                        Text("\(String(format: "%.2f", model.s.captureScale))x (set in the config)").tag(model.s.captureScale)
                    }
                }
            }
            Section("Trackpad") {
                Toggle("Three-finger double tap", isOn: model.binding(\.doubleTap.enabled, ["doubleTap", "enabled"], json: { $0 }))
                Picker("Double tap opens", selection: model.binding(\.doubleTap.action, ["doubleTap", "action"], json: { $0 })) {
                    Text("Mission Control").tag("missionControl")
                    Text("App Exposé").tag("appExpose")
                    Text("Show Desktop").tag("showDesktop")
                    Text("Launchpad").tag("launchpad")
                    if !["missionControl", "appExpose", "showDesktop", "launchpad"].contains(model.s.doubleTap.action) {
                        Text("Set in the config").tag(model.s.doubleTap.action)
                    }
                }
                .disabled(!model.s.doubleTap.enabled)
            }
            Section("Demo") {
                Toggle("Demo mode", isOn: model.binding(\.demoMode, ["demoMode"], json: { $0 }))
                Text("⌃⌥⇧O opens a Wizard of Oz window to show Oz with. Turning it off closes them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Mouse buttons") {
                buttonRow("Scroll up", -1, model.s.scrollUpButton)
                buttonRow("Scroll down", 1, model.s.scrollDownButton)
                Picker("Switch desktop while holding", selection: model.binding(\.desktopModifier, ["scrollButtons", "desktopModifier"], json: { $0 })) {
                    Text("Shift").tag("shift")
                    Text("Control").tag("control")
                    Text("Option").tag("option")
                    Text("Command").tag("command")
                    Text("Off").tag("none")
                }
                Text("Click Set…, then press the button to use: a mouse's side button, a key or a media key. Esc cancels. With magnetic scrolling each press moves one window, otherwise half a screen. Held with the key above, up goes to the desktop on the left and down to the one on the right.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("These settings apply on top of ~/.config/oz/config.js, which is left as it is. Shortcuts and window rules are set there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit Config…", action: onEditConfig)
                    Spacer()
                    Button("Reset to Config", action: onReset)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func buttonRow(_ title: String, _ dir: Int, _ value: String?) -> some View {
        LabeledContent(title) {
            HStack {
                Text(model.listening == dir ? "Press a button…" : InputTrigger(value)?.label ?? "Not set")
                    .foregroundStyle(model.listening == dir ? .primary : .secondary)
                if model.listening == dir {
                    Button("Cancel") { model.cancelPick() }
                } else {
                    Button("Set…") { model.pickButton(dir) }
                    if value != nil { Button("Clear") { model.setButton(dir, nil) } }
                }
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        unit: String = "", percent: Bool = false) -> some View {
        LabeledContent(title) {
            HStack {
                // No tick marks (dozens of them crowd the row); values still go in `step`s.
                Slider(value: Binding(get: { value.wrappedValue },
                                      set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }),
                       in: range)
                    .frame(width: 180)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%"
                             : step >= 1 ? "\(Int(value.wrappedValue)) \(unit)"
                                         : String(format: "%.2f %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The Settings window (menu bar › Settings…, ⌘,).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?
    private var pending: DispatchWorkItem?
    /// Called when a setting changed (a moment after, so a dragged slider doesn't relayout
    /// on every step), and with true after a reset.
    var apply: ((_ reset: Bool) -> Void)?
    var editConfig: (() -> Void)?
    /// Listening for a scroll button (see `SettingsModel.listen`).
    var listen: ((@escaping (String?) -> Void) -> Void)?
    var stopListening: (() -> Void)?

    func show(current: OzCore.Settings) {
        if let window, let model {
            model.s = current
            model.refreshLogin()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel(current)
        model.onChange = { [weak self] in self?.scheduleApply() }
        model.listen = listen
        model.stopListening = stopListening
        let view = SettingsView(model: model, onReset: { [weak self] in
            SettingsOverrides.reset()
            self?.pending?.cancel()
            self?.apply?(true)
        }, onEditConfig: { [weak self] in self?.editConfig?() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Oz Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: view)
        w.center()
        self.window = w
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The settings now in effect (after a reset or a config reload) for the open window.
    func refresh(_ s: OzCore.Settings) {
        model?.s = s
        model?.refreshLogin()
    }

    private func scheduleApply() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply?(false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func windowWillClose(_ notification: Notification) {
        if model?.listening != nil { model?.cancelPick() }
        // Drop the SwiftUI view while it isn't shown; it's rebuilt on the next open.
        window?.contentView = nil
        window = nil
        model = nil
    }
}
