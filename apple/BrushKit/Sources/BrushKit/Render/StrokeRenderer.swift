import CoreGraphics
import Foundation

/// A stroke turned into a path in view coordinates, ready to be drawn by a
/// `CAShapeLayer` or a `CGContext`.
public struct RenderedStroke {
    public enum Mode { case stroke(lineWidth: CGFloat), fill }
    public var path: CGPath
    public var mode: Mode
    public var color: CGColor
    public var alpha: CGFloat
}

public enum StrokeRenderer {
    /// Builds the drawable path for a stroke in a view of `size` (top-left origin;
    /// on a flipped/bottom-left-origin context, flip before drawing).
    /// `transform` lets callers map the display rect into a zoomed/panned view.
    public static func render(_ stroke: Stroke, size: CGSize, transform: CGAffineTransform = .identity) -> RenderedStroke? {
        guard !stroke.points.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let scale = hypot(transform.a, transform.c) // uniform zoom factor of the transform
        let width = max(Geometry.viewWidth(stroke.effectiveWidth, viewWidth: size.width) * scale, 0.5)
        let pts = stroke.points.map { Geometry.denormalize($0, in: size).applying(transform) }
        let color = CGColor(srgbRed: CGFloat(stroke.color.r), green: CGFloat(stroke.color.g),
                            blue: CGFloat(stroke.color.b), alpha: 1)
        let alpha = CGFloat(stroke.effectiveAlpha)

        switch stroke.tool {
        case .line, .arrow, .rectangle, .ellipse, .phone, .person:
            let path = shapePath(stroke.tool, from: pts.first!, to: pts.last!, lineWidth: width)
            return RenderedStroke(path: path, mode: .stroke(lineWidth: width), color: color, alpha: alpha)
        case .pen where hasPressureVariation(stroke.points):
            let pressures = stroke.points.map { CGFloat($0.p) }
            let path = variableWidthOutline(points: pts, pressures: pressures, baseWidth: width)
            return RenderedStroke(path: path, mode: .fill, color: color, alpha: alpha)
        case .pen, .highlighter, .eraser:
            return RenderedStroke(path: smoothPath(pts), mode: .stroke(lineWidth: width), color: color, alpha: alpha)
        }
    }

