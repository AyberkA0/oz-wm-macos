import Foundation
import JavaScriptCore
import OzCore

/// Loads ~/.config/oz/config.js into a JavaScriptCore context, the way PaperWM
/// loads user.js. The config talks to Oz through the global `oz` object.
final class ConfigEngine {
    private let wm: WindowManager
    private var context: JSContext?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var lastModified: Date?
    private(set) var lastError: String?
    /// What the config asks for that Oz can't do, though it loaded: settings it doesn't know,
    /// values it doesn't take, shortcuts for commands that don't exist or that couldn't be set.
    var warnings: [String] { settingsProblems + bindProblems }
    private var settingsProblems: [String] = []
    private var bindProblems: [String] = []
    private(set) var settings = Settings()
    /// Validate only: parse hotkeys without registering them (`OzWM --check-config`).
    var dryRun = false
    private(set) var boundCombos: [String] = []

    /// Called on the main thread after every (re)load.
    var onLoaded: ((Settings) -> Void)?

    init(wm: WindowManager) {
        self.wm = wm
    }

    static var configURL: URL {
        if let p = ProcessInfo.processInfo.environment["OZ_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/oz/config.js")
    }

    /// The file itself, when the config is a link to it.
    static var resolvedURL: URL { configURL.resolvingSymlinksInPath() }

    func ensureConfigFile() {
        let url = ConfigEngine.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? DefaultConfig.source.write(to: url, atomically: true, encoding: .utf8)
        Log.info("wrote default config to \(url.path)")
    }

    func load() {
        if !dryRun { HotkeyCenter.shared.unregisterAll() }
        boundCombos = []
        lastError = nil
        settingsProblems = []
        bindProblems = []
        settings = Settings()
        ensureConfigFile()

        guard let ctx = JSContext() else { return }
        ctx.name = "Oz config"
        ctx.exceptionHandler = { [weak self] _, ex in
            let msg = ex?.toString() ?? "unknown error"
            let line = ex?.objectForKeyedSubscript("line")?.toString() ?? "?"
            self?.lastError = "line \(line): \(msg)"
            Log.info("config error: line \(line): \(msg)")
        }

        let native = JSValue(newObjectIn: ctx)!
        func expose(_ name: String, _ block: AnyObject) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let setSettings: @convention(block) (String) -> Void = { [weak self] json in
            guard let self, let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // Every `oz.set` sends the whole of what was set so far: its problems replace the last ones.
            var s = Settings()
            var problems = s.apply(obj)
            let action = s.doubleTap.action
            if !action.hasPrefix("binding:"), Command(rawValue: action) == nil {
                problems.append("doubleTap.action: \"\(action)\" is not a command")
            }
            self.settings = s
            self.settingsProblems = problems
        }
        let bind: @convention(block) (String, Int) -> Bool = { [weak self] combo, id in
            guard let self else { return false }
            let ok = self.dryRun
                ? HotkeyCenter.parse(combo) != nil
                : HotkeyCenter.shared.register(combo) { [weak self] in self?.runBinding(id) }
            if ok { self.boundCombos.append(combo) }
            return ok
        }
        let command: @convention(block) (String, JSValue?) -> Bool = { [weak self] name, arg in
            self?.wm.perform(name, arg: ConfigEngine.native(arg)) ?? false
        }
        let log: @convention(block) (String) -> Void = { Log.info("[config] \($0)") }
        let warn: @convention(block) (String) -> Void = { [weak self] in self?.bindProblems.append($0) }
        let notify: @convention(block) (String, String) -> Void = { title, text in
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            SystemActions.run("/usr/bin/osascript",
                              ["-e", "display notification \"\(esc(text))\" with title \"\(esc(title))\""])
        }
        let exec: @convention(block) (String) -> Void = { SystemActions.shell($0) }
        let shell: @convention(block) (String) -> String = { SystemActions.shellSync($0) }
        let windows: @convention(block) () -> String = { [weak self] in
            ConfigEngine.json(self?.wm.allWindowsInfo() ?? [])
        }
        let focused: @convention(block) () -> String = { [weak self] in
            ConfigEngine.json(self?.wm.focusedInfo() ?? NSNull())
        }

        expose("settings", unsafeBitCast(setSettings, to: AnyObject.self))
        expose("bind", unsafeBitCast(bind, to: AnyObject.self))
        expose("command", unsafeBitCast(command, to: AnyObject.self))
        expose("log", unsafeBitCast(log, to: AnyObject.self))
        expose("warn", unsafeBitCast(warn, to: AnyObject.self))
        expose("notify", unsafeBitCast(notify, to: AnyObject.self))
        expose("exec", unsafeBitCast(exec, to: AnyObject.self))
        expose("shell", unsafeBitCast(shell, to: AnyObject.self))
        expose("windows", unsafeBitCast(windows, to: AnyObject.self))
        expose("focused", unsafeBitCast(focused, to: AnyObject.self))
        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)

