using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using Glasspen.Core.Model;
using Glasspen.Core.Render;
using Geometry = System.Windows.Media.Geometry;
using CoreGeometry = Glasspen.Core.Model.Geometry;

namespace Glasspen.Windows.App;

/// <summary>Turns core drawing commands into WPF geometry, and lays out text strokes.</summary>
public static class WpfDrawing
{
    public static readonly Typeface TextFace = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

    public static Color ToColor(RgbaColor c, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(255 * Math.Clamp(c.A * alpha, 0, 1)), (byte)(255 * c.R), (byte)(255 * c.G), (byte)(255 * c.B));

    public static Geometry Build(RenderedStroke r)
    {
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            var figureOpen = false;
            foreach (var op in r.Ops) figureOpen = Add(ctx, op, figureOpen, filled: r.Mode == PaintMode.Fill);
        }
        g.Freeze();
        return g;
    }

    /// <summary>Adds one drawing command; returns whether a figure is still open for the next one.</summary>
    private static bool Add(StreamGeometryContext ctx, PathOp op, bool figureOpen, bool filled)
    {
        switch (op)
        {
            case PathOp.MoveTo m:
                ctx.BeginFigure(P(m.P), filled, false);
                return true;
            case PathOp.LineTo l:
                if (!figureOpen) ctx.BeginFigure(P(l.P), filled, false);
                ctx.LineTo(P(l.P), true, true);
                return true;
            case PathOp.CubicTo c:
                ctx.BezierTo(P(c.C1), P(c.C2), P(c.P), true, true);
                return figureOpen;
            case PathOp.ArcTo a:
                ctx.ArcTo(P(a.P), new Size(a.Radius, a.Radius), 0, false, SweepDirection.Counterclockwise, true, true);
                return figureOpen;
            case PathOp.Ellipse e:
                AddEllipse(ctx, e.X, e.Y, e.W, e.H);
                return false;
            case PathOp.RoundedRect rr:
                AddRoundedRect(ctx, rr);
                return false;
            default: // Close
                return false;
        }
    }

    private static Point P(Pt p) => new(p.X, p.Y);

    private static void AddEllipse(StreamGeometryContext ctx, double x, double y, double w, double h)
    {
        double rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry;
        ctx.BeginFigure(new Point(cx + rx, cy), true, true);
        ctx.ArcTo(new Point(cx - rx, cy), new Size(Math.Max(rx, 0.01), Math.Max(ry, 0.01)), 0, false, SweepDirection.Clockwise, true, true);
        ctx.ArcTo(new Point(cx + rx, cy), new Size(Math.Max(rx, 0.01), Math.Max(ry, 0.01)), 0, false, SweepDirection.Clockwise, true, true);
    }

    private static void AddRoundedRect(StreamGeometryContext ctx, PathOp.RoundedRect r)
    {
        var c = Math.Min(r.Corner, Math.Min(r.W, r.H) / 2);
        var s = new Size(c, c);
        ctx.BeginFigure(new Point(r.X + c, r.Y), false, true);
        ctx.LineTo(new Point(r.X + r.W - c, r.Y), true, true);
        ctx.ArcTo(new Point(r.X + r.W, r.Y + c), s, 0, false, SweepDirection.Clockwise, true, true);
        ctx.LineTo(new Point(r.X + r.W, r.Y + r.H - c), true, true);
        ctx.ArcTo(new Point(r.X + r.W - c, r.Y + r.H), s, 0, false, SweepDirection.Clockwise, true, true);
        ctx.LineTo(new Point(r.X + c, r.Y + r.H), true, true);
        ctx.ArcTo(new Point(r.X, r.Y + r.H - c), s, 0, false, SweepDirection.Clockwise, true, true);
        ctx.LineTo(new Point(r.X, r.Y + c), true, true);
        ctx.ArcTo(new Point(r.X + c, r.Y), s, 0, false, SweepDirection.Clockwise, true, true);
    }

    public static FormattedText Format(string text, double fontSize, Brush brush, double pixelsPerDip) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, TextFace, Math.Max(fontSize, 0.5), brush, pixelsPerDip);

    /// <summary>Box size text needs at a font size (see TextRules).</summary>
    public static Size MeasureText(string text, double fontSize, double pixelsPerDip)
    {
        var f = Format(text, fontSize, Brushes.Black, pixelsPerDip);
        return new Size(Math.Ceiling(f.WidthIncludingTrailingWhitespace), TextRules.LineHeight(fontSize));
    }

    /// <summary>Glyph outlines of a text stroke in its box: font size = height / 1.25, ascent + descent centred.</summary>
    public static Geometry? TextGeometry(Stroke stroke, double width, double height, double pixelsPerDip)
    {
        if (string.IsNullOrEmpty(stroke.Text) || stroke.Points.Count < 2) return null;
        var (x, y, _, h) = StrokePath.Box(CoreGeometry.Denormalize(stroke.Points[0], width, height), CoreGeometry.Denormalize(stroke.Points[1], width, height));
        var fontSize = TextRules.FontSizeForBox(h);
        var f = Format(stroke.Text, fontSize, Brushes.Black, pixelsPerDip);
        double ascent = fontSize, descent = fontSize * 0.25;
        if (TextFace.TryGetGlyphTypeface(out var glyphs))
        {
            ascent = glyphs.Baseline * fontSize;
            descent = (glyphs.Height - glyphs.Baseline) * fontSize;
        }
        var baselineY = y + TextRules.BaselineOffset(h, ascent, descent);
        var geometry = f.BuildGeometry(new Point(x, baselineY - f.Baseline));
        geometry.Freeze();
        return geometry;
    }

    /// <summary>Whether the text has anything to draw (emoji and spaces don't).</summary>
    public static bool IsDrawable(string text, double pixelsPerDip) =>
        !string.IsNullOrWhiteSpace(text) && !Format(text, 24, Brushes.Black, pixelsPerDip).BuildGeometry(new Point()).Bounds.IsEmpty;
}
