import CoreGraphics

/// Where windows go while the desktop is cleared for a drop (`toggleEscapeMode`): the other
/// windows off the screen's side edges, and the focused one small enough to keep out of the
/// pointer's way. All frames in AX coordinates (top-left origin).
public enum EscapeMode {
    /// The share of the area the window may take each way: small enough that there is
    /// always somewhere to go that the pointer isn't.
    public static let widthShare: CGFloat = 0.5
    public static let heightShare: CGFloat = 0.6
    /// The pointer this close to the window (pt) sends it away.
    public static let margin: CGFloat = 40

    /// The window's frame in the mode: no bigger than its share of `area`, its middle where
    /// it was as far as the area allows.
    public static func frame(for f: CGRect, in area: CGRect) -> CGRect {
        let w = min(f.width, (area.width * widthShare).rounded())
        let h = min(f.height, (area.height * heightShare).rounded())
        let x = min(max(f.midX - w / 2, area.minX), area.maxX - w)
        let y = min(max(f.midY - h / 2, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h).integral
    }

    /// `f` moved sideways off the nearer side edge of `screen` (macOS keeps a point of it on
    /// screen), or off the other edge when another display is that way. nil: displays on
    /// both sides.
    public static func offEdge(_ f: CGRect, screen: CGRect, others: [CGRect] = []) -> CGRect? {
        let left = CGRect(x: screen.minX - f.width + 1, y: f.minY, width: f.width, height: f.height)
        let right = CGRect(x: screen.maxX - 1, y: f.minY, width: f.width, height: f.height)
        let sides = f.midX < screen.midX ? [left, right] : [right, left]
        return sides.first { r in !others.contains { $0.intersects(r.insetBy(dx: 2, dy: 2)) } }
    }

    /// The pointer at `p` is on the window or close to it.
    public static func isNear(_ p: CGPoint, _ f: CGRect) -> Bool {
        f.insetBy(dx: -margin, dy: -margin).contains(p)
    }

    /// Where the window `f` goes to get away from the pointer at `p`: of the corners, the
    /// middles of the edges and the middle of `area`, the place farthest from the pointer;
    /// of places as far, the nearest to where it is.
    public static func dodge(_ f: CGRect, from p: CGPoint, in area: CGRect) -> CGRect {
        let w = f.width, h = f.height
        let xs = [area.minX, area.midX - w / 2, area.maxX - w]
        let ys = [area.minY, area.midY - h / 2, area.maxY - h]
        var best = f, bestScore = -CGFloat.greatestFiniteMagnitude, bestMove = CGFloat.greatestFiniteMagnitude
        for x in xs {
            for y in ys {
                let r = CGRect(x: x, y: y, width: w, height: h).integral
                let score = distance(p, r)
                let move = hypot(r.minX - f.minX, r.minY - f.minY)
                if score > bestScore + 1 || (abs(score - bestScore) <= 1 && move < bestMove) {
                    best = r
                    bestScore = score
                    bestMove = move
                }
            }
        }
        return best
    }

    /// From `p` to the nearest point of `r` (0 inside it).
    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
