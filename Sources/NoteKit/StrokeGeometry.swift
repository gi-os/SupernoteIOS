import Foundation

public enum StrokeGeometry {
    /// Closed outline polygon of a variable-width stroke (round caps). Filled with non-zero
    /// winding it covers the stroke, including self-crossing loops.
    public static func outline(points: [PagePoint], radii: [Double]) -> [PagePoint] {
        guard let first = points.first else { return [] }
        if points.count == 1 || points.allSatisfy({ $0 == first }) {
            return circle(first, radii.first ?? 1)
        }
        var left: [PagePoint] = [], right: [PagePoint] = []
        for i in points.indices {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len < 1e-6 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
            let r = radii[i]
            left.append(PagePoint(x: points[i].x - dy * r, y: points[i].y + dx * r))
            right.append(PagePoint(x: points[i].x + dy * r, y: points[i].y - dx * r))
        }
        let endCap = arc(center: points.last!, radius: radii.last!, from: left.last!, to: right.last!)
        let startCap = arc(center: first, radius: radii.first!, from: right.first!, to: left.first!)
        return left + endCap + right.reversed() + startCap
    }

    static func circle(_ c: PagePoint, _ r: Double, segments: Int = 12) -> [PagePoint] {
        (0 ..< segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return PagePoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        }
    }

    /// Half-circle from `from` to `to` around `center`, going the outward way.
    static func arc(center: PagePoint, radius: Double, from: PagePoint, to: PagePoint, segments: Int = 6) -> [PagePoint] {
        let a0 = atan2(from.y - center.y, from.x - center.x)
        var a1 = atan2(to.y - center.y, to.x - center.x)
        if a1 > a0 { a1 -= 2 * .pi }  // sweep clockwise in page space (y down) to stay on the outside
        return (1 ..< segments).map { i in
            let a = a0 + (a1 - a0) * Double(i) / Double(segments)
            return PagePoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        }
    }

    /// Distance from point to the segment ab.
    public static func distance(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        var t = l2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2 : 0
        t = min(1, max(0, t))
        let cx = a.x + t * dx - p.x, cy = a.y + t * dy - p.y
        return (cx * cx + cy * cy).squareRoot()
    }

    /// True if any segment of the stroke passes within `radius` of `p`.
    public static func hits(_ s: NoteStroke, _ p: PagePoint, radius: Double) -> Bool {
        let b = s.bounds
        guard p.x >= b.minX - radius, p.x <= b.maxX + radius, p.y >= b.minY - radius, p.y <= b.maxY + radius else { return false }
        let pts = s.points
        if pts.count == 1 { return distance(p, pts[0], pts[0]) <= radius + Double(s.width) / 1000 * StrokeCodec.pixelsPerMM / 2 }
        let slack = Double(s.width) / 1000 * StrokeCodec.pixelsPerMM / 2
        for i in 1 ..< pts.count where distance(p, pts[i - 1], pts[i]) <= radius + slack { return true }
        return false
    }

    /// Even-odd point-in-polygon.
    public static func contains(_ poly: [PagePoint], _ p: PagePoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// Scanline polygon fill into an 8-bit code buffer (the RATTA_RLE layer).
public enum Raster {
    public enum Rule { case evenOdd, nonZero }

    public static func fill(_ polys: [[PagePoint]], rule: Rule, code: UInt8,
                            into buf: inout [UInt8], width: Int, height: Int) {
        var edges: [(x0: Double, y0: Double, x1: Double, y1: Double, dir: Int)] = []
        var minY = Double.infinity, maxY = -Double.infinity
        for poly in polys where poly.count >= 3 {
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if a.y == b.y { continue }
                edges.append(a.y < b.y ? (a.x, a.y, b.x, b.y, 1) : (b.x, b.y, a.x, a.y, -1))
                minY = min(minY, a.y, b.y); maxY = max(maxY, a.y, b.y)
            }
        }
        guard !edges.isEmpty else { return }
        let y0 = max(0, Int(minY.rounded(.down))), y1 = min(height - 1, Int(maxY.rounded(.down)))
        guard y0 <= y1 else { return }
        var xs: [(Double, Int)] = []
        // Conservative coverage (like the device / PIL polygon+outline): a pixel is ink if the
        // polygon touches it, approximated by sampling each row at its top, middle and bottom.
        for y in y0 ... y1 {
            let row = y * width
            for sy in [Double(y) + 0.02, Double(y) + 0.5, Double(y) + 0.98] {
                xs.removeAll(keepingCapacity: true)
                for e in edges where sy >= e.y0 && sy < e.y1 {
                    xs.append((e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0), e.dir))
                }
                guard xs.count >= 2 else { continue }
                xs.sort { $0.0 < $1.0 }
                var winding = 0
                for k in 0 ..< xs.count - 1 {
                    winding += rule == .evenOdd ? 1 : xs[k].1
                    let inside = rule == .evenOdd ? winding % 2 != 0 : winding != 0
                    guard inside else { continue }
                    let xa = max(0, Int(xs[k].0.rounded(.down)))
                    let xb = min(width - 1, Int(xs[k + 1].0.rounded(.down)))
                    if xa <= xb { for x in xa ... xb { buf[row + x] = code } }
                }
            }
        }
    }

    /// Draws a stroke into the layer buffer exactly as we'd store it (device strokes use their
    /// own contours with holes → even-odd; our generated single outline → non-zero).
    public static func draw(_ s: NoteStroke, into buf: inout [UInt8], width: Int, height: Int) {
        let rule: Rule = s.contours.count == 1 ? .nonZero : .evenOdd
        fill(s.contours, rule: rule, code: s.bitmapCode, into: &buf, width: width, height: height)
    }
}
