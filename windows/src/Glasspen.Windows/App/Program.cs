using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Glasspen.Core.Net;
using Glasspen.Windows.Overlay;
using Glasspen.Windows.Remote;
using Glasspen.Windows.Toolbar;
using Glasspen.Windows.Windows;
using Forms = System.Windows.Forms;

namespace Glasspen.Windows.App;

/// <summary>Starts Glasspen Meet: overlay, toolbar, tray icon, global shortcuts and the phone server.</summary>
public static class Program
{
    [STAThread]
    public static void Main()
    {
        using var single = new Mutex(true, "GlasspenMeet.SingleInstance", out var first);
        if (!first) return; // already running: its tray icon is there

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var model = new AppModel(AppSettings.Load());
        var server = new RemoteServer(model, app.Dispatcher);
        var overlay = new OverlayWindow(model);
        var pairing = new SingleWindow<PairingWindow>(() => new PairingWindow(server));
        var settings = new SingleWindow<SettingsWindow>(() => new SettingsWindow(model));
        ShowApprovalsFor(server);

        var toolbar = new ToolbarWindow(model, pairing.Show, settings.Show);
        using var hotKeys = new HotKeys();
        hotKeys.Register(model);
        model.HotKeysChanged += () => hotKeys.Register(model);

        using var tray = new TrayIcon(model, pairing.Show, settings.Show, () => Quit(app, server));
        overlay.Show();
        toolbar.Show();
        server.Start();
        app.Run();
    }

    /// <summary>One Allow window per pairing request; closed when the phone goes away first.</summary>
    private static void ShowApprovalsFor(RemoteServer server)
    {
        var approvals = new Dictionary<Guid, ApprovalWindow>();
        server.ApprovalRequested = request =>
        {
            var window = new ApprovalWindow(request);
            approvals[request.Id] = window;
            window.Closed += (_, _) => approvals.Remove(request.Id);
            window.Show();
            window.Activate();
            return window.Answer;
        };
        server.ApprovalCancelled = id => { if (approvals.TryGetValue(id, out var w)) w.Cancel(); };
    }

    private static void Quit(Application app, RemoteServer server)
    {
        _ = server.ShutdownAsync().ContinueWith(_ => app.Dispatcher.InvokeAsync(app.Shutdown), TaskScheduler.Default);
    }
}

/// <summary>A window shown at most once: Show brings the open one to the front, or creates a new one.</summary>
public sealed class SingleWindow<T>(Func<T> create) where T : Window
{
    private T? _window;

    public void Show()
    {
        if (_window is null)
        {
            _window = create();
            _window.Closed += (_, _) => _window = null;
        }
        _window.Show();
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        // Opened from the toolbar, which never takes focus, Windows may refuse to bring the window forward
        // and leave it behind the app being presented. Being topmost for a moment puts it in front.
        _window.Topmost = true;
        _window.Activate();
        _window.Topmost = false;
    }
}

/// <summary>The icon next to the clock, with the app's menu (Windows has no menu bar).</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;

    public TrayIcon(AppModel model, Action showPairing, Action showSettings, Action quit)
    {
        var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/glasspen.ico"))!.Stream;
        _icon = new Forms.NotifyIcon { Icon = new System.Drawing.Icon(stream), Text = "Glasspen Meet", Visible = true };
        var menu = new Forms.ContextMenuStrip();
        var draw = new Forms.ToolStripMenuItem("Start Drawing", null, (_, _) => model.ToggleDrawMode());
        var toolbar = new Forms.ToolStripMenuItem("Hide Toolbar", null, (_, _) => model.SetToolbarVisible(!model.ToolbarVisible));
        menu.Items.Add(draw);
        menu.Items.Add(toolbar);
        menu.Items.Add(new Forms.ToolStripMenuItem("Clear All", null, (_, _) => model.Clear()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("Connect iPhone/iPad…", null, (_, _) => showPairing()));
        menu.Items.Add(new Forms.ToolStripMenuItem("Settings…", null, (_, _) => showSettings()));
        menu.Items.Add(new Forms.ToolStripMenuItem("☕ Buy Me a Coffee…", null, (_, _) => SettingsWindow.OpenUrl(AppSettings.BuyMeACoffeeUrl)));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("Quit Glasspen Meet", null, (_, _) => quit()));
        menu.Opening += (_, _) =>
        {
            draw.Text = model.DrawMode ? $"Stop Drawing ({model.DrawShortcut})" : $"Start Drawing ({model.DrawShortcut})";
            toolbar.Text = model.ToolbarVisible ? "Hide Toolbar" : "Show Toolbar";
        };
        _icon.ContextMenuStrip = menu;
        _icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) model.SetToolbarVisible(true); };
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
