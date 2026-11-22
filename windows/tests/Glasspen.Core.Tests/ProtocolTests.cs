using Glasspen.Core.Model;
using Glasspen.Core.Net;
using Glasspen.Core.Protocol;
using Xunit;

namespace Glasspen.Core.Tests;

public class SwiftInteropTests
{
    private static readonly Dictionary<string, byte[]> Fixtures = File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "SwiftFixtures.txt"))
        .Where(l => !l.StartsWith("//") && l.Length > 0)
        .Select(l => l.Split(' '))
        .ToDictionary(p => $"{p[0]} {p[1]}", p => Convert.FromBase64String(p[2]));

    private static readonly Guid StrokeId = Guid.Parse("11111111-2222-3333-4444-555555555555");

    [Fact]
    public void DecodesTheSwiftHello()
    {
        var hello = Assert.IsType<ClientMessage.Hello>(MessageCodec.DecodeClient(Fixtures["client hello"]));
        Assert.Equal(new ClientMessage.Hello(2, ChannelRole.Control, "Ana’s iPhone", new SourceId("device:ABC"), false), hello);
    }

    [Fact]
    public void DecodesTheSwiftStrokeExactly()
    {
        var begin = Assert.IsType<ClientMessage.StrokeBegin>(MessageCodec.DecodeClient(Fixtures["client strokeBegin"]));
        var s = begin.Stroke;
        Assert.Equal(StrokeId, s.Id);
        Assert.Equal(Tool.Arrow, s.Tool);
        Assert.Equal(new RgbaColor(1, 0.5f, 0.25f, 0.75f), s.Color);
        Assert.Equal(0.004f, s.Width);
        Assert.Equal([new StrokePoint(0.1f, 0.2f, 0.5f), new StrokePoint(0.3f, 0.4f, 1)], s.Points);
        Assert.Equal(7UL, s.Seq);
        Assert.Equal(new DateTime(2001, 1, 1, 0, 1, 40, 500, DateTimeKind.Utc), s.CreatedAt);
        Assert.Null(s.Text);
    }

    [Fact]
    public void DecodesEveryOtherSwiftClientMessage()
    {
        Assert.Equal([new StrokePoint(0.5f, 0.6f, 0.9f)], Assert.IsType<ClientMessage.StrokeAppend>(MessageCodec.DecodeClient(Fixtures["client strokeAppend"])).Points);
        Assert.Equal(0.01f, Assert.IsType<ClientMessage.Erase>(MessageCodec.DecodeClient(Fixtures["client erase"])).Radius);
        Assert.IsType<ClientMessage.Undo>(MessageCodec.DecodeClient(Fixtures["client undo"]));
        Assert.Equal(new ToolState(Tool.Ellipse, RgbaColor.Palette[4], WidthPreset.Heavy),
                     Assert.IsType<ClientMessage.SetTool>(MessageCodec.DecodeClient(Fixtures["client setTool"])).State);
        Assert.Equal(new ClientMessage.Viewport(null, 1170, 2532), MessageCodec.DecodeClient(Fixtures["client viewportNil"]));
        Assert.Equal(new ClientMessage.Viewport(new NormRect(0.25f, 0.5f, 0.25f, 0.125f), 100, 200), MessageCodec.DecodeClient(Fixtures["client viewportRect"]));
        Assert.Equal(new ClientMessage.Ping(12.5), MessageCodec.DecodeClient(Fixtures["client ping"]));
        Assert.Equal(new ClientMessage.StrokeEnd(StrokeId), MessageCodec.DecodeClient(Fixtures["client strokeEnd"]));
        Assert.Equal(new ClientMessage.StrokeCancel(StrokeId), MessageCodec.DecodeClient(Fixtures["client strokeCancel"]));
        Assert.IsType<ClientMessage.Redo>(MessageCodec.DecodeClient(Fixtures["client redo"]));
        Assert.IsType<ClientMessage.Clear>(MessageCodec.DecodeClient(Fixtures["client clear"]));
        Assert.Equal(new ClientMessage.SetMacDrawMode(true), MessageCodec.DecodeClient(Fixtures["client setMacDrawMode"]));
        Assert.IsType<ClientMessage.RequestKeyframe>(MessageCodec.DecodeClient(Fixtures["client requestKeyframe"]));
    }

    [Fact]
    public void DecodesSwiftServerMessagesIncludingUnicodeText()
    {
        var welcome = Assert.IsType<ServerMessage.WelcomeMessage>(MessageCodec.DecodeServer(Fixtures["server welcome"])).Welcome;
        Assert.Equal("Mac", welcome.MacName);
        Assert.Equal(new DisplayInfo(1, "Built-in", 1512, 982), welcome.Display);
        Assert.Equal(2, welcome.Snapshot.Count);
        Assert.Equal("Héllo 👋", welcome.Snapshot[1].Text);
        Assert.True(welcome.MacDrawMode);
        Assert.False(welcome.ScreenPermission);
        var changed = Assert.IsType<ServerMessage.CommittedChanged>(MessageCodec.DecodeServer(Fixtures["server committedChanged"]));
        Assert.Equal([StrokeId], changed.Removed);
        Assert.Equal(new ServerMessage.PairingToken("tok_-123"), MessageCodec.DecodeServer(Fixtures["server pairingToken"]));
        Assert.Equal(new ServerMessage.DisplayChanged(new DisplayInfo(65539, "DELL U2720Q", 2560, 1440)), MessageCodec.DecodeServer(Fixtures["server displayChanged"]));
        Assert.Equal(new ServerMessage.ToolChanged(new SourceId("device:ABC"), new ToolState(Tool.Highlighter, RgbaColor.Palette[2], WidthPreset.Fine)),
                     MessageCodec.DecodeServer(Fixtures["server toolChanged"]));
        Assert.Equal(new ServerMessage.SessionEnded("Pairing was reset"), MessageCodec.DecodeServer(Fixtures["server sessionEnded"]));
    }

    /// <summary>
    /// What C# sends has exactly the plist shape Swift writes: same case and key names, same value
    /// types (a Float is a 4-byte real, an Int an integer), nil optionals left out. Our own decoder is
    /// lenient, so a round trip through it alone would not catch a wrong shape.
    /// </summary>
    [Fact]
    public void CSharpEncodingHasTheSwiftPlistShape()
    {
        foreach (var (name, swift) in Fixtures.Where(f => f.Key.StartsWith("client") || f.Key.StartsWith("server")))
        {
            var ours = name.StartsWith("client")
                ? MessageCodec.Encode(MessageCodec.DecodeClient(swift))
                : MessageCodec.Encode(MessageCodec.DecodeServer(swift));
            AssertSameTree(BinaryPlist.Read(swift), BinaryPlist.Read(ours), name);
        }
    }

    [Fact]
    public void EveryServerMessageHasASwiftFixture()
    {
        var cases = typeof(ServerMessage).GetNestedTypes().Where(t => t.IsSubclassOf(typeof(ServerMessage)));
        var fixtures = Fixtures.Keys.Where(k => k.StartsWith("server ")).Select(k => k[7..].ToLowerInvariant()).ToHashSet();
        foreach (var type in cases)
        {
            var wire = type.Name == "WelcomeMessage" ? "welcome" : type.Name.ToLowerInvariant();
            Assert.Contains(wire, fixtures);
        }
    }

    private static void AssertSameTree(object expected, object actual, string path)
    {
        switch (expected)
        {
            case Dictionary<string, object> e:
                var a = Assert.IsType<Dictionary<string, object>>(actual);
                Assert.True(e.Keys.ToHashSet().SetEquals(a.Keys), $"{path}: keys [{string.Join(",", e.Keys)}] vs [{string.Join(",", a.Keys)}]");
                foreach (var (k, v) in e) AssertSameTree(v, a[k], $"{path}.{k}");
                break;
            case List<object> e:
                var l = Assert.IsType<List<object>>(actual);
                Assert.Equal(e.Count, l.Count);
                for (var i = 0; i < e.Count; i++) AssertSameTree(e[i], l[i], $"{path}[{i}]");
                break;
            default:
                Assert.True(expected.GetType() == actual.GetType(), $"{path}: {expected.GetType().Name} vs {actual.GetType().Name}");
                Assert.True(expected.Equals(actual), $"{path}: {expected} vs {actual}");
                break;
        }
    }

    [Fact]
    public void DetailPacketBytesMatchSwift()
    {
        var detail = new DetailPacket(new NormRect(0.25f, 0.5f, 0.1f, 0.05f), 42, [1, 2, 3]);
        Assert.Equal(Fixtures["packet detail"], detail.Encode());
        var full = DetailPacket.Decode(Fixtures["packet fullFrame"])!;
        Assert.Equal(DetailPacket.FullFrameId, full.RequestId);
        Assert.Equal(NormRect.Full, full.Rect);
        Assert.Equal([0xFF, 0xD8], full.Jpeg);
    }

    /// <summary>Same key, same frame counter → the same sealed bytes as Swift (nonce = 4 zero bytes + UInt64 BE counter).</summary>
    [Fact]
    public void SealedFramesMatchSwift()
    {
        var key = Enumerable.Repeat((byte)7, 32).ToArray();
        var tx = new FrameCipher(key);
        Assert.Equal(Fixtures["sealed one"], tx.Seal("one"u8.ToArray()));
        Assert.Equal(Fixtures["sealed two"], tx.Seal("two"u8.ToArray()));
        var rx = new FrameCipher(key);
        Assert.Equal("one"u8.ToArray(), rx.Open(Fixtures["sealed one"]));
        Assert.Equal("two"u8.ToArray(), rx.Open(Fixtures["sealed two"]));
    }

    /// <summary>What C# sends must decode back to the same values Swift would see (round trip through our own reader).</summary>
    [Fact]
    public void ReEncodedSwiftMessagesDecodeTheSame()
    {
        foreach (var (name, bytes) in Fixtures.Where(f => f.Key.StartsWith("client") || f.Key.StartsWith("server")))
        {
            if (name.StartsWith("client"))
            {
                var m = MessageCodec.DecodeClient(bytes);
                Assert.Equal(Describe(m), Describe(MessageCodec.DecodeClient(MessageCodec.Encode(m))));
            }
            else
            {
                var m = MessageCodec.DecodeServer(bytes);
                Assert.Equal(Describe(m), Describe(MessageCodec.DecodeServer(MessageCodec.Encode(m))));
            }
        }
    }

    private static string Describe(object m) => System.Text.Json.JsonSerializer.Serialize(m, m.GetType());

    [Fact]
    public void SkipsStrokesWithToolsThisBuildDoesNotKnow()
    {
        var plist = (Dictionary<string, object>)BinaryPlist.Read(Fixtures["server committedChanged"]);
        var values = (Dictionary<string, object>)plist["committedChanged"];
        var known = (Dictionary<string, object>)((List<object>)values["added"])[0];
        var unknown = new Dictionary<string, object>(known) { ["tool"] = "laser-pointer" };
        values["added"] = new List<object> { unknown, known };
        var decoded = Assert.IsType<ServerMessage.CommittedChanged>(MessageCodec.DecodeServer(BinaryPlist.Write(plist)));
        Assert.Single(decoded.Added);
    }
}

