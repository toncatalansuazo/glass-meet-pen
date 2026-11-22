using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Glasspen.Core.Model;
using Glasspen.Windows.App;

namespace Glasspen.Windows.Windows;

public sealed class SettingsWindow : Window
{
    private readonly AppModel _model;
    private Action? _stopRecording;

    public SettingsWindow(AppModel model)
    {
        _model = model;
        Title = "Glasspen Meet Settings";
        Width = 460;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var stack = new StackPanel { Margin = new Thickness(20) };

        stack.Children.Add(Header("Toolbar"));
        var opacityLabel = new TextBlock { Text = $"Background opacity: {model.Settings.ToolbarOpacity * 100:0}%" };
        var opacity = new Slider { Minimum = 0, Maximum = 1, Value = model.Settings.ToolbarOpacity, Margin = new Thickness(0, 4, 0, 8) };
        opacity.ValueChanged += (_, e) => { model.SetToolbarOpacity(e.NewValue); opacityLabel.Text = $"Background opacity: {e.NewValue * 100:0}%"; };
        stack.Children.Add(opacityLabel);
        stack.Children.Add(opacity);
        var position = new ComboBox { ItemsSource = Enum.GetValues<ToolbarPosition>(), SelectedItem = model.Settings.ToolbarPosition, Margin = new Thickness(0, 0, 0, 8) };
        position.SelectionChanged += (_, _) => { if (position.SelectedItem is ToolbarPosition p) model.SetToolbarPosition(p); };
        stack.Children.Add(new TextBlock { Text = "Position" });
        stack.Children.Add(position);

        stack.Children.Add(Header("Shortcuts"));
        stack.Children.Add(ShortcutRow("Start or stop drawing", () => model.DrawHotKey, () => model.DrawHotKeyTaken, model.SetDrawHotKey));
        stack.Children.Add(ShortcutRow("Clear all", () => model.ClearHotKey, () => model.ClearHotKeyTaken, model.SetClearHotKey));
        stack.Children.Add(new TextBlock
        {
            Text = "Click a shortcut, then press the new keys (Esc cancels). Avoid Ctrl+Alt: it's AltGr on many keyboards.",
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, FontSize = 11, Margin = new Thickness(0, 0, 0, 8),
        });
        var tools = new CheckBox { Content = "Alt+1 … 0 pick a tool from any app", IsChecked = model.Settings.ToolHotKeysEnabled };
        tools.Checked += (_, _) => model.SetToolHotKeys(true);
        tools.Unchecked += (_, _) => model.SetToolHotKeys(false);
        stack.Children.Add(tools);
        stack.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", ToolInfo.All.Select(t => $"{t.ShortcutDigit()} {t.DisplayName()}")) +
                   $"\nWhile drawing: Ctrl+Z undo · Ctrl+Shift+Z redo · {string.Join(" ", ToolInfo.All.Select(t => char.ToUpper(t.ShortcutKey())))} tools · 1–8 colors · [ ] width · Delete clear · Esc stop · Shift constrains shapes",
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, FontSize = 11, Margin = new Thickness(0, 4, 0, 0),
        });

        stack.Children.Add(Header("Support"));
        var coffee = new Button { Content = "☕ Buy me a coffee", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 3, 10, 3) };
        coffee.Click += (_, _) => OpenUrl(AppSettings.BuyMeACoffeeUrl);
        stack.Children.Add(coffee);
        Content = stack;

        Deactivated += (_, _) => _stopRecording?.Invoke();
        Closed += (_, _) => _stopRecording?.Invoke();
    }

    /// <summary>Label, a button that records a new combination, "Default", and a warning when another app owns it.</summary>
    private UIElement ShortcutRow(string title, Func<HotKeyCombo> current, Func<bool> taken, Action<HotKeyCombo?> set)
    {
        var column = new StackPanel { Margin = new Thickness(0, 0, 0, 6) };
        var row = new DockPanel();
        var label = new TextBlock { Text = title, Width = 170, VerticalAlignment = VerticalAlignment.Center };
        var record = new Button { MinWidth = 150, Padding = new Thickness(8, 3, 8, 3) };
        var reset = new Button { Content = "Default", Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(6, 0, 0, 0), Focusable = false };
        var warning = new TextBlock
        {
            Foreground = Brushes.Firebrick, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(170, 2, 0, 0),
            Text = "Another app already uses this shortcut. Pick a different one.",
        };
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(reset, Dock.Right);
        row.Children.Add(label);
        row.Children.Add(reset);
        row.Children.Add(record);
        column.Children.Add(row);
        column.Children.Add(warning);

        void Show()
        {
            record.Content = HotKeys.Describe(current());
            warning.Visibility = taken() ? Visibility.Visible : Visibility.Collapsed;
        }

        KeyEventHandler? onKey = null;
        void Stop()
        {
            if (onKey is not null) PreviewKeyDown -= onKey;
            onKey = null;
            _stopRecording = null;
            _model.SuspendHotKeys(false);
            Show();
        }

        record.Click += (_, _) =>
        {
            if (onKey is not null) { Stop(); return; }
            _stopRecording?.Invoke(); // only one recorder at a time
            _model.SuspendHotKeys(true);
            record.Content = "Press the new keys…";
            record.Focus(); // keys reach the window through the focused element
            onKey = (_, e) =>
            {
                var key = e.Key switch { Key.System => e.SystemKey, Key.ImeProcessed => e.ImeProcessedKey, _ => e.Key };
                if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
                        or Key.LWin or Key.RWin or Key.None) return; // wait for the actual key
                e.Handled = true;
                var mods = Keyboard.Modifiers;
                if (key == Key.Escape && mods == ModifierKeys.None) { Stop(); return; }
                var isFunctionKey = key is >= Key.F1 and <= Key.F24;
                var hasModifier = (mods & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0;
                if (!hasModifier && !isFunctionKey)
                {
                    record.Content = "Add Alt, Ctrl or Win…";
                    return;
                }
                uint bits = 0;
                if (mods.HasFlag(ModifierKeys.Control)) bits |= Native.MOD_CONTROL;
                if (mods.HasFlag(ModifierKeys.Alt)) bits |= Native.MOD_ALT;
                if (mods.HasFlag(ModifierKeys.Shift)) bits |= Native.MOD_SHIFT;
                if (mods.HasFlag(ModifierKeys.Windows)) bits |= Native.MOD_WIN;
                var combo = new HotKeyCombo((uint)KeyInterop.VirtualKeyFromKey(key), bits);
                PreviewKeyDown -= onKey;
                onKey = null;
                _stopRecording = null;
                _model.SuspendHotKeys(false);
                set(combo); // registers it, which tells whether another app owns it
                Show();
            };
            PreviewKeyDown += onKey;
            _stopRecording = Stop;
        };
        reset.Click += (_, _) => { _stopRecording?.Invoke(); set(null); Show(); };
        Show();
        return column;
    }

    private static TextBlock Header(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, FontSize = 14, Margin = new Thickness(0, 12, 0, 6) };

    public static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}
