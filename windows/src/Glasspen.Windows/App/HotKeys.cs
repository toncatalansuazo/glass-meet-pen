using System;
using System.Collections.Generic;
using System.Windows.Input;
using System.Windows.Interop;
using Glasspen.Core.Model;

namespace Glasspen.Windows.App;

/// <summary>
/// System-wide shortcuts with RegisterHotKey. Defaults use plain Alt (not Ctrl+Alt, which is AltGr on
/// Spanish, Italian, German and many other keyboards): Alt + the key left of 1 toggles drawing, Alt+1…0
/// pick a tool, Alt+Delete clears. Drawing and clearing can be changed in Settings.
/// </summary>
public sealed class HotKeys : IDisposable
{
    private const uint VK_DELETE = 0x2E;
    /// <summary>Scan code of the key left of 1 (` on US, º on Spanish, ^ on German, ² on French).</summary>
    private const uint ScanCodeLeftOfOne = 0x29;

    private readonly HwndSource _window;
    private readonly Dictionary<int, Action> _actions = new();
    private int _nextId = 1;

    public HotKeys()
    {
        // A message-only window receives WM_HOTKEY.
        _window = new HwndSource(new HwndSourceParameters("GlasspenHotKeys") { ParentWindow = new IntPtr(-3) });
        _window.AddHook(Hook);
    }

    /// <summary>Alt + the key left of 1, whatever virtual key it has in the current keyboard layout.</summary>
    public static HotKeyCombo DefaultDraw
    {
        get
        {
            var vk = Native.MapVirtualKey(ScanCodeLeftOfOne, Native.MAPVK_VSC_TO_VK);
            return new HotKeyCombo(vk != 0 ? vk : 0xC0 /* VK_OEM_3 */, Native.MOD_ALT);
        }
    }

    public static HotKeyCombo DefaultClear => new(VK_DELETE, Native.MOD_ALT);

    /// <summary>"Alt+`", "Alt+º", "Ctrl+Shift+F5"…</summary>
    public static string Describe(HotKeyCombo combo)
    {
        var parts = new List<string>();
        if ((combo.Modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((combo.Modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
        if ((combo.Modifiers & Native.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((combo.Modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyName(combo.Vk));
        return string.Join("+", parts);
    }

    private static string KeyName(uint vk)
    {
        if (vk is >= '0' and <= '9' or >= 'A' and <= 'Z') return ((char)vk).ToString();
        if (vk is >= 0x70 and <= 0x87) return $"F{vk - 0x6F}";
        var key = KeyInterop.KeyFromVirtualKey((int)vk);
        var named = key switch
        {
            Key.Back => "Backspace", Key.Return => "Enter", Key.Prior => "PageUp", Key.Next => "PageDown",
            Key.Delete => "Delete", Key.Insert => "Insert", Key.Home => "Home", Key.End => "End", Key.Space => "Space",
            Key.Tab => "Tab", Key.Pause => "Pause", Key.Up => "Up", Key.Down => "Down", Key.Left => "Left", Key.Right => "Right",
            _ => null,
        };
        if (named is not null) return named;
        // Punctuation keys: the character printed on the key in the current layout. The high bit marks dead keys.
        var ch = Native.MapVirtualKey(vk, Native.MAPVK_VK_TO_CHAR) & 0x7FFF;
        return ch > 32 ? char.ToLower((char)ch).ToString() : key.ToString();
    }

    public void Register(AppModel model)
    {
        UnregisterAll();
        if (model.HotKeysSuspended) return;
        model.DrawHotKeyTaken = !Add(model.DrawHotKey, model.ToggleDrawMode);
        model.ClearHotKeyTaken = !Add(model.ClearHotKey, () => model.Clear());
        if (!model.Settings.ToolHotKeysEnabled) return;
        foreach (var tool in ToolInfo.All)
        {
            var t = tool;
            // Virtual-key codes for 0-9 are their ASCII values.
            Add(new HotKeyCombo('0' + (uint)tool.ShortcutDigit(), Native.MOD_ALT), () => model.StartDrawing(t));
        }
    }

    /// <summary>False when another app already owns the combination.</summary>
    private bool Add(HotKeyCombo combo, Action action)
    {
        var id = _nextId++;
        if (!Native.RegisterHotKey(_window.Handle, id, combo.Modifiers | Native.MOD_NOREPEAT, combo.Vk)) return false;
        _actions[id] = action;
        return true;
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
