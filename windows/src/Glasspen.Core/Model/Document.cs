namespace Glasspen.Core.Model;

/// <summary>Changes produced by the document, consumed by the overlay and the network layer.</summary>
public abstract record DocumentEvent
{
    public sealed record LiveBegan(Stroke Stroke) : DocumentEvent;
    /// <summary>Points added to a live stroke. For shapes, Points is the new [start, end] and Replace is true.</summary>
    public sealed record LiveUpdated(Guid Id, IReadOnlyList<StrokePoint> Points, bool Replace) : DocumentEvent;
    public sealed record LiveCancelled(Guid Id) : DocumentEvent;
    public sealed record CommittedChanged(IReadOnlyList<Stroke> Added, IReadOnlyList<Guid> Removed) : DocumentEvent;
}

/// <summary>
/// The single source of truth for all annotations (port of BrushKit's Document).
/// Each source has its own undo history. Not thread-safe: use it from the UI thread.
/// </summary>
public sealed class Document
{
    private abstract record Action
    {
        public sealed record Add(Stroke Stroke) : Action;
        /// <summary>Strokes taken away by the eraser or Clear.</summary>
        public sealed record Remove(List<Stroke> Strokes) : Action;
    }

    private readonly Dictionary<Guid, Stroke> _committed = new();
    private readonly Dictionary<SourceId, Stroke> _live = new();
    private readonly Dictionary<SourceId, List<Action>> _undo = new();
    private readonly Dictionary<SourceId, List<Action>> _redo = new();
    private ulong _nextSeq = 1;

    public const int MaxUndoDepth = 200;

    public IReadOnlyDictionary<Guid, Stroke> Committed => _committed;
    public IReadOnlyDictionary<SourceId, Stroke> Live => _live;

    /// <summary>Committed strokes in z-order (oldest first).</summary>
    public List<Stroke> OrderedStrokes => _committed.Values.OrderBy(s => s.Seq).ToList();

    // Live strokes

    public List<DocumentEvent> Begin(Stroke stroke)
    {
        var events = new List<DocumentEvent>();
        if (_live.Remove(stroke.SourceId, out var existing))
            events.Add(new DocumentEvent.LiveCancelled(existing.Id)); // one live stroke per source
        // A live freehand stroke owns its point list, so appends don't copy it (shared with LiveBegan's stroke).
        var s = stroke.Tool.IsShape() && stroke.Points.Count > 0
            ? stroke with { Points = [stroke.Points[0], stroke.Points[^1]] }
            : stroke with { Points = new List<StrokePoint>(stroke.Points) };
        _live[stroke.SourceId] = s;
        events.Add(new DocumentEvent.LiveBegan(s));
        return events;
    }

    public List<DocumentEvent> Append(SourceId source, Guid id, IReadOnlyList<StrokePoint> points)
    {
        if (!_live.TryGetValue(source, out var s) || s.Id != id || points.Count == 0) return [];
        if (s.Tool.IsShape())
        {
            var start = s.Points.Count > 0 ? s.Points[0] : points[0];
            s = s with { Points = [start, points[^1]] };
            _live[source] = s;
            return [new DocumentEvent.LiveUpdated(id, s.Points, true)];
        }
        ((List<StrokePoint>)s.Points).AddRange(points);
        return [new DocumentEvent.LiveUpdated(id, points, false)];
    }

    public List<DocumentEvent> End(SourceId source, Guid id)
    {
        if (!_live.TryGetValue(source, out var s) || s.Id != id) return [];
        _live.Remove(source);
        if (s.Points.Count == 0) return [new DocumentEvent.LiveCancelled(id)];
        s = s with { Seq = _nextSeq++, Points = s.Points.ToArray() }; // committed strokes never change
        _committed[s.Id] = s;
        Push(new Action.Add(s), source);
        return [new DocumentEvent.CommittedChanged([s], [])];
    }

    public List<DocumentEvent> Cancel(SourceId source, Guid? id = null)
    {
        if (!_live.TryGetValue(source, out var s) || (id is { } want && s.Id != want)) return [];
        _live.Remove(source);
        return [new DocumentEvent.LiveCancelled(s.Id)];
    }

    // Editing

