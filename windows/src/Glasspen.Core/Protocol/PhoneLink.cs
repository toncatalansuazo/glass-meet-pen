using Glasspen.Core.Model;

namespace Glasspen.Core.Protocol;

/// <summary>What a phone's drawing messages act on (the app model; a fake in tests).</summary>
public interface IDrawingTarget
{
    void Begin(Stroke stroke);
    void Append(SourceId source, Guid id, IReadOnlyList<StrokePoint> points);
    void End(SourceId source, Guid id);
    void Cancel(SourceId source, Guid? id = null);
    void Erase(SourceId source, IReadOnlyList<StrokePoint> points, float radius);
    void Undo(SourceId? source = null);
    void Redo(SourceId? source = null);
    void Clear(SourceId? source = null);
    void SetPhoneTool(ToolState state, SourceId source);
    void SetDrawMode(bool on);
}

/// <summary>
/// One connected phone's drawing: applies its messages as its own source, and decides which document
/// changes to send back (never the phone's own live stroke, which it already shows).
/// </summary>
public sealed class PhoneLink(IDrawingTarget target, SourceId source)
{
    private readonly HashSet<Guid> _liveIds = new();

    public SourceId Source => source;

    /// <summary>Applies a drawing message. Returns false for the messages the server handles itself.</summary>
    public bool Apply(ClientMessage message)
    {
        switch (message)
        {
            case ClientMessage.StrokeBegin b:
                if (b.Stroke.SourceId != source) return true; // a phone draws only as itself
                _liveIds.Add(b.Stroke.Id);
                target.Begin(b.Stroke);
                return true;
            case ClientMessage.StrokeAppend a: target.Append(source, a.Id, a.Points); return true;
            case ClientMessage.StrokeEnd e: target.End(source, e.Id); _liveIds.Remove(e.Id); return true;
            case ClientMessage.StrokeCancel c: target.Cancel(source, c.Id); _liveIds.Remove(c.Id); return true;
            case ClientMessage.Erase e: target.Erase(source, e.Points, e.Radius); return true;
            case ClientMessage.Undo: target.Undo(source); return true;
            case ClientMessage.Redo: target.Redo(source); return true;
            case ClientMessage.Clear: target.Clear(source); return true;
            case ClientMessage.SetTool t: target.SetPhoneTool(t.State, source); return true;
            case ClientMessage.SetMacDrawMode d: target.SetDrawMode(d.On); return true;
            default: return false;
        }
    }

    /// <summary>The message for the phone about a document change, or null when it already knows.</summary>
    public ServerMessage? Outgoing(DocumentEvent e)
    {
        switch (e)
        {
            case DocumentEvent.LiveBegan b when _liveIds.Contains(b.Stroke.Id): return null;
            case DocumentEvent.LiveUpdated u when _liveIds.Contains(u.Id): return null;
            case DocumentEvent.LiveCancelled c:
                _liveIds.Remove(c.Id); // the computer may cancel a phone stroke (e.g. Clear): tell the phone
                break;
        }
        return ServerMessage.From(e);
    }

    /// <summary>The phone went away: drop the stroke it was drawing.</summary>
    public void Disconnected()
    {
        target.Cancel(source);
        _liveIds.Clear();
    }
}
