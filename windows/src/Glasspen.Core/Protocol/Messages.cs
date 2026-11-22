using Glasspen.Core.Model;

namespace Glasspen.Core.Protocol;

public static class ProtocolInfo
{
    public const int Version = 2;
    public const string BonjourType = "_paintscreen._tcp";
    public const ushort DefaultPort = 7878;
}

public enum ChannelRole { Control, Video }

public readonly record struct NormRect(float X, float Y, float W, float H)
{
    public static readonly NormRect Full = new(0, 0, 1, 1);

    /// <summary>
    /// The part of this rect that lies on the display (the unit square), or null when nothing is left or a
    /// value isn't a finite number. A phone's rect is untrusted: this keeps close-ups on the shared display.
    /// </summary>
    public NormRect? ClampedToDisplay()
    {
        if (!float.IsFinite(X) || !float.IsFinite(Y) || !float.IsFinite(W) || !float.IsFinite(H)) return null;
        float x0 = Math.Clamp(X, 0, 1), y0 = Math.Clamp(Y, 0, 1);
        float x1 = Math.Clamp(X + W, 0, 1), y1 = Math.Clamp(Y + H, 0, 1);
        return x1 > x0 && y1 > y0 ? new NormRect(x0, y0, x1 - x0, y1 - y0) : null;
    }
}

/// <summary>Messages from the phone to the computer (Swift's ClientMessage).</summary>
public abstract record ClientMessage
{
    public sealed record Hello(int Version, ChannelRole Role, string DeviceName, SourceId SourceId, bool IsPad) : ClientMessage;
    public sealed record StrokeBegin(Stroke Stroke) : ClientMessage;
    public sealed record StrokeAppend(Guid Id, IReadOnlyList<StrokePoint> Points) : ClientMessage;
    public sealed record StrokeEnd(Guid Id) : ClientMessage;
    public sealed record StrokeCancel(Guid Id) : ClientMessage;
    public sealed record Erase(IReadOnlyList<StrokePoint> Points, float Radius) : ClientMessage;
    public sealed record Undo : ClientMessage;
    public sealed record Redo : ClientMessage;
    public sealed record Clear : ClientMessage;
    public sealed record SetTool(ToolState State) : ClientMessage;
    public sealed record SetMacDrawMode(bool On) : ClientMessage;
    /// <summary>The part of the display the phone shows; null means the whole screen.</summary>
    public sealed record Viewport(NormRect? Rect, int PixelWidth, int PixelHeight) : ClientMessage;
    public sealed record RequestKeyframe : ClientMessage;
    public sealed record Ping(double SentAt) : ClientMessage;
}

public sealed record Welcome(string MacName, DisplayInfo Display, IReadOnlyList<Stroke> Snapshot, ToolState ToolState,
                             bool MacDrawMode, bool ScreenPermission);

/// <summary>Messages from the computer to the phone (Swift's ServerMessage).</summary>
public abstract record ServerMessage
{
    public sealed record WelcomeMessage(Welcome Welcome) : ServerMessage;
    public sealed record LiveBegan(Stroke Stroke) : ServerMessage;
    public sealed record LiveUpdated(Guid Id, IReadOnlyList<StrokePoint> Points, bool Replace) : ServerMessage;
    public sealed record LiveCancelled(Guid Id) : ServerMessage;
    public sealed record CommittedChanged(IReadOnlyList<Stroke> Added, IReadOnlyList<Guid> Removed) : ServerMessage;
    public sealed record ToolChanged(SourceId Source, ToolState State) : ServerMessage;
    public sealed record DrawModeChanged(bool On) : ServerMessage;
    public sealed record DisplayChanged(DisplayInfo Display) : ServerMessage;
    public sealed record ScreenPermission(bool Granted) : ServerMessage;
    public sealed record PairingToken(string Token) : ServerMessage;
    public sealed record SessionEnded(string Reason) : ServerMessage;
    public sealed record Pong(double SentAt) : ServerMessage;

    public static ServerMessage From(DocumentEvent e) => e switch
    {
        DocumentEvent.LiveBegan b => new LiveBegan(b.Stroke),
        DocumentEvent.LiveUpdated u => new LiveUpdated(u.Id, u.Points, u.Replace),
        DocumentEvent.LiveCancelled c => new LiveCancelled(c.Id),
        DocumentEvent.CommittedChanged c => new CommittedChanged(c.Added, c.Removed),
        _ => throw new ArgumentOutOfRangeException(nameof(e)),
    };
}

/// <summary>
/// Encodes and decodes messages as binary plists in the shape Swift's Codable uses for enums:
/// a one-key dictionary named after the case; labeled values as a dictionary, one unlabeled value
/// under "_0", no values as an empty dictionary, nil optionals left out (see docs/protocol.md §7).
/// </summary>
public static class MessageCodec
{
    private static readonly Dictionary<string, object> Empty = new();