/// <summary>The fixed values in docs/protocol.md §5, so this implementation matches the Swift one.</summary>
public class ProtocolVectorTests
{
    private static byte[] Hex(string s) => Convert.FromHexString(s);
    private static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    [Fact]
    public void KeysMatchTheProtocolSpec()
    {
        var c = new KeyPair(Enumerable.Repeat((byte)0x11, 32).ToArray());
        var s = new KeyPair(Enumerable.Repeat((byte)0x22, 32).ToArray());
        var cn = Enumerable.Repeat((byte)0xAA, 32).ToArray();
        var sn = Enumerable.Repeat((byte)0xBB, 32).ToArray();
        Assert.Equal("7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13", Hex(c.Public));
        Assert.Equal("0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20", Hex(s.Public));
        Assert.Equal("602f73ae9dc4c13584eebb256cf73ef47436761db53b5bb222b7e2f57c7f44eb", Hex(Handshake.Commitment(c.Public)));

        var token = new HandshakeKeys(c.Agree(s.Public)!, "token-123", AuthMode.Token, cn, sn, c.Public, s.Public);
        Assert.Equal("2a333338b0308a156ed90448711b4c8368ed3130c4b0fb526b9f727da7152115", Hex(token.Transcript));
        Assert.Equal("d33f3fde4a92f91d304b4920dbe50a40cf40968ffd936a804a4826594b944fa3", Hex(token.ClientProof));
        Assert.Equal("e973accf70c73a43ae6cbb93308a37bd7bcd117037758eb84c8f8bd32ea78ba7", Hex(token.ServerProof));
        Assert.Equal("6af86210ef328c7cf670e0c07539dbf5c3b5c69c7425c21fa3bbdd6593d6ce83", Hex(token.ClientToServer));
        Assert.Equal("11714f39986989e72499a16b7463eafd78ffb0d34fa6cf248c4b1e84884d5f6d", Hex(token.ServerToClient));
        Assert.Equal("346892", token.ConfirmCode);

        var confirm = new HandshakeKeys(s.Agree(c.Public)!, null, AuthMode.Confirm, cn, sn, c.Public, s.Public);
        Assert.Equal("a8608049eda7e265d38e0cd3dfaf5655e5fe11672f47518d6d3a26af90798c21", Hex(confirm.Transcript));
        Assert.Equal("49a1a4f4692b05fd0cdeb7f0d41701b6bc92fa3186186ee4e7d11e8004c409fe", Hex(confirm.ClientProof));
        Assert.Equal("ef4e8db42ee07992d8fff6c3a34ebe5e2f43e243663f1eca41986a997bccde91", Hex(confirm.ServerProof));
        Assert.Equal("077fbaaab24be29dcdf973312f630d4ae5358ce1c607dbf93c385c8ab0c5f486", Hex(confirm.ClientToServer));
        Assert.Equal("b33276bdc30edf08758bbf1988b372217d2107369faacbff3cef03c1be68bc0a", Hex(confirm.ServerToClient));
        Assert.Equal("015112", confirm.ConfirmCode);
    }

