using Glasspen.Core.Model;
using Glasspen.Core.Protocol;
using Glasspen.Core.Render;
using Xunit;

namespace Glasspen.Core.Tests;

public class DocumentTests
{
    private static Stroke Pen(SourceId source, params (float X, float Y)[] pts) => new()
    {
        SourceId = source, Tool = Tool.Pen, Color = RgbaColor.Palette[0], Width = 0.004f,
        Points = pts.Select(p => new StrokePoint(p.X, p.Y)).ToList(),
    };

    private static Stroke Draw(Document doc, Stroke s)
    {
        doc.Begin(s);
        doc.End(s.SourceId, s.Id);
        return doc.Committed[s.Id];
    }

    [Fact]
    public void UndoIsPerSourceAndEraseUndoRestoresOtherSources()
    {
        var doc = new Document();
        var phone = new SourceId("device:1");
        var mine = Draw(doc, Pen(SourceId.Mouse, (0.1f, 0.1f), (0.2f, 0.2f)));
        var theirs = Draw(doc, Pen(phone, (0.5f, 0.5f), (0.6f, 0.6f)));
        doc.Undo(SourceId.Mouse);
        Assert.False(doc.Committed.ContainsKey(mine.Id));
        Assert.True(doc.Committed.ContainsKey(theirs.Id));
        doc.Redo(SourceId.Mouse);
        doc.Erase(SourceId.Mouse, [new StrokePoint(0.55f, 0.55f)], 0.01f, 1);
        Assert.False(doc.Committed.ContainsKey(theirs.Id));
        doc.Undo(SourceId.Mouse); // the mouse's erase brings the phone's stroke back
        Assert.True(doc.Committed.ContainsKey(theirs.Id));
    }

    [Fact]
    public void ShapesKeepOnlyStartAndEndAndClearCancelsEveryLiveStroke()
    {
        var doc = new Document();
        var rect = Pen(SourceId.Mouse, (0.1f, 0.1f)) with { Tool = Tool.Rectangle };
        doc.Begin(rect);
        doc.Append(SourceId.Mouse, rect.Id, [new StrokePoint(0.3f, 0.3f), new StrokePoint(0.4f, 0.5f)]);
        Assert.Equal([new StrokePoint(0.1f, 0.1f), new StrokePoint(0.4f, 0.5f)], doc.Live[SourceId.Mouse].Points);
        var events = doc.Clear(new SourceId("device:1"));
        Assert.Contains(events, e => e is DocumentEvent.LiveCancelled c && c.Id == rect.Id);
    }

    [Fact]
    public void ClearCancelsTheLiveStrokesOfEverySource()
    {
        var doc = new Document();
        var phone = new SourceId("device:1");
        var mine = Pen(SourceId.Mouse, (0.1f, 0.1f));
        var theirs = Pen(phone, (0.5f, 0.5f));
        doc.Begin(mine);
        doc.Begin(theirs);
        var cancelled = doc.Clear(SourceId.Mouse).OfType<DocumentEvent.LiveCancelled>().Select(c => c.Id).ToHashSet();
        Assert.Equal([mine.Id, theirs.Id], cancelled.OrderBy(id => id == theirs.Id));
        Assert.Empty(doc.Live);
    }

    // Ported from BrushKit's DocumentTests.swift

    [Fact]
    public void ANewStrokeClearsRedo()
    {
        var doc = new Document();
        Draw(doc, Pen(SourceId.Mouse, (0.1f, 0.1f)));
        doc.Undo(SourceId.Mouse);
        Assert.True(doc.CanRedo(SourceId.Mouse));
        Draw(doc, Pen(SourceId.Mouse, (0.2f, 0.2f)));
        Assert.False(doc.CanRedo(SourceId.Mouse));
    }

    [Fact]
    public void AppendAndEndIgnoreAWrongStrokeId()
    {
        var doc = new Document();
        var s = Pen(SourceId.Mouse, (0.1f, 0.1f));
        doc.Begin(s);
        Assert.Empty(doc.Append(SourceId.Mouse, Guid.NewGuid(), [new StrokePoint(0.9f, 0.9f)]));
        Assert.Empty(doc.End(SourceId.Mouse, Guid.NewGuid()));
        Assert.Single(doc.Live[SourceId.Mouse].Points);
    }

