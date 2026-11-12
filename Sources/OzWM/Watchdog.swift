import Darwin
import Foundation
import QuartzCore

/// Logs when the main thread stops responding (over 100 ms is a visible hitch) together
/// with what it was doing: the watchdog thread briefly suspends the main thread, walks its
/// frame pointers and symbolizes them, so every "[stall]" line in the log names its cause.
enum Watchdog {
    private static let lock = NSLock()
    private static var lastBeat = CACurrentMediaTime()
    private static var mainThread: thread_act_t = 0

    static func start() {
        mainThread = mach_thread_self()
        // 20 beats a second (not 50): a 100 ms hitch is still caught, with fewer wake-ups.
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            lock.lock(); lastBeat = CACurrentMediaTime(); lock.unlock()
        }
        RunLoop.main.add(t, forMode: .common)
        Thread.detachNewThread {
            var stallStart: CFTimeInterval = 0
            var stack: [String] = []
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); let beat = lastBeat; lock.unlock()
                let gap = CACurrentMediaTime() - beat
                if gap > 0.1 {
                    if stallStart == 0 {
                        stallStart = beat
                        stack = mainStack()
                    }
                } else if stallStart != 0 {
                    let ms = Int((beat - stallStart) * 1000) + 50
                    if !isIdle(stack) {
                        Log.info("[stall] main thread blocked \(ms) ms in:\n    " + stack.joined(separator: "\n    "))
                    }
                    stallStart = 0
                }
            }
        }
    }

    /// The main thread was asleep in its run loop, waiting for work, with none of our code on
    /// the stack: a late heartbeat (timers are held back while the Mac idles, sleeps or sits
    /// at the lock screen), not a hitch. These made up most "stalls" in the log.
    private static func isIdle(_ stack: [String]) -> Bool {
        guard let top = stack.first, top.contains("mach_msg") else { return false }
        return !stack.contains { $0.hasPrefix("OzWM") && !$0.hasSuffix(" main") }
    }

    /// Our own frames (plus the system call they are waiting in) from the main thread.
    /// Nothing is allocated while it is suspended: it may hold the allocator's lock.
    private static func mainStack() -> [String] {
        let pcs = UnsafeMutablePointer<UInt>.allocate(capacity: 66)
        defer { pcs.deallocate() }
        var n = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        #if arch(arm64)
        var state = arm_thread_state64_t()
        let flavor = ARM_THREAD_STATE64
        #else
        var state = x86_thread_state64_t()
        let flavor = x86_THREAD_STATE64
        #endif
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: state) / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, flavor, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Where it is, then (on ARM) where it returns to, which is not on the stack yet.
            #if arch(arm64)
            pcs[0] = UInt(state.__pc)
            pcs[1] = UInt(state.__lr)
            n = 2
            var fp = UInt(state.__fp)
            #else
            pcs[0] = UInt(state.__rip)
            n = 1
            var fp = UInt(state.__rbp)
            #endif
            for _ in 0..<64 where fp != 0 {
                var frame: (UInt, UInt) = (0, 0)  // (previous fp, return address)
                var size: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &frame) {
                    vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                      vm_address_t(UInt(bitPattern: $0)), &size)
                }
                guard ok == KERN_SUCCESS, frame.1 != 0, frame.0 > fp else { break }
                pcs[n] = frame.1
                n += 1
                fp = frame.0
            }
        }
        thread_resume(mainThread)

        var out: [String] = []
        for pc in UnsafeBufferPointer(start: pcs, count: n) {
            var info = Dl_info()
            // Strip pointer authentication bits (ARM) before looking the address up.
            #if arch(arm64)
            let addr = UnsafeRawPointer(bitPattern: pc & 0x0000_000F_FFFF_FFFF)
            #else
            let addr = UnsafeRawPointer(bitPattern: pc)
            #endif
            guard let addr, dladdr(addr, &info) != 0 else { continue }
            let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
            let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            let line = "\(image)  \(demangle(symbol))"
            if out.last != line { out.append(line) }
        }
        // Keep it short: the innermost few frames and everything from our own binary.
        return Array(out.prefix(4)) + out.dropFirst(4).filter { $0.hasPrefix("OzWM") }.prefix(12)
    }

    @_silgen_name("swift_demangle")
    private static func swift_demangle(_ mangled: UnsafePointer<CChar>?, _ length: Int,
                                       _ output: UnsafeMutablePointer<CChar>?, _ outLength: UnsafeMutablePointer<Int>?,
                                       _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    private static func demangle(_ s: String) -> String {
        guard let p = s.withCString({ swift_demangle($0, strlen($0), nil, nil, 0) }) else { return s }
        defer { free(p) }
        let full = String(cString: p)
        return full.count > 140 ? String(full.prefix(140)) + "…" : full
    }
}