    /// <summary>Removes every committed stroke within <paramref name="radius"/> of any point (any source).</summary>
    public List<DocumentEvent> Erase(SourceId source, IReadOnlyList<StrokePoint> points, float radius, float aspect)
    {
        var hits = _committed.Values.Where(s => Geometry.HitsAny(s, points, radius, aspect)).ToList();
        if (hits.Count == 0) return [];
        foreach (var h in hits) _committed.Remove(h.Id);
        Push(new Action.Remove(hits), source);
        return [new DocumentEvent.CommittedChanged([], hits.Select(h => h.Id).ToList())];
    }

    /// <summary>Removes every committed stroke and cancels every live stroke, from all sources.</summary>
    public List<DocumentEvent> Clear(SourceId source)
    {
        var events = new List<DocumentEvent>();
        foreach (var s in _live.Values.ToList()) events.Add(new DocumentEvent.LiveCancelled(s.Id));
        _live.Clear();
        var all = OrderedStrokes;
        if (all.Count > 0)
        {
            _committed.Clear();
            Push(new Action.Remove(all), source);
            events.Add(new DocumentEvent.CommittedChanged([], all.Select(s => s.Id).ToList()));
        }
        return events;
    }

    /// <summary>Removes strokes permanently (fading ink). Not undoable; also purged from history.</summary>
    public List<DocumentEvent> Expire(IEnumerable<Guid> ids)
    {
        var present = ids.Where(_committed.ContainsKey).ToList();
        if (present.Count == 0) return [];
        var set = present.ToHashSet();
        foreach (var id in present) _committed.Remove(id);
        Purge(_undo, set);
        Purge(_redo, set);
        return [new DocumentEvent.CommittedChanged([], present)];
    }

    private static void Purge(Dictionary<SourceId, List<Action>> stacks, HashSet<Guid> ids)
    {
        foreach (var key in stacks.Keys.ToList())
            stacks[key] = stacks[key].Select(a => Without(a, ids)).OfType<Action>().ToList();
    }

    private static Action? Without(Action action, HashSet<Guid> ids) => action switch
    {
        Action.Add add => ids.Contains(add.Stroke.Id) ? null : add,
        Action.Remove r => r.Strokes.Where(s => !ids.Contains(s.Id)).ToList() is { Count: > 0 } rest ? new Action.Remove(rest) : null,
        _ => null,
    };

    // Undo / redo (per source)

    public bool CanUndo(SourceId source) => _undo.TryGetValue(source, out var s) && s.Count > 0;
    public bool CanRedo(SourceId source) => _redo.TryGetValue(source, out var s) && s.Count > 0;

    public List<DocumentEvent> Undo(SourceId source)
    {
        if (!_undo.TryGetValue(source, out var stack) || stack.Count == 0) return [];
        var action = stack[^1];
        stack.RemoveAt(stack.Count - 1);
        Stack(_redo, source).Add(action);
        return Apply(action, inverse: true);
    }

    public List<DocumentEvent> Redo(SourceId source)
    {
        if (!_redo.TryGetValue(source, out var stack) || stack.Count == 0) return [];
        var action = stack[^1];
        stack.RemoveAt(stack.Count - 1);
        Stack(_undo, source).Add(action);
        return Apply(action, inverse: false);
    }

    private List<DocumentEvent> Apply(Action action, bool inverse)
    {
        switch (action)
        {
            case Action.Add add when inverse:
                return _committed.Remove(add.Stroke.Id) ? [new DocumentEvent.CommittedChanged([], [add.Stroke.Id])] : [];
            case Action.Add add:
                _committed[add.Stroke.Id] = add.Stroke;
                return [new DocumentEvent.CommittedChanged([add.Stroke], [])];
            case Action.Remove { Strokes: var strokes }:
                if (inverse)
                {
                    foreach (var s in strokes) _committed[s.Id] = s;
                    return [new DocumentEvent.CommittedChanged(strokes, [])];
                }
                var ids = strokes.Select(s => s.Id).Where(_committed.Remove).ToList();
                return ids.Count == 0 ? [] : [new DocumentEvent.CommittedChanged([], ids)];
            default:
                return [];
        }
    }

    private void Push(Action action, SourceId source)
    {
        var stack = Stack(_undo, source);
        stack.Add(action);
        if (stack.Count > MaxUndoDepth) stack.RemoveAt(0);
        _redo[source] = [];
    }

    private static List<Action> Stack(Dictionary<SourceId, List<Action>> stacks, SourceId source)
    {
        if (!stacks.TryGetValue(source, out var stack)) stacks[source] = stack = [];
        return stack;
    }
}