    [Fact]
    public void CancelDiscardsTheLiveStroke()
    {
        var doc = new Document();
        var s = Pen(SourceId.Mouse, (0.1f, 0.1f));
        doc.Begin(s);
        Assert.Equal([new DocumentEvent.LiveCancelled(s.Id)], doc.Cancel(SourceId.Mouse, s.Id));
        Assert.Empty(doc.Live);
        Assert.Empty(doc.Committed);
        Assert.False(doc.CanUndo(SourceId.Mouse));
    }

    [Fact]
    public void ClearRemovesEverythingAndIsUndoable()
    {
        var doc = new Document();
        var a = Draw(doc, Pen(SourceId.Mouse, (0.1f, 0.1f)));
        var b = Draw(doc, Pen(new SourceId("device:1"), (0.2f, 0.2f)));
        doc.Clear(SourceId.Mouse);
        Assert.Empty(doc.Committed);
        doc.Undo(SourceId.Mouse);
        Assert.Equal([a.Id, b.Id], doc.OrderedStrokes.Select(s => s.Id));
    }

    [Fact]
    public void EndingAStrokeWithoutPointsCancelsIt()
    {
        var doc = new Document();
        var s = Pen(SourceId.Mouse);
        doc.Begin(s);
        Assert.Equal([new DocumentEvent.LiveCancelled(s.Id)], doc.End(SourceId.Mouse, s.Id));
        Assert.Empty(doc.Committed);
    }

    [Fact]
    public void BeginningASecondStrokeReplacesTheFirst()
    {
        var doc = new Document();
        var first = Pen(SourceId.Mouse, (0.1f, 0.1f));
        var second = Pen(SourceId.Mouse, (0.2f, 0.2f));
        doc.Begin(first);
        var events = doc.Begin(second);
        Assert.Equal(new DocumentEvent.LiveCancelled(first.Id), events[0]);
        Assert.Equal(second.Id, doc.Live[SourceId.Mouse].Id);
    }

    [Fact]
    public void LongStrokesKeepEveryPointAndCommitAFrozenCopy()
    {
        var doc = new Document();
        var s = Pen(SourceId.Mouse, (0, 0));
        var began = (DocumentEvent.LiveBegan)doc.Begin(s)[0];
        for (var i = 1; i <= 5000; i++) doc.Append(SourceId.Mouse, s.Id, [new StrokePoint(i / 5000f, 0.5f)]);
        Assert.Equal(5001, began.Stroke.Points.Count); // the live stroke the overlay and phone were given grows in place
        var committed = ((DocumentEvent.CommittedChanged)doc.End(SourceId.Mouse, s.Id)[0]).Added[0];
        Assert.Equal(5001, committed.Points.Count);
        Assert.IsType<StrokePoint[]>(committed.Points);
    }

    [Fact]
    public void ExpireRemovesStrokesFromHistoryToo()
    {
        var doc = new Document();
        var s = Draw(doc, Pen(SourceId.Mouse, (0.1f, 0.1f)));
        doc.Expire([s.Id]);
        Assert.Empty(doc.Committed);
        Assert.False(doc.CanUndo(SourceId.Mouse));
    }
}

public class GeometryAndShortcutTests
{
    [Fact]
    public void ShortcutsFollowTheToolbarOrderAndAreUnique()
    {
        Assert.Equal(1, Tool.Pen.ShortcutDigit());
        Assert.Equal(5, Tool.Rectangle.ShortcutDigit());
        Assert.Equal(9, Tool.Text.ShortcutDigit());
        Assert.Equal(0, Tool.Eraser.ShortcutDigit());
        Assert.True(ToolInfo.All.Length <= 10);
        Assert.Equal(ToolInfo.All.Length, ToolInfo.All.Select(t => t.ShortcutDigit()).Distinct().Count());
        Assert.Equal(ToolInfo.All.Length, ToolInfo.All.Select(t => t.ShortcutKey()).Distinct().Count());
    }

    [Fact]
    public void WhiteboardGoesAwayWithTheToolbar()
    {
        Assert.Equal(0.8f, Whiteboard.VisibleOpacity(true, 0.8, true));
        Assert.Equal(0f, Whiteboard.VisibleOpacity(true, 1, false));
        Assert.Equal(0f, Whiteboard.VisibleOpacity(false, 1, true));
    }

    [Fact]
    public void ConstrainMakesSquaresAndFigureProportions()
    {
        var end = Geometry.Constrain(Tool.Rectangle, new StrokePoint(0.1f, 0.1f), new StrokePoint(0.3f, 0.2f), 2);
        Assert.Equal((end.X - 0.1f) * 2, end.Y - 0.1f, 4);
        var fig = Geometry.Constrain(Tool.Phone, new StrokePoint(0, 0), new StrokePoint(0.1f, 0.4f), 1);
        Assert.Equal(0.5f, fig.X / fig.Y, 3);
    }