    [Fact]
    public void FrameCipherRejectsReplayAndWrongKey()
    {
        var key = Enumerable.Repeat((byte)7, 32).ToArray();
        var tx = new FrameCipher(key);
        var rx = new FrameCipher(key);
        var a = tx.Seal("one"u8.ToArray());
        Assert.Equal("one"u8.ToArray(), rx.Open(a));
        Assert.Throws<System.Security.Cryptography.CryptographicException>(() => rx.Open(a));
        Assert.Throws<System.Security.Cryptography.CryptographicException>(() => new FrameCipher(new byte[32]).Open(new FrameCipher(key).Seal([1])));
    }

    [Fact]
    public void PairingUrlAndNames()
    {
        var url = new PairingSecret("abc_-1").PairingUrl("Ana’s PC", "192.168.1.20", 7878);
        Assert.Equal("paintscreen://pair?svc=Ana%E2%80%99s%20PC&t=abc_-1&h=192.168.1.20&p=7878", url);
        Assert.Equal(22, PairingSecret.Generate().Token.Length);
        Assert.Equal("Ana's iPhoneCode ok", Handshake.DisplayName("Ana's iPhone\n\nCode ok"));
        Assert.Equal("Unknown device", Handshake.DisplayName("  "));
        Assert.Equal(40, Handshake.DisplayName(new string('x', 99)).Length);
        Assert.Equal("012 345", Handshake.DisplayCode("012345"));
    }

