using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Glasspen.Core.Model;
using Glasspen.Core.Render;
using Glasspen.Windows.App;
using Geometry = Glasspen.Core.Model.Geometry;

namespace Glasspen.Windows.Overlay;

/// <summary>
/// Transparent, always-on-top window over the primary display. While not drawing, clicks pass through
/// to the apps below (WS_EX_TRANSPARENT); while drawing, it takes the mouse and keyboard. Screen-sharing
/// apps capture it, so everyone in the call sees the drawings.
/// </summary>
public sealed class OverlayWindow : Window
{
    private readonly AppModel _model;
    private readonly Rectangle _board = new() { Fill = Brushes.White, Opacity = 0, IsHitTestVisible = false };
    private readonly Canvas _surface = new();
    private readonly StrokeLayer _strokes;
    private IntPtr _hwnd;
    private Stroke? _active;
    private bool _erasing;
    private TextBox? _textEditor;
    private (double FontSize, RgbaColor Color, WidthPreset Width)? _textStyle;

    public OverlayWindow(AppModel model)
    {
        _model = model;
        _strokes = new StrokeLayer(model);
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
        Title = "Glasspen Meet overlay";
        var root = new Grid();
        root.Children.Add(_board);
        root.Children.Add(_surface);   // takes the mouse while drawing (nearly invisible background)
        root.Children.Add(_strokes);
        Content = root;
        PlaceOnPrimaryScreen();

        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.SetExStyle(_hwnd, Native.WS_EX_TOOLWINDOW, true); // not in Alt+Tab
            ApplyDrawMode(false);
        };
        model.DrawModeChanged += ApplyDrawMode;
        model.Changed += () =>
        {
            _board.Opacity = model.WhiteboardOpacity;
            if (model.MouseTool.Tool != Tool.Text) FinishText();
            UpdateCursor();
        };
        _surface.MouseLeftButtonDown += OnMouseDown;
        _surface.MouseMove += OnMouseMove;
        _surface.MouseLeftButtonUp += OnMouseUp;
        KeyDown += OnKeyDown;
        SystemParameters.StaticPropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(SystemParameters.PrimaryScreenWidth) or nameof(SystemParameters.PrimaryScreenHeight)) PlaceOnPrimaryScreen();
        };
    }

    private void PlaceOnPrimaryScreen()
    {
        Left = 0;
        Top = 0;
        Width = SystemParameters.PrimaryScreenWidth;
        Height = SystemParameters.PrimaryScreenHeight;
        _model.RefreshDisplay();
    }

    private void ApplyDrawMode(bool on)
    {
        if (_hwnd == IntPtr.Zero) return;
        Native.SetExStyle(_hwnd, Native.WS_EX_TRANSPARENT, !on);
        Native.SetExStyle(_hwnd, Native.WS_EX_NOACTIVATE, !on);
        // Fully transparent pixels never get the mouse in a layered window, so paint an almost invisible one.
        _surface.Background = on ? new SolidColorBrush(Color.FromArgb(1, 255, 255, 255)) : null;
        if (on)
        {
            Activate();
            Native.SetForegroundWindow(_hwnd);
            Focus();
        }
        else
        {
            FinishActiveStroke(cancel: true);
            FinishText();
        }
        UpdateCursor();
    }

    private void UpdateCursor()
    {
        Cursor = !_model.DrawMode ? null : _model.MouseTool.Tool switch
        {
            Tool.Eraser => Cursors.Cross,
            Tool.Text => Cursors.IBeam,
            _ => Cursors.Pen,
        };
    }

    // MARK: Mouse

    private StrokePoint Normalized(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        var pressure = e.StylusDevice?.GetStylusPoints(this).LastOrDefault().PressureFactor ?? 1f;
        return Geometry.Normalize(new Pt(p.X, p.Y), ActualWidth, ActualHeight, e.StylusDevice is null ? 1 : pressure);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_model.DrawMode) return;
        var state = _model.MouseTool;
        if (state.Tool == Tool.Text)
        {
            // A click while typing places the text; the next click starts a new one.
            if (_textEditor is not null) FinishText(); else BeginText(e.GetPosition(this));
            return;
        }
        _surface.CaptureMouse();
        var point = Normalized(e);
        if (state.Tool == Tool.Eraser)
        {
            _erasing = true;
            _model.Erase(SourceId.Mouse, [point], _model.EraserRadius(state.Width));
            return;
        }
        _active = new Stroke
        {
            SourceId = SourceId.Mouse, Tool = state.Tool, Color = _model.InkColor,
            Width = state.Width.Normalized(_model.Display.Width), Points = [point],
        };
        _model.Begin(_active);
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_model.DrawMode || e.LeftButton != MouseButtonState.Pressed) return;
        var point = Normalized(e);
        if (_erasing)
        {
            _model.Erase(SourceId.Mouse, [point], _model.EraserRadius(_model.MouseTool.Width));
            return;
        }
        if (_active is not { } stroke) return;
        if (stroke.Tool.IsShape() && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
            point = Geometry.Constrain(stroke.Tool, stroke.Points[0], point, _model.Display.Aspect);
        _model.Append(SourceId.Mouse, stroke.Id, [point]);
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        _surface.ReleaseMouseCapture();
        if (_erasing) { _erasing = false; return; }
        if (_active is { } stroke && stroke.Tool.IsFigure() && IsClick(stroke))
        {
            PlaceDefaultFigure(stroke);
            return;
        }
        FinishActiveStroke(cancel: false);
    }

    /// <summary>A figure whose two points are a few points apart was clicked, not dragged.</summary>
    private bool IsClick(Stroke stroke)
    {
        var live = _model.Document.Live.TryGetValue(SourceId.Mouse, out var s) ? s : stroke;
        StrokePoint a = live.Points[0], b = live.Points[^1];
        double dx = (b.X - a.X) * _model.Display.Width, dy = (b.Y - a.Y) * _model.Display.Height;
        return Math.Sqrt(dx * dx + dy * dy) < 6;
    }

    /// <summary>Replaces a clicked figure with one of default size centered on the click.</summary>
    private void PlaceDefaultFigure(Stroke stroke)
    {
        _active = null;
        _model.Cancel(SourceId.Mouse, stroke.Id);
        if (stroke.Tool.FigureAspect() is not { } aspect) return;
        var center = stroke.Points[0];
        const float height = 120;
        var w = height * aspect / Math.Max(_model.Display.Width, 1) / 2;
        var h = height / Math.Max(_model.Display.Height, 1) / 2;
        var placed = stroke with
        {
            Id = Guid.NewGuid(),
            Points = [new StrokePoint(center.X - w, center.Y - h), new StrokePoint(center.X + w, center.Y + h)],
        };
        _model.Begin(placed);
        _model.End(SourceId.Mouse, placed.Id);
    }

    private void FinishActiveStroke(bool cancel)
    {
        _erasing = false;
        if (_active is not { } stroke) return;
        _active = null;
        if (cancel) _model.Cancel(SourceId.Mouse, stroke.Id); else _model.End(SourceId.Mouse, stroke.Id);
    }

    // MARK: Keyboard (while drawing)

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (_textEditor is not null || !_model.DrawMode) return; // keys belong to the text being typed
        var mods = Keyboard.Modifiers;
        if (mods.HasFlag(ModifierKeys.Control)) e.Handled = HandleControlKey(e.Key, mods.HasFlag(ModifierKeys.Shift));
        else if (e.Key == Key.Escape) { _model.SetDrawMode(false); e.Handled = true; }
        else if ((mods & ~ModifierKeys.Shift) == ModifierKeys.None) e.Handled = HandleToolKey(e.Key);
    }

    /// <summary>Ctrl+Z undo, Ctrl+Shift+Z and Ctrl+Y redo.</summary>
    private bool HandleControlKey(Key key, bool shift)
    {
        if (key == Key.Z && !shift) _model.Undo();
        else if (key is Key.Z or Key.Y) _model.Redo();
        else return false;
        return true;
    }

    /// <summary>Letters pick tools, 1–8 colors, [ and ] the width.</summary>
    private bool HandleToolKey(Key key)
    {
        if (key is >= Key.A and <= Key.Z)
        {
            var letter = (char)('a' + (key - Key.A));
            var tools = ToolInfo.All.Where(t => t.ShortcutKey() == letter).ToList();
            if (tools.Count == 0) return false;
            _model.SelectTool(tools[0]);
            return true;
        }
        if (key is >= Key.D1 and <= Key.D8)
        {
            _model.SelectColor(RgbaColor.Palette[key - Key.D1]);
            return true;
        }
        if (key is not (Key.OemOpenBrackets or Key.OemCloseBrackets)) return false;
        var i = (int)_model.MouseTool.Width + (key == Key.OemCloseBrackets ? 1 : -1);
        if (i is >= 0 and <= 3) _model.SelectWidth((WidthPreset)i);
        return true;
    }

    // MARK: Text

    private void BeginText(Point at)
    {
        var style = (FontSize: TextRules.FontSize(_model.MouseTool.Width), Color: _model.InkColor, Width: _model.MouseTool.Width);
        var height = TextRules.LineHeight(style.FontSize) + 4;
        var box = new TextBox
        {
            FontFamily = WpfDrawing.TextFace.FontFamily, FontSize = style.FontSize, Foreground = new SolidColorBrush(WpfDrawing.ToColor(style.Color)),
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            MinWidth = 120, Height = height, AcceptsReturn = false, CaretBrush = new SolidColorBrush(WpfDrawing.ToColor(style.Color with { A = 1 })),
        };
        Canvas.SetLeft(box, at.X);
        Canvas.SetTop(box, at.Y - height / 2);
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { FinishText(); e.Handled = true; }
            else if (e.Key == Key.Escape) { FinishText(cancel: true); e.Handled = true; }
        };
        _surface.Children.Add(box);
        _textEditor = box;
        _textStyle = style;
        box.Focus();
        Keyboard.Focus(box);
    }

    /// <summary>Turns the typed text into a stroke and closes the field. Empty or emoji-only text places nothing.</summary>
    private void FinishText(bool cancel = false)
    {
        if (_textEditor is not { } box || _textStyle is not { } style) return;
        _textEditor = null;
        _textStyle = null;
        var text = box.Text.Trim();
        double fieldX = Canvas.GetLeft(box), fieldY = Canvas.GetTop(box), fieldH = box.Height;
        _surface.Children.Remove(box);
        Focus();
        var ppd = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        if (cancel || !WpfDrawing.IsDrawable(text, ppd)) return;
        var size = WpfDrawing.MeasureText(text, style.FontSize, ppd);
        var stroke = new Stroke
        {
            SourceId = SourceId.Mouse, Tool = Tool.Text, Color = style.Color, Width = style.Width.Normalized(_model.Display.Width),
            Points = TextRules.Corners(size.Width, size.Height, fieldX, fieldY, fieldH, ActualWidth, ActualHeight), Text = text,
        };
        _model.Begin(stroke);
        _model.End(SourceId.Mouse, stroke.Id);
    }
}
