using Glasspen.Core.Model;

namespace Glasspen.Core.Render;

/// <summary>A drawing command in view coordinates (top-left origin). The app turns these into WPF geometry.</summary>
public abstract record PathOp
{
    public sealed record MoveTo(Pt P) : PathOp;
    public sealed record LineTo(Pt P) : PathOp;
    public sealed record CubicTo(Pt C1, Pt C2, Pt P) : PathOp;
    /// <summary>Half-circle arc to P around the previous point and P (used for round caps).</summary>
    public sealed record ArcTo(Pt P, double Radius) : PathOp;
    public sealed record Ellipse(double X, double Y, double W, double H) : PathOp;
    public sealed record RoundedRect(double X, double Y, double W, double H, double Corner) : PathOp;
    public sealed record Close : PathOp;
}

public enum PaintMode { Stroke, Fill }

/// <summary>How to draw one stroke: path, stroke or fill, color and opacity. Text is drawn by the app.</summary>
public sealed record RenderedStroke(IReadOnlyList<PathOp> Ops, PaintMode Mode, double LineWidth, RgbaColor Color, double Alpha);

/// <summary>Port of BrushKit's StrokeRenderer: turns a stroke into drawing commands for a view of a given size.</summary>
public static class StrokePath
{
    /// <summary>Null for an empty stroke or a text stroke (the app draws text with its own font engine).</summary>
    public static RenderedStroke? Render(Stroke stroke, double width, double height, double zoom = 1, double offsetX = 0, double offsetY = 0)
    {
        if (stroke.Points.Count == 0 || width <= 0 || height <= 0 || stroke.Tool == Tool.Text) return null;
        var lineWidth = Math.Max(stroke.EffectiveWidth * width * zoom, 0.5);
        var pts = stroke.Points.Select(p => new Pt(p.X * width * zoom + offsetX, p.Y * height * zoom + offsetY)).ToList();
        var color = stroke.Color with { A = 1 };
        double alpha = stroke.EffectiveAlpha;
        if (stroke.Tool.IsShape())
            return new(Shape(stroke.Tool, pts[0], pts[^1], lineWidth), PaintMode.Stroke, lineWidth, color, alpha);
        if (stroke.Tool == Tool.Pen && HasPressureVariation(stroke.Points))
            return new(VariableWidthOutline(pts, stroke.Points.Select(p => (double)p.P).ToList(), lineWidth), PaintMode.Fill, 0, color, alpha);
        return new(Smooth(pts), PaintMode.Stroke, lineWidth, color, alpha);
    }

    public static bool HasPressureVariation(IReadOnlyList<StrokePoint> points) =>
        points.Count > 0 && points.Max(p => p.P) - points.Min(p => p.P) > 0.05f;

    /// <summary>Removes points closer than <paramref name="minDistance"/> to the previous kept point (keeps the last).</summary>
    public static List<Pt> Decimate(IReadOnlyList<Pt> pts, double minDistance = 0.75)
    {
        if (pts.Count <= 2) return pts.ToList();
        var output = new List<Pt> { pts[0] };
        for (var i = 1; i < pts.Count - 1; i++)
            if (Distance(pts[i], output[^1]) >= minDistance) output.Add(pts[i]);
        output.Add(pts[^1]);
        return output;
    }

