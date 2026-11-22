using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Threading;
using Glasspen.Core.Model;
using Glasspen.Core.Protocol;

namespace Glasspen.Windows.App;

/// <summary>
/// Central state (port of the Mac app's AppModel). Owns the drawing document and routes intents from
/// the mouse (overlay) and the phone (server) into it, then fans events out to the overlay and the phone.
/// Use it from the UI thread only.
/// </summary>
public sealed class AppModel : IDrawingTarget
{
    public AppSettings Settings { get; }
    public Document Document { get; } = new();

    public event Action? Changed;                         // any UI state below changed
    public event Action<DocumentEvent>? DocumentChanged;
    public event Action<SourceId, ToolState>? ToolChanged;
    public event Action<bool>? DrawModeChanged;
    public event Action<DisplayInfo>? DisplayChanged;
    /// <summary>Asks the overlay to animate fading strokes before they're removed.</summary>
    public event Action<IReadOnlyList<Guid>, TimeSpan>? FadeStrokes;

    public static readonly double[] FadeChoices = [1, 3, 5];
    private static readonly TimeSpan FadeAnimation = TimeSpan.FromSeconds(0.6);

    public AppModel(AppSettings settings)
    {
        Settings = settings;
        Display = CurrentDisplay();
    }

    // MARK: State

    public bool DrawMode { get; private set; }
    public ToolState MouseTool { get; private set; } = ToolState.Default;
    public string? PhoneName { get; private set; }
    public bool BoardEnabled { get; private set; }
    public bool ToolbarVisible { get; private set; } = true;
    public DisplayInfo Display { get; private set; }
    public bool CanUndo => Document.CanUndo(SourceId.Mouse);
    public bool CanRedo => Document.CanRedo(SourceId.Mouse);

    /// <summary>Seconds before new strokes fade away; null keeps them until cleared.</summary>
    public double? FadeDelay => Settings.FadeDelaySeconds > 0 ? Settings.FadeDelaySeconds : null;

    public float WhiteboardOpacity => Whiteboard.VisibleOpacity(BoardEnabled, Settings.BoardOpacity, ToolbarVisible);

    /// <summary>The selected color with the ink opacity as its alpha.</summary>
    public RgbaColor InkColor => MouseTool.Color.WithAlpha((float)Settings.InkOpacity);

    public static DisplayInfo CurrentDisplay() =>
        new(1, "Display", (float)SystemParameters.PrimaryScreenWidth, (float)SystemParameters.PrimaryScreenHeight);

    public void RefreshDisplay()
    {
        var display = CurrentDisplay();
        if (display == Display) return;
        Display = display;
        DisplayChanged?.Invoke(display);
        Changed?.Invoke();
    }

    // MARK: Modes

    public void SetDrawMode(bool on)
    {
        if (on == DrawMode) return;
        if (!on) Apply(Document.Cancel(SourceId.Mouse));
        DrawMode = on;
        DrawModeChanged?.Invoke(on);
        Changed?.Invoke();
    }

    public void ToggleDrawMode() => SetDrawMode(!DrawMode);

    /// <summary>Ctrl+Alt+Shift+1…0: pick a tool and start drawing with it.</summary>
    public void StartDrawing(Tool tool)
    {
        SelectTool(tool);
        SetDrawMode(true);
    }

    /// <summary>Hiding the toolbar also stops drawing and hides the whiteboard.</summary>
    public void SetToolbarVisible(bool visible)
    {
        ToolbarVisible = visible;
        if (!visible) SetDrawMode(false);
        Changed?.Invoke();
    }

    public void SetBoard(bool enabled)
    {
        BoardEnabled = enabled;
        Changed?.Invoke();
    }

    public void SetBoardOpacity(double opacity)
    {
        Settings.BoardOpacity = Math.Clamp(opacity, 0.1, 1);
        BoardEnabled = true; // moving the slider turns the board on
        SaveAndNotify();
    }

