using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Glasspen.Core.Protocol;

namespace Glasspen.Core.Net;

public enum ChannelErrorKind { AuthFailed, Denied, Locked, Protocol, Closed }

public sealed class ChannelException(ChannelErrorKind kind, string detail = "") : Exception(Describe(kind, detail))
{
    public ChannelErrorKind Kind { get; } = kind;

    private static string Describe(ChannelErrorKind kind, string detail) => kind switch
    {
        ChannelErrorKind.AuthFailed => "This pairing has expired. Pair again from your computer.",
        ChannelErrorKind.Denied => "The pairing was declined on the computer.",
        ChannelErrorKind.Locked => "Too many attempts. Try again in 30 seconds",
        ChannelErrorKind.Protocol => $"Protocol error: {detail}",
        _ => "Connection closed",
    };
}

/// <summary>A pairing the user has to allow on the computer.</summary>
public sealed record ConfirmRequest(Guid Id, string DeviceName, string Code, string Host);

/// <summary>How the server checks clients.</summary>
public sealed class ServerAuth
{
    /// <summary>The pairing token when the connection arrived.</summary>
    public required string Token { get; init; }
    /// <summary>Shows the Allow prompt; completes with the user's answer.</summary>
    public required Func<ConfirmRequest, Task<bool>> Approve { get; init; }
    /// <summary>The connection behind a request closed before the user answered: close the prompt.</summary>
    public Action<Guid> CancelApproval { get; init; } = _ => { };
    public required FailureLimiter Limiter { get; init; }
}

// Handshake messages (JSON, docs/protocol.md §5). Unset fields are left out.
internal sealed record ClientHello(
    [property: JsonPropertyName("v")] int V, [property: JsonPropertyName("mode")] string Mode,
    [property: JsonPropertyName("nonce")] byte[] Nonce, [property: JsonPropertyName("pub")] byte[]? Pub = null,
    [property: JsonPropertyName("commit")] byte[]? Commit = null, [property: JsonPropertyName("deviceName")] string? DeviceName = null);
internal sealed record ServerChallenge(
    [property: JsonPropertyName("nonce")] byte[] Nonce, [property: JsonPropertyName("pub")] byte[]? Pub,
    [property: JsonPropertyName("locked")] bool Locked);
internal sealed record ClientReveal([property: JsonPropertyName("pub")] byte[] Pub);
internal sealed record ClientProof([property: JsonPropertyName("mac")] byte[] Mac);
internal sealed record ServerResult(
    [property: JsonPropertyName("ok")] bool Ok, [property: JsonPropertyName("mac")] byte[]? Mac = null,
    [property: JsonPropertyName("reason")] string? Reason = null);

/// <summary>
/// A length-prefixed, authenticated, encrypted channel over TCP (port of BrushKit's SecureChannel).
/// Wire format: <c>[UInt32 length][payload]</c>; JSON during the handshake, then
/// <c>ChaCha20-Poly1305([kind][body])</c>.
/// </summary>
public sealed class SecureChannel : IAsyncDisposable
{
    public const int MaxFrameSize = 16 * 1024 * 1024;
    public const int MaxHandshakeFrameSize = 4 * 1024;
    public static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(90);

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private FrameCipher? _send, _receive;
    private int _pendingSends;
    /// <summary>Server: the limiter attempt this connection holds until the handshake ends.</summary>
    private (FailureLimiter Limiter, string Host)? _attempt;

    public AuthMode AuthMode { get; private set; }
    public string RemoteHost { get; }
    /// <summary>Frames handed to the network that haven't been written yet (video skips frames when busy).</summary>
    public int PendingSends => Volatile.Read(ref _pendingSends);

    private SecureChannel(TcpClient client)
    {
        _client = client;
        _client.NoDelay = true;
        _stream = client.GetStream();
        RemoteHost = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.MapToIPv4().ToString() ?? "unknown";
    }

    // MARK: Server

