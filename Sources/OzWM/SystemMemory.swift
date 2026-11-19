import Darwin

enum SystemMemory {
    /// The share of the Mac's memory in use (0...1): what macOS itself doesn't count as free
    /// (`kern.memorystatus_level`, the "free percentage" `memory_pressure` prints). Activity
    /// Monitor's "Memory Used" runs much higher, as it counts compressed memory and caches
    /// that macOS gives up at once when something needs the room.
    static func usedShare() -> Double? {
        var free: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &free, &size, nil, 0) == 0, (0...100).contains(free) else { return nil }
        return 1 - Double(free) / 100
    }
}
