using System;
using System.Collections.Generic;
using System.Windows.Interop;
using Glasspen.Core.Model;

namespace Glasspen.Windows.App;

/// <summary>
/// System-wide shortcuts with RegisterHotKey. All use Ctrl+Alt+Shift: Ctrl+Alt alone is AltGr, which
/// types @, #, [ … on Spanish, Italian, German and many other keyboards.
/// </summary>
public sealed class HotKeys : IDisposable
{
    private const uint Modifiers = Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_SHIFT | Native.MOD_NOREPEAT;
    private readonly HwndSource _window;
    private readonly Dictionary<int, Action> _actions = new();
    private int _nextId = 1;

    public HotKeys()
    {
        // A message-only window receives WM_HOTKEY.
        _window = new HwndSource(new HwndSourceParameters("GlasspenHotKeys") { ParentWindow = new IntPtr(-3) });
        _window.AddHook(Hook);
    }

    public const string DrawShortcut = "Ctrl+Alt+Shift+D";
    public const string ClearShortcut = "Ctrl+Alt+Shift+K";

    public void Register(AppModel model)
    {
        UnregisterAll();
        Add('D', model.ToggleDrawMode);
        Add('K', () => model.Clear());
        if (!model.Settings.ToolHotKeysEnabled) return;
        foreach (var tool in ToolInfo.All)
        {
            var t = tool;
            Add((char)('0' + tool.ShortcutDigit()), () => model.StartDrawing(t));
        }
    }

    private void Add(char key, Action action)
    {
        var id = _nextId++;
        // Virtual-key codes for 0-9 and A-Z are their ASCII values. A key another app already owns is skipped.
        if (Native.RegisterHotKey(_window.Handle, id, Modifiers, key)) _actions[id] = action;
    }

    private void UnregisterAll()
    {
        foreach (var id in _actions.Keys) Native.UnregisterHotKey(_window.Handle, id);
        _actions.Clear();
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && _actions.TryGetValue(wParam.ToInt32(), out var action))
        {
            action();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        UnregisterAll();
        _window.Dispose();
    }
}
