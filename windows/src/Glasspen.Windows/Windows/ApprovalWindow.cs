using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Glasspen.Core.Net;

namespace Glasspen.Windows.Windows;

/// <summary>
/// "Allow this device to connect?" with the code the phone shows. Closing the window, or waiting
/// 60 seconds, declines. <see cref="Cancel"/> closes it when the phone gives up.
/// </summary>
public sealed class ApprovalWindow : Window
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);
    private readonly TaskCompletionSource<bool> _answer = new();
    public Guid RequestId { get; }
    public Task<bool> Answer => _answer.Task;

    public ApprovalWindow(ConfirmRequest request)
    {
        RequestId = request.Id;
        Title = "Connect a device";
        Width = 380;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var stack = new StackPanel { Margin = new Thickness(24) };
        stack.Children.Add(PairingWindow.Text("Allow this device to connect?", 16, FontWeights.SemiBold));
        // The name comes from the network: shown as plain text on its own line (already cleaned and cut to 40 characters).
        stack.Children.Add(PairingWindow.Text(request.DeviceName, 18, FontWeights.Bold));
        var code = PairingWindow.Text(Handshake.DisplayCode(request.Code), 34, FontWeights.SemiBold);
        code.FontFamily = new System.Windows.Media.FontFamily("Consolas");
        code.Margin = new Thickness(0, 10, 0, 10);
        stack.Children.Add(code);
        stack.Children.Add(PairingWindow.Text("Click Allow only if your iPhone or iPad shows this same code. It will be able to see this screen and draw on it.", 12, color: System.Windows.Media.Brushes.Gray));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 16, 0, 0) };
        var deny = new Button { Content = "Deny", Width = 90, Margin = new Thickness(6), IsCancel = true };
        var allow = new Button { Content = "Allow", Width = 90, Margin = new Thickness(6) };
        deny.Click += (_, _) => Finish(false);
        allow.Click += (_, _) => Finish(true);
        buttons.Children.Add(deny);
        buttons.Children.Add(allow);
        stack.Children.Add(buttons);
        Content = stack;
        Closed += (_, _) => _answer.TrySetResult(false);
        var timer = new DispatcherTimer { Interval = Timeout };
        timer.Tick += (_, _) => { timer.Stop(); Finish(false); };
        timer.Start();
    }

    private void Finish(bool allowed)
    {
        _answer.TrySetResult(allowed);
        Close();
    }

    /// <summary>The device gave up (cancelled or disconnected).</summary>
    public void Cancel() => Finish(false);
}