    private static readonly DateTime T0 = new(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void LimiterCountsAttemptsWhenTheyStartAndLocksAfterFive()
    {
        var l = new FailureLimiter(5, TimeSpan.FromSeconds(30));
        for (var i = 0; i < 5; i++) Assert.True(l.Begin("h", T0));
        Assert.False(l.Begin("h", T0)); // parallel connections get no extra tries
        for (var i = 0; i < 5; i++) l.Finish("h", false, T0);
        Assert.True(l.IsLocked("h", T0));
        Assert.True(l.Begin("h", T0.AddSeconds(31)));
        l.Finish("h", true, T0.AddSeconds(31));
        Assert.False(l.IsLocked("h", T0.AddSeconds(31)));
    }

    [Fact]
    public void LimiterForgetsFailuresOlderThanTheLockout()
    {
        var l = new FailureLimiter(2, TimeSpan.FromSeconds(30));
        Assert.True(l.Begin("x", T0));
        l.Finish("x", false, T0);
        Assert.True(l.Begin("x", T0.AddSeconds(31)));
        l.Finish("x", false, T0.AddSeconds(31)); // would be the 2nd failure (a lockout) if the first were remembered
        Assert.False(l.IsLocked("x", T0.AddSeconds(31)));

        var fresh = new FailureLimiter(2, TimeSpan.FromSeconds(30));
        fresh.Begin("y", T0); fresh.Finish("y", false, T0);
        fresh.Begin("y", T0.AddSeconds(10)); fresh.Finish("y", false, T0.AddSeconds(10));
        Assert.True(fresh.IsLocked("y", T0.AddSeconds(10))); // recent failures do count
    }

    [Fact]
    public void SealingInPiecesWithHeadroomMatchesSealingTheWhole()
    {
        var key = Enumerable.Repeat((byte)9, 32).ToArray();
        var whole = new FrameCipher(key).Seal([2, 10, 20, 30]);
        var pieces = new FrameCipher(key).Seal([2], [10, 20, 30], headroom: 4);
        Assert.Equal(whole, pieces[4..]);
    }
}

public class PlistSafetyTests
{
    /// <summary>40 arrays that each reference the next one twice: 2^40 visits without sharing decoded objects.</summary>
    [Fact]
    public void SharedReferencesDecodeInLinearTime()
    {
        const int n = 40;
        var data = new List<byte>("bplist00"u8.ToArray());
        var offsets = new List<byte>();
        for (var i = 0; i < n; i++)
        {
            offsets.Add((byte)data.Count);
            data.AddRange([0xA2, (byte)(i + 1), (byte)(i + 1)]);
        }
        offsets.Add((byte)data.Count);
        data.Add(0x50); // empty string
        var tableStart = data.Count;
        data.AddRange(offsets);
        data.AddRange(Trailer(n + 1, tableStart));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.IsType<List<object>>(BinaryPlist.Read(data.ToArray()));
        Assert.True(watch.ElapsedMilliseconds < 1000);
    }