    [Fact]
    public void EraserHitsShapesAndTextBoxes()
    {
        var text = new Stroke { SourceId = SourceId.Mouse, Tool = Tool.Text, Color = RgbaColor.Palette[0], Width = 0.004f,
                                Points = [new(0.2f, 0.3f), new(0.4f, 0.35f)], Text = "Hi" };
        Assert.True(Geometry.HitTest(text, new StrokePoint(0.3f, 0.32f), 0.001f, 1));
        Assert.False(Geometry.HitTest(text, new StrokePoint(0.6f, 0.6f), 0.001f, 1));
        var rect = text with { Tool = Tool.Rectangle, Text = null };
        Assert.True(Geometry.HitTest(rect, new StrokePoint(0.2f, 0.32f), 0.001f, 1));  // on the edge
        Assert.False(Geometry.HitTest(rect, new StrokePoint(0.3f, 0.32f), 0.001f, 1)); // inside, not on the edge
    }

    [Fact]
    public void EraserFindsTheTouchedSegmentOfALongStroke()
    {
        var points = Enumerable.Range(0, 1000).Select(i => new StrokePoint(i / 1000f, i % 2 == 0 ? 0.2f : 0.21f)).ToList();
        var pen = new Stroke { SourceId = SourceId.Mouse, Tool = Tool.Pen, Color = RgbaColor.Palette[0], Width = 0.002f, Points = points };
        Assert.True(Geometry.HitsAny(pen, [new StrokePoint(0.9f, 0.9f), new StrokePoint(0.5005f, 0.205f)], 0.001f, 1));
        Assert.False(Geometry.HitsAny(pen, [new StrokePoint(0.5f, 0.3f), new StrokePoint(1.2f, 0.2f)], 0.001f, 1));
        Assert.False(Geometry.HitsAny(pen, [new StrokePoint(0.5f, 0.6f)], 0.001f, 0.5f)); // y scaled by the aspect
    }

    [Fact]
    public void RendererProducesPathsForEveryDrawnTool()
    {
        foreach (var tool in ToolInfo.All.Where(t => t != Tool.Text))
        {
            var s = new Stroke { SourceId = SourceId.Mouse, Tool = tool, Color = RgbaColor.Palette[1], Width = 0.005f,
                                 Points = [new(0.1f, 0.1f, 0.2f), new(0.3f, 0.2f, 0.9f), new(0.5f, 0.5f, 0.5f)] };
            var r = StrokePath.Render(s, 1000, 600);
            Assert.NotNull(r);
            Assert.NotEmpty(r!.Ops);
        }
        var pressured = StrokePath.Render(new Stroke { SourceId = SourceId.Mouse, Tool = Tool.Pen, Color = default, Width = 0.005f,
                                                       Points = [new(0.1f, 0.1f, 0.2f), new(0.3f, 0.2f, 0.9f)] }, 1000, 600);
        Assert.Equal(PaintMode.Fill, pressured!.Mode);
    }

    [Fact]
    public void TextCornersStayOnScreenWithoutShrinking()
    {
        var c = TextRules.Corners(100, 30, 980, -20, 34, 1000, 500); // field past the right and top edges
        Assert.Equal(100, (c[1].X - c[0].X) * 1000, 2);
        Assert.Equal(30, (c[1].Y - c[0].Y) * 500, 2);
        Assert.Equal(0, c[0].Y, 4);    // moved down onto the screen
        Assert.Equal(1, c[1].X, 4);    // moved left so its right edge is the screen's
        Assert.Equal(0.9, c[0].X, 4);
        var inside = TextRules.Corners(100, 30, 200, 100, 34, 1000, 500);
        Assert.Equal(0.202, inside[0].X, 4); // the field's 2 px padding
        Assert.Equal(0.204, inside[0].Y, 4); // centred on the 34 px field: 100 + 2
        Assert.Equal([12d, 24d, 44d, 72d], Enum.GetValues<WidthPreset>().Select(TextRules.FontSize));
        // ascent + descent (117.77) centred in a 125 box: (125 − 117.77) / 2 + 96.68.
        Assert.Equal(100.295, TextRules.BaselineOffset(125, 96.68, 21.09), 3);
    }
}

