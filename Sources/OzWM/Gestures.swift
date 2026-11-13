import Foundation
import OzCore

/// Feeds trackpad frames into per-device recognizers and forwards the
/// resulting gestures to the main thread (coalescing scroll deltas).
final class GestureController {
    /// Receives gesture events on the main thread.
    var handler: ((GestureEvent) -> Void)?

    private let lock = NSLock()
    private var recognizers: [Int: GestureRecognizer] = [:]
    private var swipe = SwipeSettings()
    private var doubleTap = DoubleTapSettings()
    private var pendingDY = 0.0
    private var flushScheduled = false

    func configure(_ settings: Settings) {
        lock.lock()
        swipe = settings.swipe
        doubleTap = settings.doubleTap
        recognizers.values.forEach(apply)
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        let source = TouchSource.shared
        guard source.isAvailable else {
            Log.info("MultitouchSupport not available; trackpad gestures disabled")
            return false
        }
        source.onFrame = { [weak self] device, touches, time in
            self?.frame(device: device, touches: touches, time: time)
        }
        let ok = source.start()
        Log.info("multitouch: \(source.deviceCount) device(s)")
        return ok
    }

    /// Main thread. A swipe under way ends here (its recognizer goes): the strip must hear
    /// of it, or it would wait for those fingers to lift for ever.
    func restart() {
        lock.lock()
        let swiping = recognizers.values.contains { $0.isSwiping }
        recognizers.removeAll()
        pendingDY = 0
        lock.unlock()
        if swiping { handler?(.swipeEnded(velocity: 0)) }
        TouchSource.shared.start()
    }

    func stop() {
        TouchSource.shared.stop()
    }

    private func apply(_ r: GestureRecognizer) {
        r.swipeEnabled = swipe.enabled
        r.swipeFingers = swipe.fingers
        r.threshold = swipe.threshold
        r.doubleTapEnabled = doubleTap.enabled
        r.tapFingers = doubleTap.fingers
        r.doubleTapInterval = doubleTap.interval
    }

    // MultitouchSupport thread.
    private func frame(device: Int, touches: [Touch], time: Double) {
        lock.lock()
        let r: GestureRecognizer
        if let existing = recognizers[device] {
            r = existing
        } else {
            r = GestureRecognizer()
            apply(r)
            recognizers[device] = r
        }
        let events = r.process(touches, time: time)
        for e in events {
            if case .swipeChanged(let dy) = e {
                pendingDY += dy
                if !flushScheduled {
                    flushScheduled = true
                    DispatchQueue.main.async { [weak self] in self?.flush() }
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.handler?(e) }
            }
        }
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let dy = pendingDY
        pendingDY = 0
        flushScheduled = false
        lock.unlock()
        if dy != 0 { handler?(.swipeChanged(dy)) }
    }
}
