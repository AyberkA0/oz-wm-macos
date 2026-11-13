import ApplicationServices
import Cocoa

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let o = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    o.handler?(notification as String, element, o.pid)
}

/// Accessibility notifications for one application. Notifications arrive on the main run
/// loop; registering for them is a round trip to the app (a launching app took up to
/// 0.9 s), so that runs on `schedule`, the app's own background queue.
final class AppObserver {
    let pid: pid_t
    let app: AXUIElement
    var handler: ((String, AXUIElement, pid_t) -> Void)?
    private var observer: AXObserver?
    private let schedule: (@escaping () -> Void) -> Void

    static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    /// `schedule` runs work off the main thread, in order with the app's other AX calls.
    init?(pid: pid_t, schedule: @escaping (@escaping () -> Void) -> Void) {
        self.pid = pid
        self.schedule = schedule
        app = AXUIElementCreateApplication(pid)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        schedule { [weak self] in self?.registerApp(attempt: 0) }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Freshly launched apps often reject registration for a moment; retry a few times.
    /// Runs on the scheduled (background) queue.
    private func registerApp(attempt: Int) {
        guard let observer else { return }
        var ok = true
        for n in AppObserver.appNotifications {
            let err = AXObserverAddNotification(observer, app, n as CFString, refcon)
            if err != .success && err != .notificationAlreadyRegistered { ok = false }
        }
        if !ok && attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.schedule { [weak self] in self?.registerApp(attempt: attempt + 1) }
            }
        }
    }

    func watch(window: AXUIElement) {
        guard let observer else { return }
        let refcon = self.refcon
        schedule {
            for n in AppObserver.windowNotifications {
                AXObserverAddNotification(observer, window, n as CFString, refcon)
            }
        }
    }
}
