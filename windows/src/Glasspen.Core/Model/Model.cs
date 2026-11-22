namespace Glasspen.Core.Model;

/// <summary>Who produced a stroke: the computer's mouse, or a paired phone/iPad.</summary>
public readonly record struct SourceId(string RawValue)
{
    public static readonly SourceId Mouse = new("mouse");
    public override string ToString() => RawValue;
}

/// <summary>Drawing tools, in toolbar order. The wire value is the lower-case name (see docs/protocol.md).</summary>
public enum Tool { Pen, Highlighter, Line, Arrow, Rectangle, Ellipse, Phone, Person, Text, Eraser }

public static class ToolInfo
{
    public static readonly Tool[] All = Enum.GetValues<Tool>();

    public static string WireName(this Tool tool) => tool.ToString().ToLowerInvariant();

    public static bool TryParse(string wire, out Tool tool)
    {
        foreach (var t in All)
        {
            if (t.WireName() == wire) { tool = t; return true; }
        }
        tool = Tool.Pen;
        return false;
    }

    /// <summary>Shapes are defined by two points (start, end) instead of a freehand path.</summary>
    public static bool IsShape(this Tool t) => t is Tool.Line or Tool.Arrow or Tool.Rectangle or Tool.Ellipse or Tool.Phone or Tool.Person;

    public static bool IsFigure(this Tool t) => t is Tool.Phone or Tool.Person;

    /// <summary>Natural width/height of a figure; Shift keeps it while dragging.</summary>
    public static float? FigureAspect(this Tool t) => t switch { Tool.Phone => 0.5f, Tool.Person => 0.55f, _ => null };

    public static string DisplayName(this Tool t) => t.ToString();

    /// <summary>Single-letter key while drawing.</summary>
    public static char ShortcutKey(this Tool t) => t switch
    {
        Tool.Pen => 'p', Tool.Highlighter => 'h', Tool.Line => 'l', Tool.Arrow => 'a', Tool.Rectangle => 'r',
        Tool.Ellipse => 'o', Tool.Phone => 'i', Tool.Person => 'f', Tool.Text => 't', _ => 'e',
    };

    /// <summary>Number key of the global Alt+1…0 shortcut, in toolbar order (the 10th tool is 0).</summary>
    public static int ShortcutDigit(this Tool t) => (Array.IndexOf(All, t) + 1) % 10;

    public static string GlobalShortcut(this Tool t) => $"Alt+{t.ShortcutDigit()}";
}

public readonly record struct RgbaColor(float R, float G, float B, float A = 1)
{
    public static readonly RgbaColor[] Palette =
    [
        new(1.00f, 0.23f, 0.19f), // red
        new(1.00f, 0.58f, 0.00f), // orange
        new(1.00f, 0.84f, 0.04f), // yellow
        new(0.20f, 0.78f, 0.35f), // green
        new(0.00f, 0.48f, 1.00f), // blue
        new(0.69f, 0.32f, 0.87f), // purple
        new(1.00f, 1.00f, 1.00f), // white
        new(0.00f, 0.00f, 0.00f), // black
    ];

    public RgbaColor WithAlpha(float a) => this with { A = a };
}

/// <summary>A point in display-normalized coordinates: (0,0) top-left, (1,1) bottom-right. P is pressure 0…1.</summary>
public readonly record struct StrokePoint(float X, float Y, float P = 1);

/// <summary>Stroke width presets in desktop points at the display's native size.</summary>
public enum WidthPreset { Fine = 0, Medium = 1, Bold = 2, Heavy = 3 }

public static class WidthPresetInfo
{
    public static float Points(this WidthPreset w) => w switch
    {
        WidthPreset.Fine => 3, WidthPreset.Medium => 6, WidthPreset.Bold => 11, _ => 18,
    };

    public static float Normalized(this WidthPreset w, float displayWidth) => w.Points() / Math.Max(displayWidth, 1);
}

public readonly record struct ToolState(Tool Tool, RgbaColor Color, WidthPreset Width)
{
    public static ToolState Default => new(Tool.Pen, RgbaColor.Palette[0], WidthPreset.Medium);
}

/// <summary>A stroke. Width is a fraction of display width. Shapes: Points = [start, end]. Text: [top-left, bottom-right].</summary>
public sealed record Stroke
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required SourceId SourceId { get; init; }
    public required Tool Tool { get; init; }
    public required RgbaColor Color { get; init; }
    public required float Width { get; init; }
    public required IReadOnlyList<StrokePoint> Points { get; init; }
    /// <summary>Order assigned when committed; keeps z-order stable across undo/redo and sync.</summary>
    public ulong Seq { get; init; }
    public DateTime CreatedAt { get; init; } = DateTime.UtcNow;
    /// <summary>The typed text, for the Text tool only.</summary>
    public string? Text { get; init; }

    /// <summary>Highlighters are at most 35% of the ink opacity.</summary>
    public float EffectiveAlpha => Tool == Tool.Highlighter ? 0.35f * Color.A : Color.A;

    /// <summary>Highlighters are wider than the selected preset.</summary>
    public float EffectiveWidth => Tool == Tool.Highlighter ? Width * 2.5f : Width;

    public bool Equals(Stroke? other) =>
        other is not null && Id == other.Id && SourceId == other.SourceId && Tool == other.Tool && Color == other.Color
        && Width == other.Width && Points.SequenceEqual(other.Points) && Seq == other.Seq
        && Math.Abs((CreatedAt - other.CreatedAt).TotalMilliseconds) < 1 && Text == other.Text;

    public override int GetHashCode() => Id.GetHashCode();
}

/// <summary>The display the overlay covers, in points (device-independent pixels on Windows).</summary>
public readonly record struct DisplayInfo(uint Id, string Name, float Width, float Height)
{
    public float Aspect => Width / Math.Max(Height, 1);
}

/// <summary>When the whiteboard covers the screen: it stays while clicking through and goes away with the toolbar.</summary>
public static class Whiteboard
{
    public static float VisibleOpacity(bool enabled, double opacity, bool toolbarVisible) =>
        enabled && toolbarVisible ? (float)opacity : 0;
}
