import Carbon.HIToolbox
import Cocoa

/// A button that can scroll the strip: a mouse button (side buttons are 3 and up), a key with
/// its modifiers, or a media key (volume, play, ...), which is what some mice's side buttons send.
struct InputTrigger: Equatable {
    enum Kind: Equatable {
        case mouse(Int64)
        case key(Int64, UInt64)
        case media(Int)
    }
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    /// From its stored form: "mouse:3", "key:123:262144", "media:0".
    init?(_ string: String?) {
        guard let parts = string?.split(separator: ":"), let tag = parts.first else { return nil }
        let n = parts.dropFirst().compactMap { Int64($0) }
        switch (tag, n.count) {
        case ("mouse", 1): kind = .mouse(n[0])
        case ("key", 2): kind = .key(n[0], UInt64(n[1]))
        case ("media", 1): kind = .media(Int(n[0]))
        default: return nil
        }
    }

    var string: String {
        switch kind {
        case .mouse(let b): return "mouse:\(b)"
        case .key(let k, let m): return "key:\(k):\(m)"
        case .media(let c): return "media:\(c)"
        }
    }

    /// For the Settings window: "Mouse button 4", "⌃⌥F13", "Volume Up".
    var label: String {
        switch kind {
        case .mouse(let b): return "Mouse button \(b + 1)"
        case .media(let c): return Self.mediaNames[c] ?? "Media key \(c)"
        case .key(let k, let m):
            let flags = CGEventFlags(rawValue: m)
            var s = ""
            if flags.contains(.maskControl) { s += "⌃" }
            if flags.contains(.maskAlternate) { s += "⌥" }
            if flags.contains(.maskShift) { s += "⇧" }
            if flags.contains(.maskCommand) { s += "⌘" }
            return s + Self.keyName(Int(k))
        }
    }

    static let modifierMask: UInt64 = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue

    private static let mediaNames: [Int: String] = [
        0: "Volume Up", 1: "Volume Down", 2: "Brightness Up", 3: "Brightness Down", 7: "Mute",
        16: "Play/Pause", 17: "Next Track", 18: "Previous Track", 19: "Fast Forward", 20: "Rewind",
    ]

