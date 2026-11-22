using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Glasspen.Core.Model;
using Glasspen.Windows.App;

namespace Glasspen.Windows.Windows;

public sealed class SettingsWindow : Window
{
    public SettingsWindow(AppModel model)
    {
        Title = "Glasspen Meet Settings";
        Width = 460;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var stack = new StackPanel { Margin = new Thickness(20) };

        stack.Children.Add(Header("Toolbar"));
        var opacityLabel = new TextBlock { Text = $"Background: {model.Settings.ToolbarOpacity * 100:0}%" };
        var opacity = new Slider { Minimum = 0, Maximum = 1, Value = model.Settings.ToolbarOpacity, Margin = new Thickness(0, 4, 0, 8) };
        opacity.ValueChanged += (_, e) => { model.SetToolbarOpacity(e.NewValue); opacityLabel.Text = $"Background: {e.NewValue * 100:0}%"; };
        stack.Children.Add(opacityLabel);
        stack.Children.Add(opacity);
        var position = new ComboBox { ItemsSource = Enum.GetValues<ToolbarPosition>(), SelectedItem = model.Settings.ToolbarPosition, Margin = new Thickness(0, 0, 0, 8) };
        position.SelectionChanged += (_, _) => { if (position.SelectedItem is ToolbarPosition p) model.SetToolbarPosition(p); };
        stack.Children.Add(new TextBlock { Text = "Position" });
        stack.Children.Add(position);

        stack.Children.Add(Header("Shortcuts"));
        stack.Children.Add(new TextBlock { Text = $"{HotKeys.DrawShortcut}  start or stop drawing\n{HotKeys.ClearShortcut}  clear all", Margin = new Thickness(0, 0, 0, 6) });
        var tools = new CheckBox { Content = "Ctrl+Alt+Shift+1 … 0 pick a tool from any app", IsChecked = model.Settings.ToolHotKeysEnabled };
        tools.Checked += (_, _) => model.SetToolHotKeys(true);
        tools.Unchecked += (_, _) => model.SetToolHotKeys(false);
        stack.Children.Add(tools);
        stack.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", ToolInfo.All.Select(t => $"{t.ShortcutDigit()} {t.DisplayName()}")) +
                   $"\nWhile drawing: Ctrl+Z undo · Ctrl+Shift+Z redo · {string.Join(" ", ToolInfo.All.Select(t => char.ToUpper(t.ShortcutKey())))} tools · 1–8 colors · [ ] width · Esc stop · Shift constrains shapes",
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, FontSize = 11, Margin = new Thickness(0, 4, 0, 0),
        });

        stack.Children.Add(Header("Support"));
        var coffee = new Button { Content = "☕ Buy me a coffee", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 3, 10, 3) };
        coffee.Click += (_, _) => OpenUrl(AppSettings.BuyMeACoffeeUrl);
        stack.Children.Add(coffee);
        Content = stack;
    }

    private static TextBlock Header(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, FontSize = 14, Margin = new Thickness(0, 12, 0, 6) };

    public static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}
