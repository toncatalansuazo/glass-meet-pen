using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Glasspen.Windows.Remote;
using QRCoder;

namespace Glasspen.Windows.Windows;

/// <summary>"Connect iPhone or iPad": the QR code, the confirm-pairing hint and the manual address.</summary>
public sealed class PairingWindow : Window
{
    private readonly RemoteServer _server;
    private readonly StackPanel _stack = new() { Margin = new Thickness(24) };

    public PairingWindow(RemoteServer server)
    {
        _server = server;
        Title = "Connect iPhone or iPad";
        Width = 400;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = _stack;
        Refresh();
        void OnChanged() => Dispatcher.InvokeAsync(Refresh);
        server.Changed += OnChanged;
        Closed += (_, _) => server.Changed -= OnChanged;
    }

    private void Refresh()
    {
        _stack.Children.Clear();
        if (_server.ConnectedName is { } name)
            _stack.Children.Add(Text($"✔ {name} is connected", 16, FontWeights.SemiBold, Brushes.Green));
        else
            _stack.Children.Add(Text("Open Glasspen Remote on your iPhone or iPad and scan this code", 14));
        _stack.Children.Add(new Border
        {
            Background = Brushes.White, Padding = new Thickness(10), Margin = new Thickness(0, 14, 0, 14),
            HorizontalAlignment = HorizontalAlignment.Center, CornerRadius = new CornerRadius(12),
            Child = new Image { Source = QrImage(_server.PairingUrl), Width = 220, Height = 220 },
        });
        _stack.Children.Add(Text($"Or tap “{_server.ServiceName}” in the app, then click Allow here when both screens show the same code.", 12, color: Brushes.Gray));
        if (_server.ListenerError is { } error)
            _stack.Children.Add(Text($"Network error: {error}", 12, color: Brushes.Red));
        else if (_server.LanAddress is { } ip)
            _stack.Children.Add(Text($"Manual address: {ip}:{_server.Port}", 12, color: Brushes.Gray));
        var reset = new Button { Content = "Reset Pairing", Margin = new Thickness(0, 14, 0, 0), Padding = new Thickness(12, 4, 12, 4),
                                 HorizontalAlignment = HorizontalAlignment.Center, ToolTip = "Creates a new QR code and disconnects every paired device" };
        reset.Click += (_, _) => _server.ResetPairing();
        _stack.Children.Add(reset);
    }

    private static ImageSource QrImage(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        var image = new BitmapImage();
        image.BeginInit();
        image.StreamSource = new MemoryStream(png);
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    internal static TextBlock Text(string text, double size, FontWeight? weight = null, Brush? color = null) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = color ?? Brushes.Black,
        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 2, 0, 2),
    };
}