    [Fact]
    public void LengthsPastTheEndAreFormatErrors()
    {
        var data = new List<byte>("bplist00"u8.ToArray());
        data.AddRange([0x5F, 0x13, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]); // a string "9e18 characters long"
        var tableStart = data.Count;
        data.Add(8);
        data.AddRange(Trailer(1, tableStart));
        Assert.Throws<FormatException>(() => BinaryPlist.Read(data.ToArray()));

        var shortString = new List<byte>("bplist00"u8.ToArray()) { 0x5E, (byte)'a' }; // claims 14 characters, has 1
        tableStart = shortString.Count;
        shortString.Add(8);
        shortString.AddRange(Trailer(1, tableStart));
        Assert.Throws<FormatException>(() => BinaryPlist.Read(shortString.ToArray()));
    }

    private static byte[] Trailer(int count, int tableStart)
    {
        var t = new byte[32];
        t[6] = 1; t[7] = 1;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(t.AsSpan(8), (ulong)count);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(t.AsSpan(24), (ulong)tableStart);
        return t;
    }

    [Fact]
    public void ViewportRectsAreClampedToTheDisplay()
    {
        Assert.Null(new NormRect(float.NaN, 0, 1, 1).ClampedToDisplay());
        Assert.Null(new NormRect(0, 0, float.PositiveInfinity, 1).ClampedToDisplay());
        Assert.Null(new NormRect(2, 2, 1, 1).ClampedToDisplay()); // another monitor
        Assert.Null(new NormRect(0.5f, 0.5f, 0, 0.1f).ClampedToDisplay());
        Assert.Equal(NormRect.Full, new NormRect(-1, -1, 3, 3).ClampedToDisplay());
        var edge = new NormRect(0.75f, 0.5f, 0.5f, 0.25f).ClampedToDisplay()!.Value;
        Assert.Equal(new NormRect(0.75f, 0.5f, 0.25f, 0.25f), edge);
    }
}