public class PhoneLinkTests
{
    private static readonly SourceId Phone = new("device:1");

    private sealed class Recorder : IDrawingTarget
    {
        public readonly List<string> Calls = [];
        public void Begin(Stroke stroke) => Calls.Add($"begin {stroke.SourceId}");
        public void Append(SourceId source, Guid id, IReadOnlyList<StrokePoint> points) => Calls.Add($"append {source}");
        public void End(SourceId source, Guid id) => Calls.Add($"end {source}");
        public void Cancel(SourceId source, Guid? id = null) => Calls.Add($"cancel {source}");
        public void Erase(SourceId source, IReadOnlyList<StrokePoint> points, float radius) => Calls.Add(FormattableString.Invariant($"erase {source} {radius}"));
        public void Undo(SourceId? source = null) => Calls.Add($"undo {source}");
        public void Redo(SourceId? source = null) => Calls.Add($"redo {source}");
        public void Clear(SourceId? source = null) => Calls.Add($"clear {source}");
        public void SetPhoneTool(ToolState state, SourceId source) => Calls.Add($"tool {source} {state.Tool}");
        public void SetDrawMode(bool on) => Calls.Add($"draw {on}");
    }

    private static Stroke Stroke(SourceId source) => new()
    {
        SourceId = source, Tool = Tool.Pen, Color = RgbaColor.Palette[0], Width = 0.004f, Points = [new(0.1f, 0.1f)],
    };

    [Fact]
    public void AppliesDrawingMessagesAsThePhoneAndLeavesTheRestToTheServer()
    {
        var target = new Recorder();
        var link = new PhoneLink(target, Phone);
        var id = Guid.NewGuid();
        Assert.True(link.Apply(new ClientMessage.StrokeBegin(Stroke(Phone))));
        Assert.True(link.Apply(new ClientMessage.StrokeAppend(id, [])));
        Assert.True(link.Apply(new ClientMessage.StrokeEnd(id)));
        Assert.True(link.Apply(new ClientMessage.Erase([], 0.01f)));
        Assert.True(link.Apply(new ClientMessage.Undo()));
        Assert.True(link.Apply(new ClientMessage.Redo()));
        Assert.True(link.Apply(new ClientMessage.Clear()));
        Assert.True(link.Apply(new ClientMessage.SetTool(new ToolState(Tool.Arrow, RgbaColor.Palette[0], WidthPreset.Fine))));
        Assert.True(link.Apply(new ClientMessage.SetMacDrawMode(true)));
        Assert.False(link.Apply(new ClientMessage.Ping(1)));
        Assert.False(link.Apply(new ClientMessage.Viewport(null, 1, 1)));
        Assert.False(link.Apply(new ClientMessage.RequestKeyframe()));
        Assert.Equal(["begin device:1", "append device:1", "end device:1", "erase device:1 0.01", "undo device:1", "redo device:1",
                      "clear device:1", "tool device:1 Arrow", "draw True"], target.Calls);
    }

    [Fact]
    public void APhoneCannotDrawAsAnotherSource()
    {
        var target = new Recorder();
        new PhoneLink(target, Phone).Apply(new ClientMessage.StrokeBegin(Stroke(SourceId.Mouse)));
        Assert.Empty(target.Calls);
    }

    [Fact]
    public void DoesNotEchoThePhonesOwnLiveStrokeButTellsItWhenTheComputerCancelsIt()
    {
        var link = new PhoneLink(new Recorder(), Phone);
        var own = Stroke(Phone);
        link.Apply(new ClientMessage.StrokeBegin(own));
        Assert.Null(link.Outgoing(new DocumentEvent.LiveBegan(own)));
        Assert.Null(link.Outgoing(new DocumentEvent.LiveUpdated(own.Id, [], false)));
        Assert.Equal(new ServerMessage.LiveCancelled(own.Id), link.Outgoing(new DocumentEvent.LiveCancelled(own.Id)));
        var mouse = Stroke(SourceId.Mouse);
        Assert.Equal(new ServerMessage.LiveBegan(mouse), link.Outgoing(new DocumentEvent.LiveBegan(mouse)));
        Assert.IsType<ServerMessage.CommittedChanged>(link.Outgoing(new DocumentEvent.CommittedChanged([own], [])));
    }

    [Fact]
    public void DisconnectingCancelsThePhonesStroke()
    {
        var target = new Recorder();
        new PhoneLink(target, Phone).Disconnected();
        Assert.Equal(["cancel device:1"], target.Calls);
    }
}