    /// <summary>Catmull-Rom spline through all points, as cubic Béziers.</summary>
    public static List<PathOp> Smooth(IReadOnlyList<Pt> raw)
    {
        var pts = Decimate(raw);
        var ops = new List<PathOp> { new PathOp.MoveTo(pts[0]) };
        if (pts.Count == 1) { ops.Add(new PathOp.LineTo(pts[0])); return ops; } // a dot with round caps
        if (pts.Count == 2) { ops.Add(new PathOp.LineTo(pts[1])); return ops; }
        for (var i = 0; i < pts.Count - 1; i++)
        {
            Pt p0 = pts[Math.Max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[Math.Min(i + 2, pts.Count - 1)];
            ops.Add(new PathOp.CubicTo(new Pt(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6),
                                       new Pt(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6), p2));
        }
        return ops;
    }

    /// <summary>Closed outline whose half-width follows pressure, with round caps. Filled, not stroked.</summary>
    public static List<PathOp> VariableWidthOutline(IReadOnlyList<Pt> raw, IReadOnlyList<double> rawPressure, double baseWidth)
    {
        var (pts, prs) = DropClosePoints(raw, rawPressure);
        var widths = SmoothedWidths(prs, baseWidth);
        if (pts.Count == 1)
        {
            var r = widths[0] / 2;
            return [new PathOp.Ellipse(pts[0].X - r, pts[0].Y - r, 2 * r, 2 * r)];
        }
        var (left, right) = Edges(pts, widths);
        var ops = new List<PathOp> { new PathOp.MoveTo(left[0]) };
        ops.AddRange(left.Skip(1).Select(p => (PathOp)new PathOp.LineTo(p)));
        ops.Add(new PathOp.ArcTo(right[^1], widths[^1] / 2)); // end cap
        ops.AddRange(Enumerable.Reverse(right).Skip(1).Select(p => (PathOp)new PathOp.LineTo(p)));
        ops.Add(new PathOp.ArcTo(left[0], widths[0] / 2));    // start cap
        ops.Add(new PathOp.Close());
        return ops;
    }

    /// <summary>Skips points closer than 0.75 px to the previous one (keeps the last), with their pressures.</summary>
    private static (List<Pt> Points, List<double> Pressures) DropClosePoints(IReadOnlyList<Pt> raw, IReadOnlyList<double> pressure)
    {
        var pts = new List<Pt>();
        var prs = new List<double>();
        for (var i = 0; i < raw.Count; i++)
        {
            if (pts.Count > 0 && i != raw.Count - 1 && Distance(raw[i], pts[^1]) < 0.75) continue;
            pts.Add(raw[i]);
            prs.Add(pressure[i]);
        }
        return (pts, prs);
    }

    /// <summary>Line width at each point from the pressure averaged over 5 neighbours.</summary>
    private static List<double> SmoothedWidths(List<double> prs, double baseWidth) =>
        prs.Select((_, i) =>
        {
            int lo = Math.Max(i - 2, 0), hi = Math.Min(i + 2, prs.Count - 1);
            var avg = prs.Skip(lo).Take(hi - lo + 1).Average();
            return baseWidth * (0.35 + 1.3 * Math.Clamp(avg, 0, 1));
        }).ToList();

    /// <summary>The two sides of the outline: each point moved half its width along the normal.</summary>
    private static (List<Pt> Left, List<Pt> Right) Edges(List<Pt> pts, List<double> widths)
    {
        var left = new List<Pt>(pts.Count);
        var right = new List<Pt>(pts.Count);
        for (var i = 0; i < pts.Count; i++)
        {
            Pt a = pts[Math.Max(i - 1, 0)], b = pts[Math.Min(i + 1, pts.Count - 1)];
            double dx = b.X - a.X, dy = b.Y - a.Y, len = Math.Max(Math.Sqrt(dx * dx + dy * dy), 0.0001);
            dx /= len; dy /= len;
            var h = widths[i] / 2;
            left.Add(new Pt(pts[i].X - dy * h, pts[i].Y + dx * h));
            right.Add(new Pt(pts[i].X + dy * h, pts[i].Y - dx * h));
        }
        return (left, right);
    }

    public static List<PathOp> Shape(Tool tool, Pt a, Pt b, double lineWidth)
    {
        var box = Box(a, b);
        switch (tool)
        {
            case Tool.Arrow:
                var ops = new List<PathOp> { new PathOp.MoveTo(a), new PathOp.LineTo(b) };
                if (Distance(a, b) > 1)
                {
                    var (l, r) = Geometry.Arrowhead(a, b, lineWidth);
                    ops.AddRange([new PathOp.MoveTo(l), new PathOp.LineTo(b), new PathOp.LineTo(r)]);
                }
                return ops;
            case Tool.Rectangle:
                return [new PathOp.MoveTo(new Pt(box.X, box.Y)), new PathOp.LineTo(new Pt(box.X + box.W, box.Y)),
                        new PathOp.LineTo(new Pt(box.X + box.W, box.Y + box.H)), new PathOp.LineTo(new Pt(box.X, box.Y + box.H)),
                        new PathOp.Close()];
            case Tool.Ellipse:
                return [new PathOp.Ellipse(box.X, box.Y, box.W, box.H)];
            case Tool.Phone:
                return Phone(box);
            case Tool.Person:
                return Person(box);
            default:
                return [new PathOp.MoveTo(a), new PathOp.LineTo(b)];
        }
    }

    public static (double X, double Y, double W, double H) Box(Pt a, Pt b) =>
        (Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));

