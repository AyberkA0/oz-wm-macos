import Carbon.HIToolbox
import Cocoa

/// Global hotkeys via Carbon's RegisterEventHotKey (needs no extra permission).
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private struct Entry {
        /// As written ("ctrl+alt+ö"): which key that is depends on the keyboard layout.
        let combo: String
        var code: UInt32
        var mods: UInt32
        var ref: EventHotKeyRef?
    }

    private var entries: [UInt32: Entry] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    /// While suspended no combo is grabbed, so every key reaches the frontmost app
    /// (remote desktops and streaming clients that have shortcuts of their own).
    private(set) var suspended = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        // Another keyboard layout: the keys named by what they type ("ö", "ğ") are elsewhere.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.layoutChanged() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if status == noErr { HotkeyCenter.shared.fire(hk.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        // A combo started with the modifiers of a held one: that wasn't the hold.
        HoldShortcuts.shared.interrupt()
        guard !suspended else { return }
        actions[id]?()
    }

    private func grab(_ id: UInt32, code: UInt32, mods: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4F5A_574D), id: id) // 'OZWM'
        let status = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    @discardableResult
    private func add(_ combo: String, action: @escaping () -> Void) -> UInt32? {
        installHandler()
        guard let (code, mods) = HotkeyCenter.parse(combo) else { return nil }
        let id = nextID
        nextID += 1
        var entry = Entry(combo: combo, code: code, mods: mods, ref: nil)
        if !suspended {
            guard let ref = grab(id, code: code, mods: mods) else { return nil }
            entry.ref = ref
        }
        entries[id] = entry
        actions[id] = action
        return id
    }

    func register(_ combo: String, action: @escaping () -> Void) -> Bool {
        add(combo, action: action) != nil
    }

    /// Registers a hotkey for a short while (e.g. Esc while an editor is up); call the
    /// returned closure to remove it. Survives nothing: `unregisterAll` drops it too.
    func registerTemporary(_ combo: String, action: @escaping () -> Void) -> (() -> Void)? {
        guard let id = add(combo, action: action) else { return nil }
        return { [weak self] in
            guard let self, let entry = self.entries.removeValue(forKey: id) else { return }
            self.actions[id] = nil
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
        }
    }

    func unregisterAll() {
        HoldShortcuts.shared.unregisterAll()
        entries.values.forEach { if let ref = $0.ref { UnregisterEventHotKey(ref) } }
        entries = [:]
        actions = [:]
    }

    /// Lets go of every combo (they stay known) until `resume`.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (id, e) in entries {
            if let ref = e.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for (id, e) in entries { entries[id]?.ref = grab(id, code: e.code, mods: e.mods) }
    }

    /// The keyboard layout changed: every combo is looked up again, and those now on another
    /// key move there. One the new layout has no key for stays on the key it had.
    private func layoutChanged() {
        var moved = 0
        for (id, e) in entries {
            guard let (code, mods) = HotkeyCenter.parse(e.combo), code != e.code || mods != e.mods else { continue }
            if let ref = e.ref { UnregisterEventHotKey(ref) }
            entries[id]?.code = code
            entries[id]?.mods = mods
            entries[id]?.ref = suspended ? nil : grab(id, code: code, mods: mods)
            if !suspended && entries[id]?.ref == nil { Log.info("shortcut \(e.combo): its key in the new layout is taken") }
            moved += 1
        }
        if moved > 0 { Log.info("keyboard layout changed: \(moved) shortcut(s) moved to their new keys") }
    }

    /// Parses "ctrl+alt+shift+k", "cmd+option+left", "hyper+1".
    static func parse(_ combo: String) -> (UInt32, UInt32)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let code = keyCode(for: keyName) else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "super": mods |= UInt32(cmdKey)
            case "alt", "option", "opt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            case "hyper": mods |= UInt32(cmdKey | optionKey | controlKey | shiftKey)
            case "meh": mods |= UInt32(optionKey | controlKey | shiftKey)
            default: return nil
            }
        }
        return (UInt32(code), mods)
    }

    /// Named keys ("left", "f5", …) are fixed; a single character is looked up in the
    /// active keyboard layout first, so "ö", "ğ", "ı" or "i" hit the key that types them
    /// (Turkish Q puts "i" where US has "'"), falling back to US key positions.
    static func keyCode(for name: String) -> Int? {
        if name.count == 1, let code = layoutKeyCodes()[name] { return code }
        return keyCodes[name]
    }

    /// Character -> key code for the current keyboard layout (unmodified key presses).
    private static func layoutKeyCodes() -> [String: Int] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [String: Int] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            // 0..<64 covers the main keys; the keypad (65+) would shadow "." "-" and digits.
            for code in 0..<64 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let ch = String(utf16CodeUnits: chars, count: length)
                if map[ch] == nil { map[ch] = code }
            }
        }
        return map
    }

    private static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "return": kVK_Return, "enter": kVK_Return, "space": kVK_Space, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "period": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash,
            "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                     kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                     kVK_F18, kVK_F19, kVK_F20]
        for (i, k) in fkeys.enumerated() { m["f\(i + 1)"] = k }
        return m
    }()
}

