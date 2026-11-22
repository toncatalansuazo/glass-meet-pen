using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Glasspen.Core.Model;
using Glasspen.Windows.App;

namespace Glasspen.Windows.Toolbar;

/// <summary>
/// Floating toolbar: a bar at the bottom or a sidebar on the left or right. Tools, colors and widths open
/// in pop-ups to keep it small. It never takes focus from the app you are presenting.
/// </summary>
public sealed class ToolbarWindow : Window
{
    private readonly AppModel _model;
    private readonly Action _showPairing, _showSettings;
    private readonly Border _frame = new() { CornerRadius = new CornerRadius(14), Padding = new Thickness(6) };
    private StackPanel _panel = new();
    private Button _drawButton = null!, _toolButton = null!, _colorButton = null!, _widthButton = null!;
    private Button _undoButton = null!, _redoButton = null!, _timerButton = null!, _boardButton = null!, _phoneButton = null!;
    private Slider _boardSlider = null!;
    private ToolbarPosition _builtFor;

    public ToolbarWindow(AppModel model, Action showPairing, Action showSettings)
    {
        _model = model;
        _showPairing = showPairing;
        _showSettings = showSettings;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Title = "Glasspen Meet toolbar";
        Content = _frame;
        _frame.Effect = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Opacity = 0.25 };
        Build();
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetExStyle(hwnd, Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW, true);
        };
        Loaded += (_, _) => Place();
        SizeChanged += (_, _) => Place();
        model.Changed += Refresh;
        Refresh();
    }

    private bool Vertical => _model.Settings.ToolbarPosition != ToolbarPosition.Bottom;

    /// <summary>Bottom: centered 24 px above the taskbar. Sides: 12 px from the edge, centered vertically.</summary>
    public void Place()
    {
        var area = SystemParameters.WorkArea;
        switch (_model.Settings.ToolbarPosition)
        {
            case ToolbarPosition.Bottom:
                Left = area.Left + (area.Width - ActualWidth) / 2;
                Top = area.Bottom - ActualHeight - 24;
                break;
            case ToolbarPosition.Left:
                Left = area.Left + 12;
                Top = area.Top + (area.Height - ActualHeight) / 2;
                break;
            default:
                Left = area.Right - ActualWidth - 12;
                Top = area.Top + (area.Height - ActualHeight) / 2;
                break;
        }
    }

    // MARK: Build

    private void Build()
    {
        _builtFor = _model.Settings.ToolbarPosition;
        _panel = new StackPanel { Orientation = Vertical ? Orientation.Vertical : Orientation.Horizontal };
        _frame.Child = _panel;

        var grip = Label("⋮⋮", "Drag to move the toolbar");
        grip.Cursor = Cursors.SizeAll;
        grip.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); };
        Add(grip);

        _drawButton = IconButton("", "", _model.ToggleDrawMode);
        Add(_drawButton);
        Divider();
        _toolButton = IconButton("", "", () => OpenPopup(_toolButton, ToolsPopup()));
        _colorButton = IconButton("●", "Color and ink opacity", () => OpenPopup(_colorButton, ColorsPopup()));
        _widthButton = IconButton("", "", () => OpenPopup(_widthButton, WidthsPopup()));
        Add(_toolButton); Add(_colorButton); Add(_widthButton);
        Divider();
        _undoButton = IconButton("↶", "Undo (Ctrl+Z)", () => _model.Undo());
        _redoButton = IconButton("↷", "Redo (Ctrl+Shift+Z)", () => _model.Redo());
        var clear = IconButton("🗑", $"Clear all ({HotKeys.ClearShortcut})", () => _model.Clear());
        _timerButton = IconButton("", "", () => OpenTimerMenu(_timerButton));
        Add(_undoButton); Add(_redoButton); Add(clear); Add(_timerButton);
        Divider();
        _boardButton = IconButton("⬜", "", () => _model.SetBoard(!_model.BoardEnabled));
        _boardSlider = new Slider
        {
            Minimum = 0.1, Maximum = 1, Width = Vertical ? 40 : 76, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 4, 0), Focusable = false,
        };
        _boardSlider.ValueChanged += (_, e) => { if (_boardSlider.IsMouseCaptureWithin) _model.SetBoardOpacity(e.NewValue); };
        Add(_boardButton); Add(_boardSlider);
        Divider();
        _phoneButton = IconButton("📱", "", _showPairing);
        Add(_phoneButton);
        Add(IconButton("⇔", "Toolbar position", () => OpenPositionMenu()));
        Add(IconButton("⚙", "Settings", _showSettings));
        Add(IconButton("✕", "Hide toolbar (the tray icon shows it again)", () => _model.SetToolbarVisible(false)));
    }

    private void Refresh()
    {
        if (_model.Settings.ToolbarPosition != _builtFor) { Build(); Place(); }
        Visibility = _model.ToolbarVisible ? Visibility.Visible : Visibility.Hidden;
        var opacity = _model.Settings.ToolbarOpacity;
        _frame.Background = new SolidColorBrush(Color.FromArgb((byte)(242 * opacity), 250, 250, 252));
        _frame.BorderBrush = new SolidColorBrush(Color.FromArgb((byte)(40 * opacity), 0, 0, 0));
        _frame.BorderThickness = new Thickness(1);
        ((DropShadowEffect)_frame.Effect).Opacity = 0.25 * opacity;

        SetIcon(_drawButton, _model.DrawMode ? "✎" : "🖱",
                _model.DrawMode ? $"Stop drawing ({HotKeys.DrawShortcut} or Esc)" : $"Start drawing ({HotKeys.DrawShortcut})");
        _drawButton.Background = _model.DrawMode ? new SolidColorBrush(Color.FromRgb(0, 120, 215)) : Brushes.Transparent;
        _drawButton.Foreground = _model.DrawMode ? Brushes.White : Brushes.Black;
        var tool = _model.MouseTool.Tool;
        SetIcon(_toolButton, Symbol(tool), $"Tool: {tool.DisplayName()}");
        _colorButton.Foreground = new SolidColorBrush(WpfDrawing.ToColor(_model.MouseTool.Color with { A = 1 }));
        SetIcon(_widthButton, WidthSymbol(_model.MouseTool.Width), $"Width: {_model.MouseTool.Width.Points()} pt");
        _undoButton.IsEnabled = _model.CanUndo;
        _redoButton.IsEnabled = _model.CanRedo;
        SetIcon(_timerButton, _model.FadeDelay is { } d ? $"⏱{d:0}s" : "⏱∞",
                _model.FadeDelay is { } s ? $"Strokes fade after {s:0} s" : "Strokes stay until cleared");
        SetIcon(_boardButton, _model.BoardEnabled ? "⬛" : "⬜", _model.BoardEnabled ? "Hide whiteboard" : "Show whiteboard");
        if (!_boardSlider.IsMouseCaptureWithin) _boardSlider.Value = _model.Settings.BoardOpacity;
        _boardSlider.ToolTip = $"Whiteboard opacity {_model.Settings.BoardOpacity * 100:0}%";
        _phoneButton.Opacity = _model.PhoneName is null ? 0.45 : 1;
        _phoneButton.ToolTip = _model.PhoneName is { } name ? $"{name} is connected" : "Connect iPhone or iPad…";
    }

    // MARK: Pop-ups

    private Panel ToolsPopup()
    {
        var grid = new UniformGrid { Columns = 3 };
        foreach (var tool in ToolInfo.All)
        {
            var t = tool;
            var b = PopupButton($"{Symbol(tool)}\n{tool.DisplayName()}", $"{tool.DisplayName()} ({char.ToUpper(tool.ShortcutKey())} · {tool.GlobalShortcut()})",
                                () => _model.SelectTool(t), _model.MouseTool.Tool == tool);
            b.Width = 70; b.Height = 52;
            grid.Children.Add(b);
        }
        return grid;
    }

    private Panel ColorsPopup()
    {
        var stack = new StackPanel();
        var grid = new UniformGrid { Columns = 4 };
        for (var i = 0; i < RgbaColor.Palette.Length; i++)
        {
            var color = RgbaColor.Palette[i];
            var swatch = PopupButton("●", $"Color {i + 1} (key {i + 1} while drawing)", () => _model.SelectColor(color), _model.MouseTool.Color == color);
            swatch.FontSize = 26;
            swatch.Foreground = new SolidColorBrush(WpfDrawing.ToColor(color));
            if (color == RgbaColor.Palette[6]) swatch.Effect = new DropShadowEffect { ShadowDepth = 0, BlurRadius = 3, Opacity = 0.8 };
            grid.Children.Add(swatch);
        }
        stack.Children.Add(grid);
        var ink = new Slider { Minimum = 0.1, Maximum = 1, Value = _model.Settings.InkOpacity, Width = 140, Margin = new Thickness(4, 8, 4, 0) };
        var label = new TextBlock { Text = $"Ink opacity {_model.Settings.InkOpacity * 100:0}%", Margin = new Thickness(4, 6, 4, 0) };
        ink.ValueChanged += (_, e) => { _model.SetInkOpacity(e.NewValue); label.Text = $"Ink opacity {e.NewValue * 100:0}%"; };
        stack.Children.Add(label);
        stack.Children.Add(ink);
        return stack;
    }

    private Panel WidthsPopup()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var width in Enum.GetValues<WidthPreset>())
        {
            var w = width;
            var b = PopupButton($"{WidthSymbol(width)}\n{width.Points()} pt", $"{width.Points()} pt ([ and ] while drawing)",
                                () => _model.SelectWidth(w), _model.MouseTool.Width == width);
            b.Width = 52; b.Height = 52;
            row.Children.Add(b);
        }
        return row;
    }

    private void OpenPopup(Button anchor, Panel content)
    {
        var popup = new Popup
        {
            PlacementTarget = anchor, StaysOpen = false, AllowsTransparency = true,
            Placement = _model.Settings.ToolbarPosition switch
            {
                ToolbarPosition.Left => PlacementMode.Right, ToolbarPosition.Right => PlacementMode.Left, _ => PlacementMode.Top,
            },
            Child = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(245, 250, 250, 252)), CornerRadius = new CornerRadius(12),
                BorderBrush = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), BorderThickness = new Thickness(1),
                Padding = new Thickness(8), Margin = new Thickness(6), Child = content,
                Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Opacity = 0.25 },
            },
        };
        foreach (var b in content.Children.OfType<Button>()) b.Click += (_, _) => popup.IsOpen = false;
        if (content.Children.OfType<UniformGrid>().FirstOrDefault() is { } inner)
            foreach (var b in inner.Children.OfType<Button>()) b.Click += (_, _) => popup.IsOpen = false;
        popup.IsOpen = true;
    }

    private void OpenTimerMenu(Button anchor)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Top };
        menu.Items.Add(MenuItem("Permanent", _model.FadeDelay is null, () => _model.SetFadeDelay(null)));
        foreach (var s in AppModel.FadeChoices)
        {
            var seconds = s;
            menu.Items.Add(MenuItem($"{s:0} s", _model.FadeDelay == s, () => _model.SetFadeDelay(seconds)));
        }
        menu.IsOpen = true;
    }

    private void OpenPositionMenu()
    {
        var menu = new ContextMenu { Placement = PlacementMode.MousePoint };
        foreach (var p in Enum.GetValues<ToolbarPosition>())
        {
            var position = p;
            var title = p switch { ToolbarPosition.Bottom => "Bottom", ToolbarPosition.Left => "Left side", _ => "Right side" };
            menu.Items.Add(MenuItem(title, _model.Settings.ToolbarPosition == p, () => _model.SetToolbarPosition(position)));
        }
        menu.IsOpen = true;
    }

    // MARK: Pieces

    public static string Symbol(Tool tool) => tool switch
    {
        Tool.Pen => "✎", Tool.Highlighter => "🖍", Tool.Line => "╱", Tool.Arrow => "↗", Tool.Rectangle => "▭",
        Tool.Ellipse => "◯", Tool.Phone => "📱", Tool.Person => "🧍", Tool.Text => "T", _ => "⌫",
    };

    private static string WidthSymbol(WidthPreset w) => w switch { WidthPreset.Fine => "·", WidthPreset.Medium => "•", WidthPreset.Bold => "●", _ => "⬤" };

    private static MenuItem MenuItem(string title, bool isChecked, Action action)
    {
        var item = new MenuItem { Header = title, IsCheckable = true, IsChecked = isChecked };
        item.Click += (_, _) => action();
        return item;
    }

    private Button IconButton(string text, string tip, Action action)
    {
        var b = new Button
        {
            Content = text, ToolTip = tip, Width = 36, Height = 34, Margin = new Thickness(1), FontSize = 17,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Focusable = false, Padding = new Thickness(0),
        };
        b.Click += (_, _) => action();
        return b;
    }

    private static Button PopupButton(string text, string tip, Action action, bool selected)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = text, TextAlignment = TextAlignment.Center }, ToolTip = tip, Margin = new Thickness(2),
            Background = selected ? new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)) : Brushes.Transparent,
            BorderThickness = new Thickness(0), Focusable = false, FontSize = 15,
        };
        b.Click += (_, _) => action();
        return b;
    }

    private static void SetIcon(Button b, string text, string tip)
    {
        b.Content = text;
        b.ToolTip = tip;
        b.FontSize = text.Length > 2 ? 12 : 17;
    }

    private static TextBlock Label(string text, string tip) => new()
    {
        Text = text, ToolTip = tip, FontSize = 14, Foreground = Brushes.Gray, Margin = new Thickness(4),
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
    };

    private void Add(UIElement e) => _panel.Children.Add(e);

    private void Divider() => _panel.Children.Add(new Border
    {
        Background = new SolidColorBrush(Color.FromArgb(38, 0, 0, 0)),
        Width = Vertical ? 26 : 1, Height = Vertical ? 1 : 24, Margin = new Thickness(4),
    });
}
