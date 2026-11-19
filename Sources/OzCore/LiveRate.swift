/// The live capture rate when it is set to automatic (`livePeekFPS: 0`): `base` while memory
/// is plentiful, lower as it fills up, so the captures give way when the Mac needs memory.
public enum LiveRate {
    /// Frame rate of automatic mode while less than half the memory is in use.
    public static let base = 30.0

    /// Above each share of memory in use, the rate drops by this much (of `base`).
    static let steps: [(used: Double, cut: Double)] = [(0.9, 0.85), (0.75, 0.5), (0.5, 0.25)]

    /// Above this share in use, or with macOS saying memory is critically short, one frame a
    /// second: only enough to show what's there.
    public static let last = 0.95

    /// The rate for `used` (0...1, the share of memory in use), whole frames, at least 1.
    /// `critical`: macOS reports critical memory pressure.
    public static func fps(memoryUsed used: Double, critical: Bool = false, base: Double = LiveRate.base) -> Double {
        if critical || used > last { return 1 }
        let cut = steps.first { used > $0.used }?.cut ?? 0
        return max(1, (base * (1 - cut)).rounded())
    }
}
