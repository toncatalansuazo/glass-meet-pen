using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using Glasspen.Core.Model;
using Glasspen.Core.Render;
using Glasspen.Windows.App;
using Geometry = System.Windows.Media.Geometry;

namespace Glasspen.Windows.Overlay;

/// <summary>
/// Draws every committed and live stroke of the document. Committed geometry is cached per stroke and
/// their z-order is sorted only when they change; a live stroke is rebuilt only when it has new points.
/// </summary>
public sealed class StrokeLayer : FrameworkElement
{
    private readonly record struct Item(Geometry Geometry, Pen? Pen, Brush? Fill, double Alpha);

    private readonly AppModel _model;
    private readonly Dictionary<Guid, Item> _cache = new();
    private readonly Dictionary<Guid, ((int Count, StrokePoint Last) Key, Item Item)> _liveCache = new();
    private List<Stroke>? _ordered;
    private readonly Dictionary<Guid, (DateTime Start, TimeSpan Duration)> _fading = new();
    private Size _cachedFor;

    public StrokeLayer(AppModel model)
    {
        _model = model;
        IsHitTestVisible = false;
        model.DocumentChanged += e =>
        {
            switch (e)
            {
                case DocumentEvent.CommittedChanged c:
                    foreach (var id in c.Removed) { _cache.Remove(id); _fading.Remove(id); }
                    foreach (var s in c.Added) { _cache.Remove(s.Id); _liveCache.Remove(s.Id); }
                    _ordered = null;
                    break;
                case DocumentEvent.LiveCancelled lc:
                    _liveCache.Remove(lc.Id);
                    break;
            }
            InvalidateVisual();
        };
        model.FadeStrokes += (ids, duration) =>
        {
            foreach (var id in ids) _fading[id] = (DateTime.UtcNow, duration);
            CompositionTarget.Rendering -= OnFrame;
            CompositionTarget.Rendering += OnFrame;
        };
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        if (_fading.Count == 0) { CompositionTarget.Rendering -= OnFrame; return; }
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = RenderSize;
        if (size != _cachedFor) { _cache.Clear(); _liveCache.Clear(); _cachedFor = size; }
        var ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var s in _ordered ??= _model.Document.OrderedStrokes)
        {
            if (!_cache.TryGetValue(s.Id, out var item))
            {
                if (Build(s, size, ppd) is not { } built) continue;
                _cache[s.Id] = item = built;
            }
            Draw(dc, item, FadeFactor(s.Id));
        }
        foreach (var s in _model.Document.Live.Values)
            if (LiveItem(s, size, ppd) is { } live) Draw(dc, live, 1);
    }

    /// <summary>A live stroke's geometry, rebuilt only when points were added (or a shape's end moved).</summary>
    private Item? LiveItem(Stroke s, Size size, double ppd)
    {
        var key = (s.Points.Count, s.Points.Count > 0 ? s.Points[^1] : default); // a shape keeps 2 points but moves its end
        if (_liveCache.TryGetValue(s.Id, out var cached) && cached.Key == key) return cached.Item;
        if (Build(s, size, ppd) is not { } item) return null;
        _liveCache[s.Id] = (key, item);
        return item;
    }

    private double FadeFactor(Guid id)
    {
        if (!_fading.TryGetValue(id, out var f)) return 1;
        var t = (DateTime.UtcNow - f.Start).TotalSeconds / Math.Max(f.Duration.TotalSeconds, 0.01);
        return Math.Clamp(1 - t, 0, 1);
    }

    private static void Draw(DrawingContext dc, Item item, double fade)
    {
        dc.PushOpacity(item.Alpha * fade);
        dc.DrawGeometry(item.Fill, item.Pen, item.Geometry);
        dc.Pop();
    }

    private static Item? Build(Stroke s, Size size, double ppd)
    {
        if (s.Tool == Tool.Text)
        {
            var text = WpfDrawing.TextGeometry(s, size.Width, size.Height, ppd);
            return text is null ? null : new Item(text, null, Frozen(new SolidColorBrush(WpfDrawing.ToColor(s.Color with { A = 1 }))), s.EffectiveAlpha);
        }
        if (StrokePath.Render(s, size.Width, size.Height) is not { } r) return null;
        var brush = Frozen(new SolidColorBrush(WpfDrawing.ToColor(r.Color)));
        var geometry = WpfDrawing.Build(r);
        if (r.Mode == PaintMode.Fill) return new Item(geometry, null, brush, r.Alpha);
        var pen = new Pen(brush, r.LineWidth) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        pen.Freeze();
        return new Item(geometry, pen, null, r.Alpha);
    }

    private static T Frozen<T>(T f) where T : Freezable { f.Freeze(); return f; }
}