    /// <summary>Runs the server side of the handshake. Throws <see cref="ChannelException"/> when it fails.</summary>
    public static async Task<SecureChannel> AcceptAsync(TcpClient client, ServerAuth auth, CancellationToken ct = default)
    {
        var channel = new SecureChannel(client);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(HandshakeTimeout);
        try
        {
            await channel.ServerHandshakeAsync(auth, timeout.Token);
            return channel;
        }
        catch (Exception e)
        {
            await channel.DisposeAsync();
            throw e as ChannelException ?? new ChannelException(e is OperationCanceledException ? ChannelErrorKind.Protocol : ChannelErrorKind.Closed,
                                                              e is OperationCanceledException ? "timeout" : e.Message);
        }
    }

    private async Task ServerHandshakeAsync(ServerAuth auth, CancellationToken ct)
    {
        var hello = await ReadJsonAsync<ClientHello>(ct);
        var keyPair = new KeyPair();
        var nonce = Handshake.RandomNonce();
        if (!auth.Limiter.Begin(RemoteHost))
        {
            await WriteJsonAsync(new ServerChallenge(nonce, null, true), ct);
            throw new ChannelException(ChannelErrorKind.Locked);
        }
        _attempt = (auth.Limiter, RemoteHost);
        try
        {
            if (hello.V != ProtocolInfo.Version) throw new ChannelException(ChannelErrorKind.Protocol, "version");
            await WriteJsonAsync(new ServerChallenge(nonce, keyPair.Public, false), ct);
            var (keys, mode) = await AuthenticateClientAsync(hello, keyPair, nonce, auth, ct);
            ReleaseAttempt(success: true);
            await WriteJsonAsync(new ServerResult(true, keys.ServerProof), ct);
            Ready(mode, send: keys.ServerToClient, receive: keys.ClientToServer);
        }
        finally
        {
            ReleaseAttempt(success: false); // no-op after success; counts a handshake abandoned halfway
        }
    }

    /// <summary>Checks the client's proof (and, in confirm mode, the user's Allow). Throws after telling the client why.</summary>
    private async Task<(HandshakeKeys Keys, AuthMode Mode)> AuthenticateClientAsync(ClientHello hello, KeyPair keyPair, byte[] nonce,
                                                                                ServerAuth auth, CancellationToken ct)
    {
        if (hello.Mode != "confirm")
        {
            var keys = ServerKeys(hello, hello.Pub, keyPair, nonce, auth.Token, AuthMode.Token)
                       ?? throw await RejectAsync(ChannelErrorKind.AuthFailed, ct);
            await CheckProofAsync(keys, ReadJsonAsync<ClientProof>(ct), ct);
            return (keys, AuthMode.Token);
        }
        var reveal = await ReadJsonAsync<ClientReveal>(ct);
        var confirmKeys = (hello.Commit is { } commit && CryptographicOperations.FixedTimeEquals(Handshake.Commitment(reveal.Pub), commit)
                              ? ServerKeys(hello, reveal.Pub, keyPair, nonce, null, AuthMode.Confirm)
                              : null)
                          ?? throw await RejectAsync(ChannelErrorKind.AuthFailed, ct);
        await WaitForProofAndAllowAsync(confirmKeys, hello, auth, ct);
        return (confirmKeys, AuthMode.Confirm);
    }

    private static HandshakeKeys? ServerKeys(ClientHello hello, byte[]? clientPub, KeyPair keyPair, byte[] nonce, string? token, AuthMode mode)
    {
        if (clientPub is null || keyPair.Agree(clientPub) is not { } shared) return null;
        return new HandshakeKeys(shared, token, mode, hello.Nonce, nonce, clientPub, keyPair.Public);
    }

    /// <summary>Confirm mode needs both the user's Allow and a valid proof (sent once the phone user confirms), in either order.</summary>
    private async Task WaitForProofAndAllowAsync(HandshakeKeys keys, ClientHello hello, ServerAuth auth, CancellationToken ct)
    {
        var request = new ConfirmRequest(Guid.NewGuid(), Handshake.DisplayName(hello.DeviceName), keys.ConfirmCode, RemoteHost);
        var answered = false;
        try
        {
            var approval = auth.Approve(request);
            var proof = ReadJsonAsync<ClientProof>(ct);
            var allowedFirst = await Task.WhenAny(approval, proof) == approval;
            if (!allowedFirst) await CheckProofAsync(keys, proof, ct);
            var allowed = await approval.WaitAsync(ct);
            answered = true;
            if (!allowed) throw await RejectAsync(ChannelErrorKind.Denied, ct);
            if (allowedFirst) await CheckProofAsync(keys, proof, ct);
        }
        finally
        {
            if (!answered) auth.CancelApproval(request.Id);
        }
    }