    public void SetInkOpacity(double opacity) { Settings.InkOpacity = Math.Clamp(opacity, 0.1, 1); SaveAndNotify(); }
    public void SetFadeDelay(double? seconds) { Settings.FadeDelaySeconds = seconds ?? 0; SaveAndNotify(); }
    public void SetToolbarOpacity(double opacity) { Settings.ToolbarOpacity = Math.Clamp(opacity, 0, 1); SaveAndNotify(); }
    public void SetToolbarPosition(ToolbarPosition position) { Settings.ToolbarPosition = position; SaveAndNotify(); }

    public void SetToolHotKeys(bool enabled)
    {
        Settings.ToolHotKeysEnabled = enabled;
        SaveAndNotify();
        HotKeysChanged?.Invoke();
    }

    public event Action? HotKeysChanged;

    private void SaveAndNotify()
    {
        Settings.Save();
        Changed?.Invoke();
    }

    // MARK: Tools (mouse)

    public void SelectTool(Tool tool) => SetMouseTool(MouseTool with { Tool = tool });
    public void SelectColor(RgbaColor color) => SetMouseTool(MouseTool with { Color = color });
    public void SelectWidth(WidthPreset width) => SetMouseTool(MouseTool with { Width = width });

    private void SetMouseTool(ToolState state)
    {
        if (state == MouseTool) return;
        MouseTool = state;
        ToolChanged?.Invoke(SourceId.Mouse, state);
        Changed?.Invoke();
    }

    /// <summary>Normalized eraser radius for a width preset.</summary>
    public float EraserRadius(WidthPreset width) => (width.Points() * 2 + 6) / Math.Max(Display.Width, 1);

    // MARK: Intents (any source)

    public void Begin(Stroke stroke) => Apply(Document.Begin(stroke));
    public void Append(SourceId source, Guid id, IReadOnlyList<StrokePoint> points) => Apply(Document.Append(source, id, points));
    public void End(SourceId source, Guid id) => Apply(Document.End(source, id));
    public void Cancel(SourceId source, Guid? id = null) => Apply(Document.Cancel(source, id));
    public void Erase(SourceId source, IReadOnlyList<StrokePoint> points, float radius) =>
        Apply(Document.Erase(source, points, radius, Display.Aspect));
    public void Undo(SourceId? source = null) => Apply(Document.Undo(source ?? SourceId.Mouse));
    public void Redo(SourceId? source = null) => Apply(Document.Redo(source ?? SourceId.Mouse));
    public void Clear(SourceId? source = null) => Apply(Document.Clear(source ?? SourceId.Mouse));

    private void Apply(List<DocumentEvent> events)
    {
        foreach (var e in events)
        {
            DocumentChanged?.Invoke(e);
            if (e is DocumentEvent.CommittedChanged { Added.Count: > 0 } c && FadeDelay is { } delay)
                ScheduleFade(c.Added.Select(s => s.Id).ToList(), delay);
        }
        // Only committed changes affect the toolbar (undo/redo); live points arrive many times a second.
        if (events.Any(e => e is DocumentEvent.CommittedChanged)) Changed?.Invoke();
    }

    // MARK: Fading ink

    private void ScheduleFade(List<Guid> ids, double delaySeconds)
    {
        var start = TimeSpan.FromSeconds(Math.Max(delaySeconds - FadeAnimation.TotalSeconds, 0.1));
        After(start, () =>
        {
            var alive = ids.Where(Document.Committed.ContainsKey).ToList();
            if (alive.Count == 0) return;
            FadeStrokes?.Invoke(alive, FadeAnimation);
            After(FadeAnimation, () => Apply(Document.Expire(alive)));
        });
    }

    private static void After(TimeSpan delay, Action action)
    {
        var timer = new DispatcherTimer { Interval = delay };
        timer.Tick += (_, _) => { timer.Stop(); action(); };
        timer.Start();
    }

    // MARK: Phone

    public void PhoneConnected(string? name)
    {
        PhoneName = name;
        Changed?.Invoke();
    }

    public void SetPhoneTool(ToolState state, SourceId source) => ToolChanged?.Invoke(source, state);
}