    /// <summary>Smartphone outline: rounded body, speaker slot and home indicator.</summary>
    private static List<PathOp> Phone((double X, double Y, double W, double H) r) =>
    [
        new PathOp.RoundedRect(r.X, r.Y, r.W, r.H, Math.Min(r.W, r.H) * 0.18),
        new PathOp.MoveTo(new Pt(r.X + r.W * 0.4, r.Y + r.H * 0.06)), new PathOp.LineTo(new Pt(r.X + r.W * 0.6, r.Y + r.H * 0.06)),
        new PathOp.MoveTo(new Pt(r.X + r.W * 0.35, r.Y + r.H * 0.94)), new PathOp.LineTo(new Pt(r.X + r.W * 0.65, r.Y + r.H * 0.94)),
    ];

    /// <summary>Stick figure: head, body, arms and legs filling the box.</summary>
    private static List<PathOp> Person((double X, double Y, double W, double H) r)
    {
        var head = Math.Min(r.W * 0.25, r.H * 0.12);
        var cx = r.X + r.W / 2;
        var neck = r.Y + head * 2;
        var hip = r.Y + r.H * 0.62;
        var shoulder = new Pt(cx, neck + r.H * 0.08);
        return
        [
            new PathOp.Ellipse(cx - head, r.Y, head * 2, head * 2),
            new PathOp.MoveTo(new Pt(cx, neck)), new PathOp.LineTo(new Pt(cx, hip)),
            new PathOp.MoveTo(new Pt(r.X, r.Y + r.H * 0.45)), new PathOp.LineTo(shoulder), new PathOp.LineTo(new Pt(r.X + r.W, r.Y + r.H * 0.45)),
            new PathOp.MoveTo(new Pt(r.X + r.W * 0.1, r.Y + r.H)), new PathOp.LineTo(new Pt(cx, hip)), new PathOp.LineTo(new Pt(r.X + r.W * 0.9, r.Y + r.H)),
        ];
    }

    private static double Distance(Pt a, Pt b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
}

/// <summary>Text sizing shared by every client (see docs/protocol.md).</summary>
public static class TextRules
{
    /// <summary>Box height = font size × this.</summary>
    public const double LineHeightFactor = 1.25;

    /// <summary>3, 6, 11, 18 pt lines give 12, 24, 44, 72 pt text.</summary>
    public static double FontSize(WidthPreset width) => width.Points() * 4;

    public static double LineHeight(double fontSize) => Math.Ceiling(fontSize * LineHeightFactor);

    /// <summary>Font size for a text box of the given height.</summary>
    public static double FontSizeForBox(double boxHeight) => boxHeight / LineHeightFactor;

    /// <summary>Baseline from the box top: the font's full height (ascent + descent) is centred in the box.</summary>
    public static double BaselineOffset(double boxHeight, double ascent, double descent) => (boxHeight - (ascent + descent)) / 2 + ascent;

    /// <summary>
    /// Normalized [top-left, bottom-right] corners for text of <paramref name="textWidth"/>×<paramref name="textHeight"/>
    /// typed in a field at (fieldX, fieldY, fieldH): centred on the field and moved, never shrunk, to stay on screen.
    /// </summary>
    public static StrokePoint[] Corners(double textWidth, double textHeight, double fieldX, double fieldY, double fieldH,
                                        double viewWidth, double viewHeight)
    {
        var x = Math.Clamp(fieldX + 2, 0, Math.Max(viewWidth - textWidth, 0));
        var y = Math.Clamp(fieldY + (fieldH - textHeight) / 2, 0, Math.Max(viewHeight - textHeight, 0));
        return [Geometry.Normalize(new Pt(x, y), viewWidth, viewHeight),
                Geometry.Normalize(new Pt(x + textWidth, y + textHeight), viewWidth, viewHeight)];
    }
}
