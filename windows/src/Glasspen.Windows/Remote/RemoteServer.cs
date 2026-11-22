using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Glasspen.Core.Model;
using Glasspen.Core.Net;
using Glasspen.Core.Protocol;
using Glasspen.Windows.App;
using Makaretu.Dns;

namespace Glasspen.Windows.Remote;

/// <summary>
/// Listener for the Glasspen Remote phone app (port of the Mac app's RemoteServer). One phone at a time;
/// each phone opens a control channel and a video channel. Network work runs on the thread pool; all
/// session state is changed on the UI thread.
/// </summary>
public sealed class RemoteServer : IDisposable
{
    private readonly AppModel _model;
    private readonly Dispatcher _ui;
    private readonly FailureLimiter _limiter = new();
    private readonly CancellationTokenSource _stop = new();
    private TcpListener? _listener;
    private ServiceDiscovery? _bonjour;
    private ServiceProfile? _profile;
    private int _pending;
    private Session? _session;
    private readonly Dictionary<SourceId, ToolState> _lastToolStates = new();
    /// <summary>Connections still in the pairing handshake (any thread), closed by Reset Pairing.</summary>
    private readonly ConcurrentDictionary<TcpClient, byte> _connecting = new();
    /// <summary>Paired channels that haven't said hello yet (UI thread).</summary>
    private readonly HashSet<SecureChannel> _handshaking = new();
    private Guid? _approvalOpen;
    private uint _detailRequestId;

    private const int FrameMaxPixels = 1600;
    private const long FrameQuality = 70, CloseUpQuality = 85;
    private static readonly TimeSpan FrameInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan CloseUpFirst = TimeSpan.FromMilliseconds(150), CloseUpInterval = TimeSpan.FromMilliseconds(500);

    /// <summary>At most this many connections may be mid-handshake at once.</summary>
    private const int MaxPending = 16;

    public PairingSecret Secret { get; private set; } = PairingSecret.Generate();
    public ushort Port { get; private set; }
    public string ServiceName { get; } = Environment.MachineName;
    public string? LanAddress { get; private set; } = CurrentLanAddress();
    public string? ListenerError { get; private set; }
    public string? ConnectedName => _session?.DeviceName;
    public string PairingUrl => Secret.PairingUrl(ServiceName, LanAddress, Port);

    public event Action? Changed;
    /// <summary>Shows the Allow prompt; completes with the user's answer.</summary>
    public Func<ConfirmRequest, Task<bool>>? ApprovalRequested { get; set; }
    /// <summary>Closes the prompt for a request whose connection went away.</summary>
    public Action<Guid>? ApprovalCancelled { get; set; }

    private sealed class Session
    {
        public required SecureChannel Control { get; init; }
        public SecureChannel? Video { get; set; }
        public required PhoneLink Link { get; init; }
        public SourceId SourceId => Link.Source;
        public required string DeviceName { get; init; }
        /// <summary>The whole-screen frame loop.</summary>
        public CancellationTokenSource? Frames { get; set; }
        /// <summary>The close-up loop for the area the phone is zoomed into.</summary>
        public CancellationTokenSource? CloseUp { get; set; }

        public void StopStreams()
        {
            Frames?.Cancel();
            CloseUp?.Cancel();
        }
    }

    public RemoteServer(AppModel model, Dispatcher ui)
    {
        _model = model;
        _ui = ui;
        model.DocumentChanged += Broadcast;
        model.ToolChanged += (source, state) => Send(new ServerMessage.ToolChanged(source, state));
        model.DrawModeChanged += on => Send(new ServerMessage.DrawModeChanged(on));
        model.DisplayChanged += display => Send(new ServerMessage.DisplayChanged(display));
    }

    // MARK: Listener

    public void Start()
    {
        try
        {
            _listener = Listen(ProtocolInfo.DefaultPort) ?? Listen(0);
            if (_listener is null) { ListenerError = "Could not open a network port."; Changed?.Invoke(); return; }
            Port = (ushort)((IPEndPoint)_listener.LocalEndpoint).Port;
            Advertise();
            _ = Task.Run(AcceptLoop);
        }
        catch (Exception e) when (e is SocketException or InvalidOperationException)
        {
            ListenerError = e.Message;
        }
        Changed?.Invoke();
    }