    /// Draws a stroke into a context whose coordinate system has a top-left origin.
    public static func draw(_ stroke: Stroke, in ctx: CGContext, size: CGSize, transform: CGAffineTransform = .identity) {
        guard let r = render(stroke, size: size, transform: transform) else { return }
        ctx.saveGState()
        ctx.setAlpha(r.alpha)
        ctx.addPath(r.path)
        switch r.mode {
        case .stroke(let lw):
            ctx.setStrokeColor(r.color)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .fill:
            ctx.setFillColor(r.color)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Paths

    static func hasPressureVariation(_ points: [StrokePoint]) -> Bool {
        guard let lo = points.map(\.p).min(), let hi = points.map(\.p).max() else { return false }
        return hi - lo > 0.05
    }

    /// Removes points closer than `minDistance` to the previous kept point (keeps the last).
    static func decimate(_ pts: [CGPoint], minDistance: CGFloat = 0.75) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where hypot(p.x - out.last!.x, p.y - out.last!.y) >= minDistance {
            out.append(p)
        }
        out.append(pts.last!)
        return out
    }

    /// Catmull-Rom spline through all points, as cubic Béziers.
    public static func smoothPath(_ raw: [CGPoint]) -> CGPath {
        let pts = decimate(raw)
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first) // zero-length line renders as a dot with round caps
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Closed outline whose half-width follows pressure, with round caps. Filled, not stroked.
    static func variableWidthOutline(points raw: [CGPoint], pressures rawP: [CGFloat], baseWidth: CGFloat) -> CGPath {
        // Decimate while keeping pressures aligned.
        var pts: [CGPoint] = [], prs: [CGFloat] = []
        for (i, p) in raw.enumerated() {
            if let last = pts.last, i != raw.count - 1, hypot(p.x - last.x, p.y - last.y) < 0.75 { continue }
            pts.append(p); prs.append(rawP[i])
        }
        // Smooth pressure so width changes are gradual.
        let smoothed = prs.indices.map { i -> CGFloat in
            let lo = max(i - 2, 0), hi = min(i + 2, prs.count - 1)
            return prs[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1)
        }
        let widths = smoothed.map { baseWidth * (0.35 + 1.3 * min(max($0, 0), 1)) }

        let path = CGMutablePath()
        guard pts.count > 1 else {
            let r = (widths.first ?? baseWidth) / 2
            if let p = pts.first { path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            return path
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            dx /= len; dy /= len
            let h = widths[i] / 2
            left.append(CGPoint(x: pts[i].x - dy * h, y: pts[i].y + dx * h))
            right.append(CGPoint(x: pts[i].x + dy * h, y: pts[i].y - dx * h))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        // End cap: semicircle from left[last] to right[last] around the last point.
        let endAngle = atan2(left.last!.y - pts.last!.y, left.last!.x - pts.last!.x)
        path.addArc(center: pts.last!, radius: widths.last! / 2, startAngle: endAngle,
                    endAngle: endAngle + .pi, clockwise: true)
        for p in right.reversed().dropFirst() { path.addLine(to: p) }
        let startAngle = atan2(right[0].y - pts[0].y, right[0].x - pts[0].x)
        path.addArc(center: pts[0], radius: widths[0] / 2, startAngle: startAngle,
                    endAngle: startAngle + .pi, clockwise: true)
        path.closeSubpath()
        return path
    }

    public static func shapePath(_ tool: Tool, from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch tool {
        case .line:
            path.move(to: a); path.addLine(to: b)
        case .arrow:
            path.move(to: a); path.addLine(to: b)
            if hypot(b.x - a.x, b.y - a.y) > 1 {
                let (l, r) = Geometry.arrowhead(tail: a, tip: b, lineWidth: lineWidth)
                path.move(to: l); path.addLine(to: b); path.addLine(to: r)
            }
        case .rectangle:
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .ellipse:
            path.addEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .phone:
            addPhone(to: path, in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .person:
            addPerson(to: path, in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        default:
            path.move(to: a); path.addLine(to: b)
        }
        return path
    }

    /// Smartphone outline: rounded body, speaker slot and home indicator.
    static func addPhone(to path: CGMutablePath, in r: CGRect) {
        let corner = min(r.width, r.height) * 0.18
        path.addRoundedRect(in: r, cornerWidth: corner, cornerHeight: corner)
        path.move(to: CGPoint(x: r.minX + r.width * 0.4, y: r.minY + r.height * 0.06))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.06))
        path.move(to: CGPoint(x: r.minX + r.width * 0.35, y: r.maxY - r.height * 0.06))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.65, y: r.maxY - r.height * 0.06))
    }

    /// Stick figure: head, body, arms and legs filling the box.
    static func addPerson(to path: CGMutablePath, in r: CGRect) {
        let head = min(r.width * 0.25, r.height * 0.12)
        let cx = r.midX
        let neck = r.minY + head * 2
        let hip = r.minY + r.height * 0.62
        path.addEllipse(in: CGRect(x: cx - head, y: r.minY, width: head * 2, height: head * 2))
        path.move(to: CGPoint(x: cx, y: neck))
        path.addLine(to: CGPoint(x: cx, y: hip))
        let shoulder = CGPoint(x: cx, y: neck + r.height * 0.08)
        path.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.45))
        path.addLine(to: shoulder)
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.45))
        path.move(to: CGPoint(x: r.minX + r.width * 0.1, y: r.maxY))
        path.addLine(to: CGPoint(x: cx, y: hip))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY))
    }
}
