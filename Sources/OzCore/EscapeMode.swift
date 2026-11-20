import CoreGraphics

/// Where windows go while the desktop is cleared for a drop (`toggleEscapeMode`): the other
/// windows off the screen's side edges, and the focused one small enough to keep out of the
/// pointer's way. All frames in AX coordinates (top-left origin).
public enum EscapeMode {
    /// The share of the area the window may take each way: small enough that there is
    /// always somewhere to go that the pointer isn't.
    public static let widthShare: CGFloat = 0.5
    public static let heightShare: CGFloat = 0.6
    /// The pointer this far inside the window (pt) sends it away: up to its edge, and that
    /// little way in, it stays, so its edge can be taken to resize it.
    public static let edgeSlack: CGFloat = 16

    /// The window's frame in the mode: no bigger than its share of `area`, its shape kept
    /// (made smaller evenly, its picture shrinks into it without being squashed), its middle
    /// where it was as far as the area allows.
    public static func frame(for f: CGRect, in area: CGRect) -> CGRect {
        let k = min(1, area.width * widthShare / max(f.width, 1), area.height * heightShare / max(f.height, 1))
        let w = (f.width * k).rounded(), h = (f.height * k).rounded()
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

    /// The pointer at `p` is on the window, past its edge.
    public static func isNear(_ p: CGPoint, _ f: CGRect) -> Bool {
        f.insetBy(dx: edgeSlack, dy: edgeSlack).contains(p)
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

    /// Never made smaller than this wide by scrolling (pt).
    public static let minWidth: CGFloat = 240

    /// Scrolled in the mode: the window `f` made bigger (`amount` > 0) or smaller by a factor
    /// of e^amount, toward its size `original` before the mode or away, its shape that of
    /// `original`, its middle where it was as far as `area` allows. No bigger than `original`
    /// or `area`, no narrower than `minWidth`.
    public static func resized(_ f: CGRect, by amount: CGFloat, original: CGSize, in area: CGRect) -> CGRect {
        let ow = max(original.width, 1), oh = max(original.height, 1)
        let most = min(1, area.width / ow, area.height / oh)
        let least = min(most, minWidth / ow)
        let k = min(most, max(least, f.width / ow * exp(amount)))
        let w = (ow * k).rounded(), h = (oh * k).rounded()
        // At its smallest or biggest already: where it is (worked out again from its middle,
        // rounding moved it a point each time, and it crept down the screen).
        if abs(w - f.width) < 1 && abs(h - f.height) < 1 { return f }
        return fitted(CGRect(x: (f.midX - w / 2).rounded(), y: (f.midY - h / 2).rounded(), width: w, height: h), in: area)
    }

    /// `f` moved (not resized) to lie inside `area` as far as it fits, from its top left.
    public static func fitted(_ f: CGRect, in area: CGRect) -> CGRect {
        let x = max(min(f.minX, area.maxX - f.width), area.minX)
        let y = max(min(f.minY, area.maxY - f.height), area.minY)
        return CGRect(x: x, y: y, width: f.width, height: f.height).integral
    }

    /// From `p` to the nearest point of `r` (0 inside it).
    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
