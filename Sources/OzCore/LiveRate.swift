/// The live capture rate when it is set to automatic (`livePeekFPS: 0`): `base` while memory
/// is plentiful, lower as it fills up, so the captures give way when the Mac needs memory.
public enum LiveRate {
    /// Frame rate of automatic mode while less than half the memory is in use.
    public static let base = 24.0

    /// Above each share of memory in use, the rate drops by this much (of `base`).
    static let steps: [(used: Double, cut: Double)] = [(0.9, 0.85), (0.75, 0.5), (0.5, 0.25)]

    /// The rate for `used` (0...1, the share of memory in use), whole frames, at least 1.
    public static func fps(memoryUsed used: Double, base: Double = LiveRate.base) -> Double {
        let cut = steps.first { used > $0.used }?.cut ?? 0
        return max(1, (base * (1 - cut)).rounded())
    }
}
