import CoreGraphics
import Foundation

public enum Geometry {
    // MARK: Coordinate mapping

    /// Normalized (0...1) point → view point for a view of `size` whose origin is top-left.
    public static func denormalize(_ p: StrokePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
    }

    /// View point (top-left origin) → normalized point, clamped to the display.
    public static func normalize(_ point: CGPoint, in size: CGSize, pressure: CGFloat = 1) -> StrokePoint {
        let x = size.width > 0 ? point.x / size.width : 0
        let y = size.height > 0 ? point.y / size.height : 0
        return StrokePoint(x: Float(min(max(x, 0), 1)), y: Float(min(max(y, 0), 1)), p: Float(pressure))
    }

    /// Stroke width in view points for a normalized width (fraction of display width).
    public static func viewWidth(_ normalizedWidth: Float, viewWidth: CGFloat) -> CGFloat {
        CGFloat(normalizedWidth) * viewWidth
    }

    /// Largest rect of `aspect` (w/h) centered in `bounds` (letterboxing).
    public static func aspectFit(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let boundsAspect = bounds.width / bounds.height
        var size = bounds.size
        if boundsAspect > aspect { size.width = bounds.height * aspect } else { size.height = bounds.width / aspect }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Shapes

    /// Constrains a shape's end point so that, in display pixels, the shape is a
    /// square/circle (rect, ellipse) or a 45°-snapped line (line, arrow).
    public static func constrain(tool: Tool, start: StrokePoint, end: StrokePoint, aspect: Float) -> StrokePoint {
        // Work in a space where x is scaled by aspect so units are equal on both axes.
        let dx = (end.x - start.x) * aspect
        let dy = end.y - start.y
        if let figureAspect = tool.figureAspect {
            // Keep the figure's natural proportions, sized by the larger drag axis.
            let h = max(abs(dy), abs(dx) / figureAspect)
            let w = h * figureAspect
            return StrokePoint(x: start.x + (dx < 0 ? -w : w) / aspect, y: start.y + (dy < 0 ? -h : h), p: end.p)
        }
        switch tool {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            let nx = start.x + (dx < 0 ? -side : side) / aspect
            let ny = start.y + (dy < 0 ? -side : side)
            return StrokePoint(x: nx, y: ny, p: end.p)
        case .line, .arrow:
            let angle = atan2(dy, dx)
            let step = Float.pi / 4
            let snapped = (angle / step).rounded() * step
            let len = (dx * dx + dy * dy).squareRoot()
            return StrokePoint(x: start.x + cos(snapped) * len / aspect,
                               y: start.y + sin(snapped) * len, p: end.p)
        default:
            return end
        }
    }

    /// The two barb end points of an arrowhead at `tip`, coming from `tail`, in view space.
    public static func arrowhead(tail: CGPoint, tip: CGPoint, lineWidth: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(lineWidth * 4, 12)
        let spread = CGFloat.pi / 7
        let a = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let b = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        return (a, b)
    }

    // MARK: Hit testing

    /// Whether `point` is within `radius` (+ half stroke width) of the stroke's outline.
    /// All values normalized; `aspect` = display width / height.
    public static func hitTest(stroke: Stroke, point: StrokePoint, radius: Float, aspect: Float) -> Bool {
        // Map to a space where 1 unit is the same physical length on both axes (display-width units).
        func m(_ p: StrokePoint) -> SIMD2<Float> { SIMD2(p.x, p.y / max(aspect, 0.0001)) }
        let q = m(point)
        let tol = radius + stroke.effectiveWidth / 2

        let segments: [(SIMD2<Float>, SIMD2<Float>)]
        let pts = stroke.points
        switch stroke.tool {
        case .phone where pts.count >= 2, .person where pts.count >= 2, .text where pts.count >= 2:
            // Figures and text are erased by touching anywhere inside their box.
            let a = m(pts[0]), b = m(pts[1])
            return q.x >= min(a.x, b.x) - tol && q.x <= max(a.x, b.x) + tol
                && q.y >= min(a.y, b.y) - tol && q.y <= max(a.y, b.y) + tol
        case .rectangle where pts.count >= 2:
            let a = m(pts[0]), b = m(pts[1])
            let c1 = SIMD2(a.x, a.y), c2 = SIMD2(b.x, a.y), c3 = SIMD2(b.x, b.y), c4 = SIMD2(a.x, b.y)
            segments = [(c1, c2), (c2, c3), (c3, c4), (c4, c1)]
        case .ellipse where pts.count >= 2:
            let a = m(pts[0]), b = m(pts[1])
            let c = (a + b) / 2, r = abs(b - a) / 2
            let n = 32
            let ring = (0...n).map { i -> SIMD2<Float> in
                let t = Float(i) / Float(n) * 2 * .pi
                return SIMD2(c.x + r.x * cos(t), c.y + r.y * sin(t))
            }
            segments = zip(ring, ring.dropFirst()).map { ($0, $1) }
        default:
            let mapped = pts.map(m)
            if mapped.count == 1 { return simd_distance(mapped[0], q) <= tol }
            segments = zip(mapped, mapped.dropFirst()).map { ($0, $1) }
        }
        return segments.contains { distance(from: q, toSegment: $0.0, $0.1) <= tol }
    }

    static func distance(from p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        if len2 == 0 { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return simd_distance(p, a + t * ab)
    }
}

@inline(__always) private func simd_distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}

@inline(__always) private func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    a.x * b.x + a.y * b.y
}

private func abs(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(Swift.abs(v.x), Swift.abs(v.y)) }