    private async Task CheckProofAsync(HandshakeKeys keys, Task<ClientProof> proof, CancellationToken ct)
    {
        if (!keys.IsValidClientProof((await proof).Mac)) throw await RejectAsync(ChannelErrorKind.AuthFailed, ct);
    }

    /// <summary>Records the failure, tells the client why, and returns the exception for the caller to throw.</summary>
    private async Task<ChannelException> RejectAsync(ChannelErrorKind kind, CancellationToken ct)
    {
        var attempt = _attempt;
        ReleaseAttempt(success: false); // record first, so the attempt that locks the host already says "locked"
        var locked = attempt is { } a && a.Limiter.IsLocked(a.Host);
        var reason = locked ? "locked" : kind == ChannelErrorKind.Denied ? "denied" : "auth";
        await WriteJsonAsync(new ServerResult(false, null, reason), ct);
        return new ChannelException(kind);
    }

    private void Ready(AuthMode mode, byte[] send, byte[] receive)
    {
        AuthMode = mode;
        _send = new FrameCipher(send);
        _receive = new FrameCipher(receive);
    }

    private void ReleaseAttempt(bool success)
    {
        if (_attempt is not { } a) return;
        _attempt = null;
        a.Limiter.Finish(a.Host, success);
    }

    // MARK: Client (used by tests and tools; the phone app has its own)

    public static async Task<SecureChannel> ConnectAsync(string host, int port, string? token, string? deviceName,
                                                         Func<string, Task<bool>>? confirmCode = null, CancellationToken ct = default)
    {
        var client = new TcpClient();
        await client.ConnectAsync(host, port, ct);
        var channel = new SecureChannel(client);
        try
        {
            await channel.ClientHandshakeAsync(token, deviceName, confirmCode, ct);
            return channel;
        }
        catch
        {
            await channel.DisposeAsync();
            throw;
        }
    }

    private async Task ClientHandshakeAsync(string? token, string? deviceName, Func<string, Task<bool>>? confirmCode, CancellationToken ct)
    {
        var mode = token is null ? AuthMode.Confirm : AuthMode.Token;
        var keys = await ClientKeysAsync(token, deviceName, mode, ct);
        if (mode == AuthMode.Confirm && (confirmCode is null || !await confirmCode(keys.ConfirmCode)))
            throw new ChannelException(ChannelErrorKind.Closed);
        await WriteJsonAsync(new ClientProof(keys.ClientProof), ct);
        var result = await ReadJsonAsync<ServerResult>(ct);
        if (!result.Ok || result.Mac is null || !keys.IsValidServerProof(result.Mac))
        {
            throw new ChannelException(result.Reason switch
            {
                "locked" => ChannelErrorKind.Locked, "denied" => ChannelErrorKind.Denied, _ => ChannelErrorKind.AuthFailed,
            });
        }
        Ready(mode, send: keys.ClientToServer, receive: keys.ServerToClient);
    }

    /// <summary>Hello, challenge and (confirm mode) reveal: the keys both sides now share.</summary>
    private async Task<HandshakeKeys> ClientKeysAsync(string? token, string? deviceName, AuthMode mode, CancellationToken ct)
    {
        var keyPair = new KeyPair();
        var nonce = Handshake.RandomNonce();
        await WriteJsonAsync(mode == AuthMode.Token
            ? new ClientHello(ProtocolInfo.Version, "token", nonce, keyPair.Public)
            : new ClientHello(ProtocolInfo.Version, "confirm", nonce, Commit: Handshake.Commitment(keyPair.Public), DeviceName: deviceName), ct);
        var challenge = await ReadJsonAsync<ServerChallenge>(ct);
        if (challenge.Locked) throw new ChannelException(ChannelErrorKind.Locked);
        if (challenge.Pub is null || keyPair.Agree(challenge.Pub) is not { } shared) throw new ChannelException(ChannelErrorKind.Protocol, "key");
        if (mode == AuthMode.Confirm) await WriteJsonAsync(new ClientReveal(keyPair.Public), ct);
        return new HandshakeKeys(shared, token, mode, nonce, challenge.Nonce, keyPair.Public, challenge.Pub);
    }