    private static func keyName(_ code: Int) -> String {
        let named: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_Home: "Home", kVK_End: "End",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Esc",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let n = named[code] { return n }
        // What the key types in the current layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Scrolls the strip with buttons the user picked (Settings › Mouse buttons): an event tap
/// sees mouse buttons, keys and media keys, takes the picked ones (their own action, a
/// browser's "back", the volume, doesn't happen as well) and scrolls a step instead. It also
/// listens for the next button pressed, for the Settings window to pick one.
final class ScrollButtons {
    private(set) var up: InputTrigger?
    private(set) var down: InputTrigger?
    /// A picked button was pressed: -1 up, +1 down.
    var onScroll: ((Int) -> Void)?
    /// Held with a picked button, it switches desktop instead (`onDesktop`: -1 the one on the
    /// left, +1 the one on the right). Nil: no such key.
    var desktopModifier: CGEventFlags?
    var onDesktop: ((Int) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// The kinds of event the tap watches now (0: no tap).
    private var tapMask: CGEventMask = 0
    /// The tap is to watch fewer kinds, once the buttons it took a press of are let go.
    private var retuneWhenReleased = false
    private var listener: ((InputTrigger?) -> Void)?
    /// Presses taken, whose release must be taken too (or the app gets a lone mouse-up).
    private var heldMouse = Set<Int64>()
    private var heldKeys = Set<Int64>()
    private var heldMedia = Set<Int>()

    func set(up: InputTrigger?, down: InputTrigger?) {
        self.up = up
        self.down = down
        retune()
    }

    /// The next button pressed (taken, not passed on) goes to `done`; Esc gives nil.
    func listen(_ done: @escaping (InputTrigger?) -> Void) {
        listener = done
        retune()
    }

    func stopListening() {
        listener = nil
        retune()
    }

    private static let mouseMask: CGEventMask = 1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue
    private static let keyMask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
    private static let mediaMask: CGEventMask = 1 << 14  // NX_SYSDEFINED: media keys

    /// The kinds of event the tap has to watch: those the picked buttons are, and every kind
    /// while listening for one to pick. Every event of a watched kind goes through Oz before
    /// its app gets it, so with a mouse button picked the keyboard is left alone.
    private var wantedMask: CGEventMask {
        if listener != nil { return Self.mouseMask | Self.keyMask | Self.mediaMask }
        var mask: CGEventMask = 0
        for t in [up, down] {
            switch t?.kind {
            case .mouse: mask |= Self.mouseMask
            case .key: mask |= Self.keyMask
            case .media: mask |= Self.mediaMask
            case nil: break
            }
        }
        return mask
    }

    /// Makes the tap watch what is wanted now: a new tap for other kinds, none for nothing.
    private func retune() {
        let mask = wantedMask
        guard mask != tapMask else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Fewer kinds, with a press taken whose release is still to come: that must be taken
        // too, so wait for it. More kinds can't wait (a button is about to be picked).
        let fewer = mask & ~tapMask == 0
        if fewer && !(heldMouse.isEmpty && heldKeys.isEmpty && heldMedia.isEmpty) {
            retuneWhenReleased = true
            return
        }
        retuneWhenReleased = false
        stopTap()
        if mask != 0 { startTap(mask) }
    }

    private func stopTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        tapMask = 0
        heldMouse.removeAll()
        heldKeys.removeAll()
        heldMedia.removeAll()
    }

    private func startTap(_ mask: CGEventMask) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ScrollButtons>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: me) else {
            Log.info("scroll buttons: no event tap (Accessibility permission?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = source
        tapMask = mask
        Log.debug("scroll buttons: watching\(mask & Self.mouseMask != 0 ? " mouse buttons" : "")\(mask & Self.keyMask != 0 ? " keys" : "")\(mask & Self.mediaMask != 0 ? " media keys" : "")")
    }

    /// The press or release `event` is, if it is one of the kinds a button can be (`down`: pressed).
    private func trigger(_ type: CGEventType, _ event: CGEvent) -> (InputTrigger, down: Bool)? {
        switch type {
        case .otherMouseDown, .otherMouseUp:
            return (InputTrigger(.mouse(event.getIntegerValueField(.mouseEventButtonNumber))), type == .otherMouseDown)
        case .keyDown, .keyUp:
            let mods = event.flags.rawValue & InputTrigger.modifierMask
            return (InputTrigger(.key(event.getIntegerValueField(.keyboardEventKeycode), mods)), type == .keyDown)
        case CGEventType(rawValue: 14)!:
            // A media key: NSEvent subtype 8, key code and state packed in data1.
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return nil }
            let code = (ns.data1 & 0xFFFF_0000) >> 16, state = (ns.data1 & 0xFF00) >> 8
            return (InputTrigger(.media(code)), state == 0xA)
        default:
            return nil
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let (t, down) = trigger(type, event) else { return Unmanaged.passUnretained(event) }
        if down, let done = listener {
            listener = nil
            hold(t)
            // Esc (alone) cancels.
            let cancel = t == InputTrigger(.key(Int64(kVK_Escape), 0))
            DispatchQueue.main.async { done(cancel ? nil : t) }
            return nil
        }
        if !down, release(t) {
            // Not from inside the tap's own callback.
            if retuneWhenReleased { DispatchQueue.main.async { [weak self] in self?.retune() } }
            return nil
        }
        // With the desktop key held: switch desktop. A key button counts with that key added.
        if down, let mod = desktopModifier, event.flags.contains(mod) {
            var bare = t
            if case .key(let k, let m) = t.kind { bare = InputTrigger(.key(k, m & ~mod.rawValue)) }
            if bare == self.up || bare == self.down {
                hold(t)
                // Not again while held: one desktop per press.
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
                let dir = bare == self.down ? 1 : -1
                DispatchQueue.main.async { [weak self] in self?.onDesktop?(dir) }
                return nil
            }
        }
        guard down, t == self.up || t == self.down else { return Unmanaged.passUnretained(event) }
        // Held keys repeat: one step per repeat, like holding an arrow key.
        hold(t)
        let dir = t == self.down ? 1 : -1
        DispatchQueue.main.async { [weak self] in self?.onScroll?(dir) }
        return nil
    }

    private func hold(_ t: InputTrigger) {
        switch t.kind {
        case .mouse(let b): heldMouse.insert(b)
        case .key(let k, _): heldKeys.insert(k)
        case .media(let c): heldMedia.insert(c)
        }
    }

    /// A release of a press that was taken: taken too.
    private func release(_ t: InputTrigger) -> Bool {
        switch t.kind {
        case .mouse(let b): return heldMouse.remove(b) != nil
        case .key(let k, _): return heldKeys.remove(k) != nil
        case .media(let c): return heldMedia.remove(c) != nil
        }
    }
}
