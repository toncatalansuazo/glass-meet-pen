using System.Numerics;

namespace Glasspen.Core.Model;

/// <summary>A point in view coordinates (top-left origin).</summary>
public readonly record struct Pt(double X, double Y);

public static class Geometry
{
    public static Pt Denormalize(StrokePoint p, double width, double height) => new(p.X * width, p.Y * height);

    /// <summary>View point (top-left origin) → normalized point, clamped to the display.</summary>
    public static StrokePoint Normalize(Pt p, double width, double height, double pressure = 1)
    {
        var x = width > 0 ? p.X / width : 0;
        var y = height > 0 ? p.Y / height : 0;
        return new StrokePoint((float)Math.Clamp(x, 0, 1), (float)Math.Clamp(y, 0, 1), (float)pressure);
    }

    /// <summary>
    /// Constrains a shape's end point so that, in display pixels, it is a square/circle (rectangle,
    /// ellipse), a 45°-snapped line (line, arrow) or a figure with its natural proportions.
    /// </summary>
    public static StrokePoint Constrain(Tool tool, StrokePoint start, StrokePoint end, float aspect)
    {
        var dx = (end.X - start.X) * aspect;
        var dy = end.Y - start.Y;
        if (tool.FigureAspect() is { } figureAspect)
        {
            var h = Math.Max(Math.Abs(dy), Math.Abs(dx) / figureAspect);
            var w = h * figureAspect;
            return new StrokePoint(start.X + (dx < 0 ? -w : w) / aspect, start.Y + (dy < 0 ? -h : h), end.P);
        }
        switch (tool)
        {
            case Tool.Rectangle or Tool.Ellipse:
                var side = Math.Max(Math.Abs(dx), Math.Abs(dy));
                return new StrokePoint(start.X + (dx < 0 ? -side : side) / aspect, start.Y + (dy < 0 ? -side : side), end.P);
            case Tool.Line or Tool.Arrow:
                var step = MathF.PI / 4;
                var snapped = MathF.Round(MathF.Atan2(dy, dx) / step) * step;
                var len = MathF.Sqrt(dx * dx + dy * dy);
                return new StrokePoint(start.X + MathF.Cos(snapped) * len / aspect, start.Y + MathF.Sin(snapped) * len, end.P);
            default:
                return end;
        }
    }

    /// <summary>The two barb end points of an arrowhead at <paramref name="tip"/>, in view space.</summary>
    public static (Pt Left, Pt Right) Arrowhead(Pt tail, Pt tip, double lineWidth)
    {
        var angle = Math.Atan2(tip.Y - tail.Y, tip.X - tail.X);
        var length = Math.Max(lineWidth * 4, 12);
        var spread = Math.PI / 7;
        return (new Pt(tip.X - length * Math.Cos(angle - spread), tip.Y - length * Math.Sin(angle - spread)),
                new Pt(tip.X - length * Math.Cos(angle + spread), tip.Y - length * Math.Sin(angle + spread)));
    }

    /// <summary>
    /// Whether <paramref name="point"/> is within radius (+ half stroke width) of the stroke. All values
    /// normalized; y is scaled by 1/aspect so distances are in display-width units.
    /// </summary>
    public static bool HitTest(Stroke stroke, StrokePoint point, float radius, float aspect) => HitsAny(stroke, [point], radius, aspect);

    /// <summary>
    /// Whether any of <paramref name="points"/> touches the stroke (see <see cref="HitTest"/>). The stroke's
    /// bounding box is checked first, so the eraser only measures segments of strokes it is near.
    /// </summary>
    public static bool HitsAny(Stroke stroke, IReadOnlyList<StrokePoint> points, float radius, float aspect)
    {
        var pts = stroke.Points;
        if (pts.Count == 0) return false;
        var yScale = 1 / Math.Max(aspect, 0.0001f);
        Vector2 M(StrokePoint p) => new(p.X, p.Y * yScale);
        var tol = radius + stroke.EffectiveWidth / 2;
        var (min, max) = Bounds(pts, yScale);
        min -= new Vector2(tol); max += new Vector2(tol);
        var boxOnly = pts.Count >= 2 && stroke.Tool is Tool.Phone or Tool.Person or Tool.Text; // erased by touching their box
        foreach (var point in points)
        {
            var q = M(point);
            if (q.X < min.X || q.X > max.X || q.Y < min.Y || q.Y > max.Y) continue;
            if (boxOnly || NearAnySegment(stroke.Tool, pts, M, q, tol)) return true;
        }
        return false;
    }

    private static (Vector2 Min, Vector2 Max) Bounds(IReadOnlyList<StrokePoint> pts, float yScale)
    {
        var min = new Vector2(float.MaxValue); var max = new Vector2(float.MinValue);
        foreach (var p in pts)
        {
            var v = new Vector2(p.X, p.Y * yScale);
            min = Vector2.Min(min, v); max = Vector2.Max(max, v);
        }
        return (min, max);
    }

    private static bool NearAnySegment(Tool tool, IReadOnlyList<StrokePoint> pts, Func<StrokePoint, Vector2> m, Vector2 q, float tol)
    {
        if (pts.Count == 1 || tool is Tool.Rectangle or Tool.Ellipse)
            return Segments(tool, pts.Take(2).Select(m).ToList()).Any(s => DistanceToSegment(q, s.A, s.B) <= tol);
        var a = m(pts[0]);
        for (var i = 1; i < pts.Count; i++)
        {
            var b = m(pts[i]);
            if (DistanceToSegment(q, a, b) <= tol) return true;
            a = b;
        }
        return false;
    }

    private static IEnumerable<(Vector2 A, Vector2 B)> Segments(Tool tool, List<Vector2> m)
    {
        if (m.Count == 1) return [(m[0], m[0])];
        if (tool == Tool.Rectangle && m.Count >= 2)
        {
            Vector2 a = m[0], b = m[1];
            Vector2 c1 = new(a.X, a.Y), c2 = new(b.X, a.Y), c3 = new(b.X, b.Y), c4 = new(a.X, b.Y);
            return [(c1, c2), (c2, c3), (c3, c4), (c4, c1)];
        }
        if (tool == Tool.Ellipse && m.Count >= 2)
        {
            var c = (m[0] + m[1]) / 2;
            var r = Vector2.Abs(m[1] - m[0]) / 2;
            var ring = Enumerable.Range(0, 33)
                .Select(i => i / 32f * 2 * MathF.PI)
                .Select(t => new Vector2(c.X + r.X * MathF.Cos(t), c.Y + r.Y * MathF.Sin(t))).ToList();
            return ring.Zip(ring.Skip(1));
        }
        return m.Zip(m.Skip(1));
    }

    internal static float DistanceToSegment(Vector2 p, Vector2 a, Vector2 b)
    {
        var ab = b - a;
        var len2 = Vector2.Dot(ab, ab);
        if (len2 == 0) return Vector2.Distance(p, a);
        var t = Math.Clamp(Vector2.Dot(p - a, ab) / len2, 0, 1);
        return Vector2.Distance(p, a + t * ab);
    }
}