    // MARK: Encrypted frames

    public async Task SendAsync(FrameKind kind, byte[] body, CancellationToken ct = default)
    {
        Interlocked.Increment(ref _pendingSends);
        await _writeLock.WaitAsync(ct);
        try
        {
            var send = _send ?? throw new InvalidOperationException("handshake not finished");
            // Encrypt straight into the outgoing frame, after its 4-byte length: no extra copies of the body.
            var frame = send.Seal([(byte)kind], body, headroom: 4);
            BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)(frame.Length - 4));
            await _stream.WriteAsync(frame, ct);
        }
        finally
        {
            _writeLock.Release();
            Interlocked.Decrement(ref _pendingSends);
        }
    }

    public Task SendAsync(ServerMessage message, CancellationToken ct = default) => SendAsync(FrameKind.Message, MessageCodec.Encode(message), ct);

    public Task SendAsync(ClientMessage message, CancellationToken ct = default) => SendAsync(FrameKind.Message, MessageCodec.Encode(message), ct);

    /// <summary>The next frame. Throws <see cref="ChannelException"/> on a bad frame or a closed connection.</summary>
    public async Task<(FrameKind Kind, byte[] Body)> ReceiveAsync(CancellationToken ct = default)
    {
        var receive = _receive ?? throw new InvalidOperationException("handshake not finished");
        var data = await ReadRawAsync(MaxFrameSize, ct);
        byte[] plain;
        try { plain = receive.Open(data); }
        catch (CryptographicException) { throw new ChannelException(ChannelErrorKind.Protocol, "decrypt"); }
        if (plain.Length == 0 || !Enum.IsDefined((FrameKind)plain[0])) throw new ChannelException(ChannelErrorKind.Protocol, "frame kind");
        return ((FrameKind)plain[0], plain[1..]);
    }

    // MARK: Raw framing

    private async Task WriteJsonAsync<T>(T value, CancellationToken ct)
    {
        await _writeLock.WaitAsync(ct);
        try { await WriteRawAsync(JsonSerializer.SerializeToUtf8Bytes(value, Json), ct); }
        finally { _writeLock.Release(); }
    }

    private async Task<T> ReadJsonAsync<T>(CancellationToken ct)
    {
        var data = await ReadRawAsync(MaxHandshakeFrameSize, ct);
        try { return JsonSerializer.Deserialize<T>(data, Json) ?? throw new JsonException("null"); }
        catch (JsonException) { throw new ChannelException(ChannelErrorKind.Protocol, "handshake"); }
    }

    private async Task WriteRawAsync(byte[] payload, CancellationToken ct)
    {
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)payload.Length);
        payload.CopyTo(frame, 4);
        await _stream.WriteAsync(frame, ct);
    }

    private async Task<byte[]> ReadRawAsync(int maxLength, CancellationToken ct)
    {
        var header = new byte[4];
        await ReadExactlyAsync(header, ct);
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length == 0 || length > maxLength) throw new ChannelException(ChannelErrorKind.Protocol, "length");
        var body = new byte[length];
        await ReadExactlyAsync(body, ct);
        return body;
    }

    private async Task ReadExactlyAsync(byte[] buffer, CancellationToken ct)
    {
        try { await _stream.ReadExactlyAsync(buffer, ct); }
        catch (EndOfStreamException) { throw new ChannelException(ChannelErrorKind.Closed); }
        catch (IOException) { throw new ChannelException(ChannelErrorKind.Closed); }
    }

    public ValueTask DisposeAsync()
    {
        _client.Dispose();
        _writeLock.Dispose();
        return ValueTask.CompletedTask;
    }
}
