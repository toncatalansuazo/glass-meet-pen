using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Glasspen.Core.Net;
using Glasspen.Core.Protocol;
using Xunit;

namespace Glasspen.Core.Tests;

/// <summary>End-to-end over loopback TCP: both pairing modes and the rejections.</summary>
public class SecureChannelTests
{
    private const string Token = "server-token";

    private sealed class Server : IAsyncDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
        public Task<SecureChannel> Accepted { get; }

        public Server(ServerAuth auth)
        {
            _listener.Start();
            Accepted = Task.Run(async () => await SecureChannel.AcceptAsync(await _listener.AcceptTcpClientAsync(), auth));
        }

        public ValueTask DisposeAsync() { _listener.Stop(); return ValueTask.CompletedTask; }
    }

    private static ServerAuth Auth(Func<ConfirmRequest, Task<bool>>? approve = null, Action<Guid>? cancel = null, FailureLimiter? limiter = null) => new()
    {
        Token = Token, Approve = approve ?? (_ => Task.FromResult(false)), CancelApproval = cancel ?? (_ => { }), Limiter = limiter ?? new FailureLimiter(),
    };

    [Fact]
    public async Task TokenPairingCarriesEncryptedFramesBothWays()
    {
        await using var server = new Server(Auth());
        await using var client = await SecureChannel.ConnectAsync("127.0.0.1", server.Port, Token, null);
        await using var accepted = await server.Accepted;
        Assert.Equal(AuthMode.Token, accepted.AuthMode);
        await client.SendAsync(new ClientMessage.Ping(1.5));
        var (kind, body) = await accepted.ReceiveAsync();
        Assert.Equal(FrameKind.Message, kind);
        Assert.Equal(new ClientMessage.Ping(1.5), MessageCodec.DecodeClient(body));
        await accepted.SendAsync(FrameKind.Detail, new DetailPacket(NormRect.Full, DetailPacket.FullFrameId, [1, 2, 3]).Encode());
        var (k2, b2) = await client.ReceiveAsync();
        Assert.Equal(FrameKind.Detail, k2);
        Assert.Equal([1, 2, 3], DetailPacket.Decode(b2)!.Jpeg);
    }

    [Fact]
    public async Task ConfirmPairingShowsTheSameCodeAndNeedsBothSides()
    {
        string? serverCode = null;
        var allow = new TaskCompletionSource<bool>();
        var asked = new TaskCompletionSource();
        await using var server = new Server(Auth(approve: r => { serverCode = r.Code; asked.TrySetResult(); return allow.Task; }));
        string? phoneCode = null;
        var phoneConfirmed = new TaskCompletionSource();
        var connect = SecureChannel.ConnectAsync("127.0.0.1", server.Port, null, "Test iPhone", code =>
        {
            phoneCode = code;
            phoneConfirmed.TrySetResult();
            return Task.FromResult(true);
        });
        await Task.WhenAll(asked.Task, phoneConfirmed.Task).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(server.Accepted.IsCompleted, "the phone confirmed, but nobody clicked Allow yet");
        allow.SetResult(true);
        await using var client = await connect;
        await using var accepted = await server.Accepted;
        Assert.Equal(AuthMode.Confirm, accepted.AuthMode);
        Assert.NotNull(phoneCode);
        Assert.Equal(phoneCode, serverCode);
    }

    [Fact]
    public async Task AllowOnTheComputerAloneDoesNotPair()
    {
        await using var server = new Server(Auth(approve: _ => Task.FromResult(true)));
        var phoneDecides = new TaskCompletionSource<bool>();
        var phoneAsked = new TaskCompletionSource();
        var connect = SecureChannel.ConnectAsync("127.0.0.1", server.Port, null, "x", _ => { phoneAsked.TrySetResult(); return phoneDecides.Task; });
        await phoneAsked.Task.WaitAsync(TimeSpan.FromSeconds(5)); // the phone shows the code; the computer already allowed
        Assert.False(server.Accepted.IsCompleted);
        phoneDecides.SetResult(false); // Cancel on the phone
        await Assert.ThrowsAsync<ChannelException>(() => connect);
        await Assert.ThrowsAsync<ChannelException>(() => server.Accepted);
    }

    [Fact]
    public async Task CancellingOnThePhoneClosesThePrompt()
    {
        var cancelled = new TaskCompletionSource<Guid>();
        Guid asked = Guid.Empty;
        await using var server = new Server(Auth(approve: r => { asked = r.Id; return new TaskCompletionSource<bool>().Task; }, cancel: id => cancelled.TrySetResult(id)));
        await Assert.ThrowsAsync<ChannelException>(() => SecureChannel.ConnectAsync("127.0.0.1", server.Port, null, "x", _ => Task.FromResult(false)));
        Assert.Equal(asked, await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task DenyAndWrongTokenAreRejected()
    {
        await using (var server = new Server(Auth(approve: _ => Task.FromResult(false))))
        {
            var e = await Assert.ThrowsAsync<ChannelException>(() => SecureChannel.ConnectAsync("127.0.0.1", server.Port, null, "x", _ => Task.FromResult(true)));
            Assert.Equal(ChannelErrorKind.Denied, e.Kind);
        }
        await using (var server = new Server(Auth()))
        {
            var e = await Assert.ThrowsAsync<ChannelException>(() => SecureChannel.ConnectAsync("127.0.0.1", server.Port, "wrong", null));
            Assert.Equal(ChannelErrorKind.AuthFailed, e.Kind);
        }
    }

    [Fact]
    public async Task LockedHostIsRefusedBeforeAnyGuess()
    {
        var limiter = new FailureLimiter(1);
        Assert.True(limiter.Begin("127.0.0.1"));
        limiter.Finish("127.0.0.1", false);
        await using var server = new Server(Auth(limiter: limiter));
        var e = await Assert.ThrowsAsync<ChannelException>(() => SecureChannel.ConnectAsync("127.0.0.1", server.Port, Token, null));
        Assert.Equal(ChannelErrorKind.Locked, e.Kind);
    }

    [Fact]
    public async Task RevealThatDoesNotMatchTheCommitmentIsRejected()
    {
        await using var server = new Server(Auth(approve: _ => throw new Xunit.Sdk.XunitException("must not ask the user")));
        using var raw = new TcpClient();
        await raw.ConnectAsync(IPAddress.Loopback, server.Port);
        var stream = raw.GetStream();
        var committed = new KeyPair();
        var other = new KeyPair();
        await WriteJson(stream, new { v = 2, mode = "confirm", nonce = Handshake.RandomNonce(), commit = Handshake.Commitment(committed.Public), deviceName = "x" });
        await ReadJson(stream); // challenge
        await WriteJson(stream, new { pub = other.Public });
        var result = await ReadJson(stream);
        Assert.False(result.GetProperty("ok").GetBoolean());
        Assert.Equal("auth", result.GetProperty("reason").GetString());
    }

    [Fact]
    public async Task OldVersionIsClosedWithoutAChallenge()
    {
        await using var server = new Server(Auth());
        using var raw = new TcpClient();
        await raw.ConnectAsync(IPAddress.Loopback, server.Port);
        var stream = raw.GetStream();
        await WriteJson(stream, new { v = 1, mode = "token", nonce = Handshake.RandomNonce(), pub = new KeyPair().Public });
        var buffer = new byte[4];
        Assert.Equal(0, await stream.ReadAtLeastAsync(buffer, 4, throwOnEndOfStream: false));
    }

    private static async Task WriteJson(Stream s, object value)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(value);
        var header = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length);
        await s.WriteAsync(header);
        await s.WriteAsync(body);
    }

    private static async Task<JsonElement> ReadJson(Stream s)
    {
        var header = new byte[4];
        await s.ReadExactlyAsync(header);
        var body = new byte[System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(header)];
        await s.ReadExactlyAsync(body);
        return JsonDocument.Parse(body).RootElement;
    }
}