        let commands = ConfigEngine.json(Command.allCases.map(\.rawValue))
        ctx.evaluateScript(ConfigEngine.prelude.replacingOccurrences(of: "__COMMANDS__", with: commands))

        let url = ConfigEngine.configURL
        if let src = try? String(contentsOf: url, encoding: .utf8) {
            ctx.evaluateScript(src, withSourceURL: url)
        } else {
            lastError = "cannot read \(url.path)"
        }
        context = ctx
        lastModified = modificationDate()
        Log.info(lastError == nil ? "config loaded" : "config loaded with error: \(lastError!)")
        warnings.forEach { Log.info("config warning: \($0)") }
        onLoaded?(settings)
        emit("configLoaded", [:])
    }

    func runBinding(_ id: Int) {
        context?.objectForKeyedSubscript("oz")?.invokeMethod("__run", withArguments: [id])
    }

    func emit(_ event: String, _ payload: Any) {
        context?.objectForKeyedSubscript("oz")?.invokeMethod("__emit", withArguments: [event, ConfigEngine.json(payload)])
    }

    func rules(for w: ManagedWindow) -> RuleResult {
        var result = RuleResult()
        let info = ["app": w.appName, "title": w.title, "bundleId": w.bundleID ?? ""]
        guard let out = context?.objectForKeyedSubscript("oz")?
            .invokeMethod("__rules", withArguments: [ConfigEngine.json(info)])?.toString(),
            let data = out.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return result }
        result.float = obj["float"] as? Bool ?? false
        result.ignore = obj["ignore"] as? Bool ?? false
        if let h = obj["height"] as? NSNumber, h.doubleValue > 0, h.doubleValue <= 1 {
            result.height = CGFloat(h.doubleValue)
        }
        return result
    }

    /// Reload automatically when config.js is saved, however it is saved and wherever it
    /// really is: an editor that writes into the file changes only the file; one that swaps
    /// in a new file changes its folder; and the file may be a link into another folder (a
    /// dotfiles repository), which is where both of those happen then.
    func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        let link = ConfigEngine.configURL, file = ConfigEngine.resolvedURL
        for path in Set([link.deletingLastPathComponent().path, file.deletingLastPathComponent().path, file.path]) {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
                                                                queue: .main)
            src.setEventHandler { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.changed() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func changed() {
        // A new file may have taken the old one's place (or the link points elsewhere now).
        watch()
        guard let m = modificationDate(), m != lastModified else { return }
        Log.info("config changed, reloading")
        load()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ConfigEngine.resolvedURL.path))?[.modificationDate] as? Date
    }

    private static func native(_ v: JSValue?) -> Any? {
        guard let v, !v.isUndefined, !v.isNull else { return nil }
        if v.isNumber { return NSNumber(value: v.toDouble()) }
        if v.isBoolean { return v.toBool() }
        return v.toString()
    }

    static func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject([v]),
              let data = try? JSONSerialization.data(withJSONObject: [v]),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return String(s.dropFirst().dropLast())
    }

    private static let prelude = #"""
    var oz = (function () {
      var settings = {};
      var actions = {};
      var nextId = 1;
      var handlers = {};
      var rules = [];
      var commands = __COMMANDS__;

      function isPlain(v) { return v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof RegExp); }
      function merge(dst, src) {
        for (var k in src) {
          if (isPlain(src[k])) dst[k] = merge(isPlain(dst[k]) ? dst[k] : {}, src[k]);
          else dst[k] = src[k];
        }
        return dst;
      }
      function register(action) { var id = nextId++; actions[id] = action; return id; }
      function test(pattern, value) {
        if (pattern === undefined || pattern === null) return true;
        value = value || "";
        if (pattern instanceof RegExp) return pattern.test(value);
        if (typeof pattern === 'function') return !!pattern(value);
        if (Array.isArray(pattern)) return pattern.some(function (p) { return test(p, value); });
        return String(pattern) === value;
      }
      function str(a) { return (a !== null && typeof a === 'object') ? JSON.stringify(a) : String(a); }

      var oz = {
        // Merge settings (call as often as you like).
        set: function (s) {
          s = s || {};
          if (s.doubleTap && typeof s.doubleTap.action === 'function') {
            s.doubleTap.action = 'binding:' + register(s.doubleTap.action);
          }
          merge(settings, s);
          __native.settings(JSON.stringify(settings));
        },
        settings: function () { return JSON.parse(JSON.stringify(settings)); },
        // oz.bind("ctrl+alt+j", "focusDown") or oz.bind("ctrl+alt+x", function () { ... })
        bind: function (combo, action) {
          if (typeof action !== 'string' && typeof action !== 'function') {
            throw new Error("oz.bind('" + combo + "'): action must be a command name or a function");
          }
          // A command that doesn't exist (a misspelt name) would take the keys and do nothing.
          if (typeof action === 'string' && commands.indexOf(action) < 0) {
            __native.warn("oz.bind('" + combo + "'): \"" + action + "\" is not a command");
            return;
          }
          if (!__native.bind(String(combo), register(action))) {
            __native.warn("oz.bind('" + combo + "'): could not bind these keys (not a key Oz knows, or taken)");
          }
        },
        // Events: windowCreated, windowFocused, swipeEnded, spaceChanged, configLoaded
        on: function (event, fn) { (handlers[event] = handlers[event] || []).push(fn); },
        // oz.rule({ app: "Finder", float: true }), title/app/bundleId may be strings, RegExps, arrays or functions
        rule: function (r) { rules.push(r); },
        command: function (name, arg) { return __native.command(String(name), arg === undefined ? null : arg); },
        log: function () { __native.log(Array.prototype.map.call(arguments, str).join(' ')); },
        notify: function (title, text) { __native.notify(String(title), text === undefined ? "" : String(text)); },
        exec: function (cmd) { __native.exec(String(cmd)); },
        shell: function (cmd) { return __native.shell(String(cmd)); },
        windows: function () { return JSON.parse(__native.windows()); },
        focusedWindow: function () { return JSON.parse(__native.focused()); },

        __run: function (id) {
          var a = actions[id];
          if (typeof a === 'string') oz.command(a);
          else if (typeof a === 'function') a();
        },
        __emit: function (event, json) {
          var payload = JSON.parse(json);
          (handlers[event] || []).forEach(function (fn) {
            try { fn(payload); } catch (e) { oz.log("oz.on('" + event + "') error: " + e); }
          });
        },
        __rules: function (json) {
          var w = JSON.parse(json), out = {};
          rules.forEach(function (r) {
            if (test(r.app, w.app) && test(r.title, w.title) && test(r.bundleId, w.bundleId)) {
              for (var k in r) if (k !== 'app' && k !== 'title' && k !== 'bundleId') out[k] = r[k];
            }
          });
          return JSON.stringify(out);
        }
      };
      commands.forEach(function (c) { oz[c] = function (arg) { return oz.command(c, arg); }; });
      return oz;
    })();
    """#
}