    // Server messages (computer → phone)

    public static byte[] Encode(ServerMessage message) => BinaryPlist.Write(ToPlist(message));

    public static ServerMessage DecodeServer(byte[] data) => FromPlistServer(BinaryPlist.Read(data));

    internal static Dictionary<string, object> ToPlist(ServerMessage m) => m switch
    {
        ServerMessage.WelcomeMessage w => Case("welcome", Unlabeled(WelcomePlist(w.Welcome))),
        ServerMessage.LiveBegan b => Case("liveBegan", Unlabeled(StrokePlist(b.Stroke))),
        ServerMessage.LiveUpdated u => Case("liveUpdated", new() { ["id"] = Id(u.Id), ["points"] = Points(u.Points), ["replace"] = u.Replace }),
        ServerMessage.LiveCancelled c => Case("liveCancelled", new() { ["id"] = Id(c.Id) }),
        ServerMessage.CommittedChanged c => Case("committedChanged", new()
        {
            ["added"] = c.Added.Select(s => (object)StrokePlist(s)).ToList(),
            ["removed"] = c.Removed.Select(Id).Cast<object>().ToList(),
        }),
        ServerMessage.ToolChanged t => Case("toolChanged", new() { ["source"] = SourcePlist(t.Source), ["state"] = ToolStatePlist(t.State) }),
        ServerMessage.DrawModeChanged d => Case("drawModeChanged", Unlabeled(d.On)),
        ServerMessage.DisplayChanged d => Case("displayChanged", Unlabeled(DisplayPlist(d.Display))),
        ServerMessage.ScreenPermission p => Case("screenPermission", new() { ["granted"] = p.Granted }),
        ServerMessage.PairingToken p => Case("pairingToken", Unlabeled(p.Token)),
        ServerMessage.SessionEnded s => Case("sessionEnded", new() { ["reason"] = s.Reason }),
        ServerMessage.Pong p => Case("pong", new() { ["sentAt"] = p.SentAt }),
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    internal static ServerMessage FromPlistServer(object root)
    {
        var (name, v) = SingleCase(root);
        return name switch
        {
            "welcome" => new ServerMessage.WelcomeMessage(WelcomeFrom(Dict(v["_0"]))),
            "liveBegan" => new ServerMessage.LiveBegan(StrokeFrom(v["_0"])),
            "liveUpdated" => new ServerMessage.LiveUpdated(Uuid(v["id"]), PointsFrom(v["points"]), (bool)v["replace"]),
            "liveCancelled" => new ServerMessage.LiveCancelled(Uuid(v["id"])),
            "committedChanged" => new ServerMessage.CommittedChanged(StrokesLenient(v["added"]), List(v["removed"]).Select(Uuid).ToList()),
            "toolChanged" => new ServerMessage.ToolChanged(SourceFrom(v["source"]), ToolStateFrom(v["state"])),
            "drawModeChanged" => new ServerMessage.DrawModeChanged((bool)v["_0"]),
            "displayChanged" => new ServerMessage.DisplayChanged(DisplayFrom(v["_0"])),
            "screenPermission" => new ServerMessage.ScreenPermission((bool)v["granted"]),
            "pairingToken" => new ServerMessage.PairingToken((string)v["_0"]),
            "sessionEnded" => new ServerMessage.SessionEnded((string)v["reason"]),
            "pong" => new ServerMessage.Pong(Real(v["sentAt"])),
            _ => throw new FormatException($"unknown server message '{name}'"),
        };
    }

    // Client messages (phone → computer)

    public static byte[] Encode(ClientMessage message) => BinaryPlist.Write(ToPlist(message));

    public static ClientMessage DecodeClient(byte[] data) => FromPlistClient(BinaryPlist.Read(data));

    internal static Dictionary<string, object> ToPlist(ClientMessage m) => m switch
    {
        ClientMessage.Hello h => Case("hello", new()
        {
            ["version"] = (long)h.Version, ["role"] = h.Role.ToString().ToLowerInvariant(), ["deviceName"] = h.DeviceName,
            ["sourceID"] = SourcePlist(h.SourceId), ["isPad"] = h.IsPad,
        }),
        ClientMessage.StrokeBegin b => Case("strokeBegin", Unlabeled(StrokePlist(b.Stroke))),
        ClientMessage.StrokeAppend a => Case("strokeAppend", new() { ["id"] = Id(a.Id), ["points"] = Points(a.Points) }),
        ClientMessage.StrokeEnd e => Case("strokeEnd", new() { ["id"] = Id(e.Id) }),
        ClientMessage.StrokeCancel c => Case("strokeCancel", new() { ["id"] = Id(c.Id) }),
        ClientMessage.Erase e => Case("erase", new() { ["points"] = Points(e.Points), ["radius"] = new PlistReal32(e.Radius) }),
        ClientMessage.Undo => Case("undo", Empty),
        ClientMessage.Redo => Case("redo", Empty),
        ClientMessage.Clear => Case("clear", Empty),
        ClientMessage.SetTool t => Case("setTool", Unlabeled(ToolStatePlist(t.State))),
        ClientMessage.SetMacDrawMode d => Case("setMacDrawMode", Unlabeled(d.On)),
        ClientMessage.Viewport v => Case("viewport", ViewportPlist(v)),
        ClientMessage.RequestKeyframe => Case("requestKeyframe", Empty),
        ClientMessage.Ping p => Case("ping", new() { ["sentAt"] = p.SentAt }),
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    internal static ClientMessage FromPlistClient(object root)
    {
        var (name, v) = SingleCase(root);
        return name switch
        {
            "hello" => new ClientMessage.Hello((int)Int(v["version"]), Enum.Parse<ChannelRole>((string)v["role"], ignoreCase: true),
                                               (string)v["deviceName"], SourceFrom(v["sourceID"]), (bool)v["isPad"]),
            "strokeBegin" => new ClientMessage.StrokeBegin(StrokeFrom(v["_0"])),
            "strokeAppend" => new ClientMessage.StrokeAppend(Uuid(v["id"]), PointsFrom(v["points"])),
            "strokeEnd" => new ClientMessage.StrokeEnd(Uuid(v["id"])),
            "strokeCancel" => new ClientMessage.StrokeCancel(Uuid(v["id"])),
            "erase" => new ClientMessage.Erase(PointsFrom(v["points"]), Float(v["radius"])),
            "undo" => new ClientMessage.Undo(),
            "redo" => new ClientMessage.Redo(),
            "clear" => new ClientMessage.Clear(),
            "setTool" => new ClientMessage.SetTool(ToolStateFrom(v["_0"])),
            "setMacDrawMode" => new ClientMessage.SetMacDrawMode((bool)v["_0"]),
            "viewport" => new ClientMessage.Viewport(v.TryGetValue("rect", out var r) ? RectFrom(r) : null,
                                                     (int)Int(v["pixelWidth"]), (int)Int(v["pixelHeight"])),
            "requestKeyframe" => new ClientMessage.RequestKeyframe(),
            "ping" => new ClientMessage.Ping(Real(v["sentAt"])),
            _ => throw new FormatException($"unknown client message '{name}'"),
        };
    }

    // Value types

    internal static Dictionary<string, object> StrokePlist(Stroke s)
    {
        var d = new Dictionary<string, object>
        {
            ["id"] = Id(s.Id), ["sourceID"] = SourcePlist(s.SourceId), ["tool"] = s.Tool.WireName(),
            ["color"] = ColorPlist(s.Color), ["width"] = new PlistReal32(s.Width), ["points"] = Points(s.Points),
            ["seq"] = checked((long)s.Seq), ["createdAt"] = s.CreatedAt,
        };
        if (s.Text is { } text) d["text"] = text;
        return d;
    }

    /// <summary>Throws <see cref="FormatException"/> for a tool this build doesn't know.</summary>
    internal static Stroke StrokeFrom(object o)
    {
        var d = Dict(o);
        if (!ToolInfo.TryParse((string)d["tool"], out var tool)) throw new FormatException($"unknown tool '{d["tool"]}'");
        return new Stroke
        {
            Id = Uuid(d["id"]), SourceId = SourceFrom(d["sourceID"]), Tool = tool, Color = ColorFrom(d["color"]),
            Width = Float(d["width"]), Points = PointsFrom(d["points"]), Seq = (ulong)Int(d["seq"]),
            CreatedAt = (DateTime)d["createdAt"], Text = d.TryGetValue("text", out var t) ? (string)t : null,
        };
    }

    /// <summary>Skips strokes this build can't read, so a newer phone or computer never breaks the whole message.</summary>
    internal static List<Stroke> StrokesLenient(object o)
    {
        var strokes = new List<Stroke>();
        foreach (var item in List(o))
        {
            try { strokes.Add(StrokeFrom(item)); }
            catch (Exception e) when (e is FormatException or KeyNotFoundException or InvalidCastException) { }
        }
        return strokes;
    }

    private static Dictionary<string, object> WelcomePlist(Welcome w) => new()
    {
        ["macName"] = w.MacName, ["display"] = DisplayPlist(w.Display),
        ["snapshot"] = w.Snapshot.Select(s => (object)StrokePlist(s)).ToList(),
        ["toolState"] = ToolStatePlist(w.ToolState), ["macDrawMode"] = w.MacDrawMode, ["screenPermission"] = w.ScreenPermission,
    };

    private static Welcome WelcomeFrom(Dictionary<string, object> d) =>
        new((string)d["macName"], DisplayFrom(d["display"]), StrokesLenient(d["snapshot"]), ToolStateFrom(d["toolState"]),
            (bool)d["macDrawMode"], (bool)d["screenPermission"]);

    private static Dictionary<string, object> SourcePlist(SourceId s) => new() { ["rawValue"] = s.RawValue };
    private static SourceId SourceFrom(object o) => new((string)Dict(o)["rawValue"]);

    private static Dictionary<string, object> ColorPlist(RgbaColor c) => new()
    {
        ["r"] = new PlistReal32(c.R), ["g"] = new PlistReal32(c.G), ["b"] = new PlistReal32(c.B), ["a"] = new PlistReal32(c.A),
    };

    private static RgbaColor ColorFrom(object o)
    {
        var d = Dict(o);
        return new RgbaColor(Float(d["r"]), Float(d["g"]), Float(d["b"]), Float(d["a"]));
    }

    private static Dictionary<string, object> ToolStatePlist(ToolState t) => new()
    {
        ["tool"] = t.Tool.WireName(), ["color"] = ColorPlist(t.Color), ["width"] = (long)t.Width,
    };

    private static ToolState ToolStateFrom(object o)
    {
        var d = Dict(o);
        ToolInfo.TryParse((string)d["tool"], out var tool);
        return new ToolState(tool, ColorFrom(d["color"]), (WidthPreset)Math.Clamp(Int(d["width"]), 0, 3));
    }

    private static Dictionary<string, object> DisplayPlist(DisplayInfo d) => new()
    {
        ["id"] = (long)d.Id, ["name"] = d.Name, ["width"] = new PlistReal32(d.Width), ["height"] = new PlistReal32(d.Height),
    };

    private static DisplayInfo DisplayFrom(object o)
    {
        var d = Dict(o);
        return new DisplayInfo((uint)Int(d["id"]), (string)d["name"], Float(d["width"]), Float(d["height"]));
    }

    private static Dictionary<string, object> ViewportPlist(ClientMessage.Viewport v)
    {
        var d = new Dictionary<string, object> { ["pixelWidth"] = (long)v.PixelWidth, ["pixelHeight"] = (long)v.PixelHeight };
        if (v.Rect is { } r) d["rect"] = RectPlist(r);
        return d;
    }

    internal static Dictionary<string, object> RectPlist(NormRect r) => new()
    {
        ["x"] = new PlistReal32(r.X), ["y"] = new PlistReal32(r.Y), ["w"] = new PlistReal32(r.W), ["h"] = new PlistReal32(r.H),
    };

    private static NormRect RectFrom(object o)
    {
        var d = Dict(o);
        return new NormRect(Float(d["x"]), Float(d["y"]), Float(d["w"]), Float(d["h"]));
    }

    private static List<object> Points(IReadOnlyList<StrokePoint> points) =>
        points.Select(p => (object)new Dictionary<string, object>
        {
            ["x"] = new PlistReal32(p.X), ["y"] = new PlistReal32(p.Y), ["p"] = new PlistReal32(p.P),
        }).ToList();

    private static List<StrokePoint> PointsFrom(object o) =>
        List(o).Select(Dict).Select(d => new StrokePoint(Float(d["x"]), Float(d["y"]), Float(d["p"]))).ToList();

    // Helpers

    private static Dictionary<string, object> Case(string name, Dictionary<string, object> values) => new() { [name] = values };
    private static Dictionary<string, object> Unlabeled(object value) => new() { ["_0"] = value };

    private static (string Name, Dictionary<string, object> Values) SingleCase(object root)
    {
        var d = Dict(root);
        if (d.Count != 1) throw new FormatException("a message has exactly one case");
        var (name, values) = d.First();
        return (name, Dict(values));
    }

    private static string Id(Guid g) => g.ToString("D").ToUpperInvariant();
    private static Guid Uuid(object o) => Guid.Parse((string)o);
    private static Dictionary<string, object> Dict(object o) => o as Dictionary<string, object> ?? throw new FormatException("expected a dictionary");
    private static List<object> List(object o) => o as List<object> ?? throw new FormatException("expected an array");

    private static long Int(object o) => o switch
    {
        long l => l, double d => (long)d, PlistReal32 f => (long)f.Value, _ => throw new FormatException("expected a number"),
    };

    private static double Real(object o) => o switch
    {
        double d => d, PlistReal32 f => f.Value, long l => l, _ => throw new FormatException("expected a number"),
    };

    private static float Float(object o) => (float)Real(o);
}