    private static TcpListener? Listen(int port)
    {
        try
        {
            var l = new TcpListener(IPAddress.Any, port);
            l.Start();
            return l;
        }
        catch (SocketException)
        {
            return null; // default port busy: let the system pick one
        }
    }

    /// <summary>Announces "_paintscreen._tcp" with Bonjour (mDNS), as the Mac does, so the phone finds this PC.</summary>
    private void Advertise()
    {
        try
        {
            _bonjour = new ServiceDiscovery();
            _profile = new ServiceProfile(ServiceName, ProtocolInfo.BonjourType, Port);
            _bonjour.Advertise(_profile);
        }
        catch (Exception)
        {
            // Without Bonjour the phone can still connect with the QR code (it holds the address).
            _bonjour = null;
        }
    }

    private async Task AcceptLoop()
    {
        while (!_stop.IsCancellationRequested && _listener is { } listener)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(_stop.Token); }
            catch (Exception) { return; }
            if (Interlocked.Increment(ref _pending) > MaxPending)
            {
                Interlocked.Decrement(ref _pending);
                client.Dispose();
                continue;
            }
            _ = Task.Run(() => HandleConnection(client));
        }
    }

    private async Task HandleConnection(TcpClient client)
    {
        if (await PairAsync(client) is not { } channel) return;
        try
        {
            await ReadMessagesAsync(channel);
        }
        catch (Exception)
        {
            // Closed or broken connection.
        }
        finally
        {
            await _ui.InvokeAsync(() => ChannelClosed(channel));
            await channel.DisposeAsync();
        }
    }

    /// <summary>
    /// Runs the pairing handshake. Null when it fails, or when Reset Pairing happened meanwhile: a
    /// handshake that started with the old token must not end up connected.
    /// </summary>
    private async Task<SecureChannel?> PairAsync(TcpClient client)
    {
        var token = Secret.Token;
        _connecting[client] = 0;
        SecureChannel channel;
        try
        {
            var auth = new ServerAuth
            {
                Token = token, Limiter = _limiter, Approve = RequestApproval,
                CancelApproval = id => _ui.InvokeAsync(() => { if (_approvalOpen == id) { _approvalOpen = null; ApprovalCancelled?.Invoke(id); } }),
            };
            channel = await SecureChannel.AcceptAsync(client, auth, _stop.Token);
        }
        catch (Exception)
        {
            return null; // failed handshakes are counted by the limiter
        }
        finally
        {
            _connecting.TryRemove(client, out _);
            Interlocked.Decrement(ref _pending);
        }
        var current = await _ui.InvokeAsync(() =>
        {
            if (token != Secret.Token) return false;
            _handshaking.Add(channel);
            return true;
        });
        if (current) return channel;
        await channel.DisposeAsync();
        return null;
    }

    private async Task ReadMessagesAsync(SecureChannel channel)
    {
        while (!_stop.IsCancellationRequested)
        {
            var (kind, body) = await channel.ReceiveAsync(_stop.Token);
            if (kind != FrameKind.Message) continue;
            ClientMessage message;
            try { message = MessageCodec.DecodeClient(body); }
            catch (Exception e) when (e is FormatException or KeyNotFoundException or InvalidCastException) { continue; }
            await _ui.InvokeAsync(() => Handle(message, channel));
        }
    }

    /// <summary>One prompt at a time: a request while one is open is declined.</summary>
    private Task<bool> RequestApproval(ConfirmRequest request) =>
        _ui.InvokeAsync(() =>
        {
            if (_approvalOpen is not null || ApprovalRequested is null) return Task.FromResult(false);
            _approvalOpen = request.Id;
            return ApprovalRequested(request).ContinueWith(t =>
            {
                _ui.InvokeAsync(() => { if (_approvalOpen == request.Id) _approvalOpen = null; });
                return t.IsCompletedSuccessfully && t.Result;
            });
        }).Task.Unwrap();

    // MARK: Messages (UI thread)

    private void Handle(ClientMessage message, SecureChannel channel)
    {
        if (message is ClientMessage.Hello hello)
        {
            _handshaking.Remove(channel);
            if (hello.Version != ProtocolInfo.Version) { _ = channel.DisposeAsync(); return; }
            if (hello.Role == ChannelRole.Control) AttachControl(channel, hello);
            else AttachVideo(channel, hello.SourceId);
            return;
        }
        if (_session is not { } session || session.Control != channel) return;
        if (message is ClientMessage.SetTool t) _lastToolStates[session.SourceId] = t.State; // restored when it reconnects
        if (session.Link.Apply(message)) return;
        switch (message)
        {
            case ClientMessage.Viewport v: StartCloseUps(session, v); break;
            case ClientMessage.RequestKeyframe: SendFrameNow(session); break;
            case ClientMessage.Ping p: Send(new ServerMessage.Pong(p.SentAt)); break;
        }
    }

    private void AttachControl(SecureChannel channel, ClientMessage.Hello hello)
    {
        if (_session is { } old)
        {
            // One phone at a time: the newly paired device takes over.
            _ = Notify(old.Control, new ServerMessage.SessionEnded("Another device connected"));
            EndSession(old);
        }
        var tool = _lastToolStates.GetValueOrDefault(hello.SourceId, new ToolState(Tool.Pen, RgbaColor.Palette[4], WidthPreset.Medium));
        _session = new Session { Control = channel, Link = new PhoneLink(_model, hello.SourceId), DeviceName = Handshake.DisplayName(hello.DeviceName) };
        _model.PhoneConnected(_session.DeviceName);
        _model.SetPhoneTool(tool, hello.SourceId);
        var welcome = new Welcome(ServiceName, _model.Display, _model.Document.OrderedStrokes, tool, _model.DrawMode, ScreenPermission: true);
        Send(new ServerMessage.WelcomeMessage(welcome));
        if (channel.AuthMode == AuthMode.Confirm) Send(new ServerMessage.PairingToken(Secret.Token));
        Changed?.Invoke();
    }

    private void AttachVideo(SecureChannel channel, SourceId sourceId)
    {
        if (_session is not { } s || s.SourceId != sourceId) { _ = channel.DisposeAsync(); return; }
        s.StopStreams();
        if (s.Video is { } oldVideo) _ = oldVideo.DisposeAsync();
        s.Video = channel;
        var frames = s.Frames = new CancellationTokenSource();
        _ = Task.Run(() => StreamFrames(channel, frames.Token));
    }

    private void ChannelClosed(SecureChannel channel)
    {
        _handshaking.Remove(channel);
        if (_session is not { } s) return;
        if (s.Control == channel)
        {
            EndSession(s);
            _session = null;
            _model.PhoneConnected(null);
            Changed?.Invoke();
        }
        else if (s.Video == channel)
        {
            s.StopStreams();
            s.Video = null;
        }
    }

    /// <summary>Stops the session's streams, drops its live stroke and closes its channels.</summary>
    private static void EndSession(Session s)
    {
        s.StopStreams();
        s.Link.Disconnected();
        _ = Task.Run(async () =>
        {
            await Task.Delay(200); // let a goodbye message go out first
            await s.Control.DisposeAsync();
            if (s.Video is { } v) await v.DisposeAsync();
        });
    }

    // MARK: Outgoing

    private void Send(ServerMessage message)
    {
        if (_session is { } s) _ = Notify(s.Control, message);
    }

    private static async Task Notify(SecureChannel channel, ServerMessage message)
    {
        try { await channel.SendAsync(message); }
        catch (Exception) { /* the read loop notices the closed connection */ }
    }

    private void Broadcast(DocumentEvent e)
    {
        if (_session?.Link.Outgoing(e) is { } message) Send(message);
    }

    // MARK: Screen for the phone

    /// <summary>
    /// Whole-screen JPEG stills about 4 times a second, as Detail frames with request ID 0 (docs/protocol.md §8).
    /// A frame is skipped while the previous one is still being sent, or when the screen hasn't changed.
    /// </summary>
    private static async Task StreamFrames(SecureChannel video, CancellationToken ct)
    {
        byte[]? last = null;
        while (!ct.IsCancellationRequested)
        {
            if (video.PendingSends == 0)
            {
                var (open, sent) = await SendStillAsync(video, NormRect.Full, FrameMaxPixels, FrameMaxPixels, FrameQuality, DetailPacket.FullFrameId, last, ct);
                if (!open) return;
                last = sent;
            }
            try { await Task.Delay(FrameInterval, ct); } catch (OperationCanceledException) { return; }
        }
    }

    private static void SendFrameNow(Session s)
    {
        if (s.Video is not { } video) return;
        _ = Task.Run(() => SendStillAsync(video, NormRect.Full, FrameMaxPixels, FrameMaxPixels, FrameQuality, DetailPacket.FullFrameId, null, default));
    }

    /// <summary>
    /// A sharp still of the area the phone is zoomed into, refreshed about twice a second (only when it
    /// changed) until the phone zooms elsewhere. The rect is untrusted: it is clamped to the shared display.
    /// </summary>
    private void StartCloseUps(Session s, ClientMessage.Viewport v)
    {
        s.CloseUp?.Cancel();
        s.CloseUp = null;
        if (v.Rect?.ClampedToDisplay() is not { } rect || s.Video is not { } video) return;
        var id = ++_detailRequestId;
        if (id == DetailPacket.FullFrameId) id = ++_detailRequestId; // 0 means a whole-screen frame
        var work = s.CloseUp = new CancellationTokenSource();
        int w = Math.Clamp(v.PixelWidth, 1, 2048), h = Math.Clamp(v.PixelHeight, 1, 2048);
        _ = Task.Run(async () =>
        {
            byte[]? last = null;
            var wait = CloseUpFirst;
            while (true)
            {
                try { await Task.Delay(wait, work.Token); } catch (OperationCanceledException) { return; }
                wait = CloseUpInterval;
                if (video.PendingSends > 0) continue;
                var (open, sent) = await SendStillAsync(video, rect, w, h, CloseUpQuality, id, last, work.Token);
                if (!open) return;
                last = sent;
            }
        });
    }

    /// <summary>
    /// Captures <paramref name="rect"/> and sends it as a Detail frame, unless it is the same image as
    /// <paramref name="previous"/>. A failed capture (locked screen, display change) skips this still.
    /// Returns whether the channel is still open, and the last image sent.
    /// </summary>
    private static async Task<(bool Open, byte[]? Sent)> SendStillAsync(SecureChannel video, NormRect rect, int maxWidth, int maxHeight,
                                                                       long quality, uint id, byte[]? previous, CancellationToken ct)
    {
        byte[]? jpeg;
        try { jpeg = ScreenCapture.Capture(rect, maxWidth, maxHeight, quality); }
        catch (Exception e) when (e is not OutOfMemoryException) { jpeg = null; }
        if (jpeg is null || (previous is not null && jpeg.AsSpan().SequenceEqual(previous))) return (true, previous);
        try
        {
            await video.SendAsync(FrameKind.Detail, new DetailPacket(rect, id, jpeg).Encode(), ct);
            return (true, jpeg);
        }
        catch (Exception)
        {
            return (false, previous); // closed or cancelled
        }
    }

    // MARK: Pairing

    /// <summary>New token: disconnects every paired device.</summary>
    public void ResetPairing()
    {
        Secret = PairingSecret.Generate();
        if (_session is { } s)
        {
            _ = Notify(s.Control, new ServerMessage.SessionEnded("Pairing was reset on the computer"));
            EndSession(s);
        }
        // Handshakes still running with the old token: close them (PairAsync also re-checks the token).
        foreach (var client in _connecting.Keys) client.Dispose();
        foreach (var c in _handshaking.ToList()) _ = c.DisposeAsync();
        Changed?.Invoke();
    }

    /// <summary>Tells the phone the app is closing.</summary>
    public async Task ShutdownAsync()
    {
        if (_session is { } s)
        {
            await Task.WhenAny(Notify(s.Control, new ServerMessage.SessionEnded("Glasspen Meet was closed on the computer")), Task.Delay(500));
        }
        Dispose();
    }

    public static string? CurrentLanAddress()
    {
        // Prefer Wi-Fi/Ethernet with a gateway over VPN and virtual adapters.
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Count > 0)
            .ThenByDescending(n => n.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))?.ToString();
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener?.Stop();
        if (_bonjour is not null && _profile is not null) _bonjour.Unadvertise(_profile);
        _bonjour?.Dispose();
    }
}