/// Shortcuts made of modifier keys alone, held down a while ("fn" for 2 s), optionally with
/// an action for when they are let go again (a mode that lasts while they are held).
/// RegisterEventHotKey needs a key besides the modifiers, so these watch the modifier keys
/// themselves (event monitors, which the Accessibility permission covers). Any key or
/// click while they are down, or another modifier, starts over: the modifiers were the
/// start of something else (⌃⌥⇧J, a ⌃ click).
final class HoldShortcuts {
    static let shared = HoldShortcuts()

    private struct Entry {
        let mods: NSEvent.ModifierFlags
        let seconds: Double
        let action: () -> Void
        let release: (() -> Void)?
    }

    private var entries: [Entry] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    /// The modifiers now down have fired their shortcut already: not again until let go.
    private var fired = false
    /// Fired, and waiting for the keys to be let go to run its release action.
    private var held: Entry?

    private static let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    /// "ctrl+alt+shift", "meh", "hyper", "fn": only modifiers. nil when there is a key in it.
    static func parse(_ combo: String) -> NSEvent.ModifierFlags? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for m in parts {
            switch m {
            case "cmd", "command", "super": mods.insert(.command)
            case "alt", "option", "opt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            case "fn", "globe": mods.insert(.function)
            case "hyper": mods.formUnion([.command, .option, .control, .shift])
            case "meh": mods.formUnion([.option, .control, .shift])
            default: return nil
            }
        }
        return mods
    }

    /// `release`: run when the keys are let go after `action` ran.
    func register(_ combo: String, seconds: Double, action: @escaping () -> Void, release: (() -> Void)? = nil) -> Bool {
        guard let mods = HoldShortcuts.parse(combo), seconds > 0 else { return false }
        entries.append(Entry(mods: mods, seconds: seconds, action: action, release: release))
        watch()
        return true
    }

    func unregisterAll() {
        entries = []
        held = nil
        interrupt()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    /// Something else happened while the modifiers were down: no hold this time.
    func interrupt() {
        timer?.invalidate()
        timer = nil
        if !entries.isEmpty { fired = true }
    }

    private func watch() {
        guard monitors.isEmpty else { return }
        let others: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.changed(e.modifierFlags) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: others, handler: { [weak self] _ in self?.interrupt() }) {
            monitors.append(m)
        }
        // Oz's own windows (Settings) in front.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.changed(e.modifierFlags); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: others, handler: { [weak self] e in self?.interrupt(); return e }) {
            monitors.append(m)
        }
    }

    private func changed(_ flags: NSEvent.ModifierFlags) {
        timer?.invalidate()
        timer = nil
        let mods = flags.intersection(HoldShortcuts.watched)
        // Let go (or another modifier pressed with them): what lasted while held ends.
        if let h = held, mods != h.mods {
            held = nil
            h.release?()
        }
        // Every modifier let go (or another set pressed): the next hold may fire.
        fired = false
        guard !mods.isEmpty, let entry = entries.first(where: { $0.mods == mods }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: entry.seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            guard !self.fired, !HotkeyCenter.shared.suspended else { return }
            // Still exactly these, as macOS has them now.
            guard NSEvent.modifierFlags.intersection(HoldShortcuts.watched) == entry.mods else { return }
            self.fired = true
            if entry.release != nil { self.held = entry }
            entry.action()
        }
    }
}
