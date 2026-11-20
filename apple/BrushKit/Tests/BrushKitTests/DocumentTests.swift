import XCTest
@testable import BrushKit

final class DocumentTests: XCTestCase {
    let phone = SourceID("phone:test")

    func stroke(_ source: SourceID, tool: Tool = .pen, _ pts: [(Float, Float)]) -> Stroke {
        Stroke(sourceID: source, tool: tool, color: RGBAColor.palette[0], width: 0.004,
               points: pts.map { StrokePoint(x: $0.0, y: $0.1) })
    }

    @discardableResult
    func draw(_ doc: inout Document, _ s: Stroke) -> Stroke {
        doc.begin(Stroke(id: s.id, sourceID: s.sourceID, tool: s.tool, color: s.color, width: s.width, points: [s.points[0]]))
        doc.append(source: s.sourceID, id: s.id, points: Array(s.points.dropFirst()))
        doc.end(source: s.sourceID, id: s.id)
        return doc.committed[s.id]!
    }

    func testConcurrentSourcesProduceSeparateStrokes() {
        var doc = Document()
        let a = stroke(.mouse, [(0.1, 0.1)])
        let b = stroke(phone, [(0.5, 0.5)])
        doc.begin(a)
        doc.begin(b)
        XCTAssertEqual(doc.live.count, 2)
        doc.append(source: .mouse, id: a.id, points: [StrokePoint(x: 0.2, y: 0.2)])
        doc.append(source: phone, id: b.id, points: [StrokePoint(x: 0.6, y: 0.6)])
        doc.end(source: phone, id: b.id)
        doc.end(source: .mouse, id: a.id)
        XCTAssertEqual(doc.committed.count, 2)
        XCTAssertEqual(doc.committed[a.id]?.points.count, 2)
        XCTAssertEqual(doc.committed[b.id]?.points.count, 2)
        // Commit order defines z-order.
        XCTAssertEqual(doc.orderedStrokes.map(\.id), [b.id, a.id])
    }

    func testAppendIgnoresWrongStrokeID() {
        var doc = Document()
        let a = stroke(.mouse, [(0.1, 0.1)])
        doc.begin(a)
        XCTAssertTrue(doc.append(source: .mouse, id: UUID(), points: [StrokePoint(x: 0.3, y: 0.3)]).isEmpty)
    }

    func testShapeKeepsOnlyStartAndEnd() {
        var doc = Document()
        let s = stroke(.mouse, tool: .rectangle, [(0.1, 0.1)])
        doc.begin(s)
        doc.append(source: .mouse, id: s.id, points: [StrokePoint(x: 0.2, y: 0.2), StrokePoint(x: 0.4, y: 0.3)])
        doc.append(source: .mouse, id: s.id, points: [StrokePoint(x: 0.5, y: 0.6)])
        XCTAssertEqual(doc.live[.mouse]?.points, [StrokePoint(x: 0.1, y: 0.1), StrokePoint(x: 0.5, y: 0.6)])
    }

    func testUndoRedoIsPerSource() {
        var doc = Document()
        let m = draw(&doc, stroke(.mouse, [(0.1, 0.1), (0.2, 0.2)]))
        let p = draw(&doc, stroke(phone, [(0.5, 0.5), (0.6, 0.6)]))
        _ = draw(&doc, stroke(.mouse, [(0.8, 0.8), (0.9, 0.9)]))

        // Phone undo removes the phone stroke, not the most recent (mouse) one.
        let events = doc.undo(source: phone)
        XCTAssertEqual(events, [.committedChanged(added: [], removed: [p.id])])
        XCTAssertNil(doc.committed[p.id])
        XCTAssertEqual(doc.committed.count, 2)

        doc.redo(source: phone)
        XCTAssertEqual(doc.committed[p.id], p)

        doc.undo(source: .mouse)
        doc.undo(source: .mouse)
        XCTAssertNil(doc.committed[m.id])
        XCTAssertEqual(doc.committed.keys.sorted(), [p.id])
        XCTAssertFalse(doc.canUndo(.mouse))
    }

    func testNewStrokeClearsRedo() {
        var doc = Document()
        _ = draw(&doc, stroke(.mouse, [(0.1, 0.1)]))
        doc.undo(source: .mouse)
        XCTAssertTrue(doc.canRedo(.mouse))
        _ = draw(&doc, stroke(.mouse, [(0.3, 0.3)]))
        XCTAssertFalse(doc.canRedo(.mouse))
    }

    func testCancelDiscardsLiveStroke() {
        var doc = Document()
        let s = stroke(phone, [(0.1, 0.1)])
        doc.begin(s)
        XCTAssertEqual(doc.cancel(source: phone, id: s.id), [.liveCancelled(id: s.id)])
        XCTAssertTrue(doc.live.isEmpty)
        XCTAssertTrue(doc.end(source: phone, id: s.id).isEmpty)
        XCTAssertTrue(doc.committed.isEmpty)
    }

    func testClearRemovesEverythingAndIsUndoable() {
        var doc = Document()
        _ = draw(&doc, stroke(.mouse, [(0.1, 0.1)]))
        _ = draw(&doc, stroke(phone, [(0.5, 0.5)]))
        let live = stroke(phone, [(0.7, 0.7)])
        doc.begin(live)
        let events = doc.clear(source: .mouse)
        XCTAssertTrue(events.contains(.liveCancelled(id: live.id)))
        XCTAssertTrue(doc.committed.isEmpty)
        XCTAssertTrue(doc.live.isEmpty)
        doc.undo(source: .mouse)
        XCTAssertEqual(doc.committed.count, 2)
    }

    func testEraserRemovesWholeStrokesItTouches() {
        var doc = Document()
        let hit = draw(&doc, stroke(.mouse, [(0.1, 0.5), (0.9, 0.5)]))
        let miss = draw(&doc, stroke(.mouse, [(0.1, 0.1), (0.9, 0.1)]))
        let events = doc.erase(source: .mouse, at: [StrokePoint(x: 0.5, y: 0.505)], radius: 0.01, aspect: 1)
        XCTAssertEqual(events, [.committedChanged(added: [], removed: [hit.id])])
        XCTAssertNotNil(doc.committed[miss.id])
        doc.undo(source: .mouse)
        XCTAssertNotNil(doc.committed[hit.id])
    }

    func testExpireIsNotUndoable() {
        var doc = Document()
        let s = draw(&doc, stroke(.mouse, [(0.1, 0.1)]))
        doc.expire([s.id])
        XCTAssertTrue(doc.committed.isEmpty)
        XCTAssertFalse(doc.canUndo(.mouse))
        XCTAssertTrue(doc.undo(source: .mouse).isEmpty)
    }

    func testMirrorFollowsEvents() {
        var doc = Document()
        var mirror = DocumentMirror()
        func sync(_ e: [DocumentEvent]) { e.forEach { mirror.apply($0) } }
        let s = stroke(.mouse, [(0.1, 0.1)])
        sync(doc.begin(s))
        XCTAssertEqual(mirror.live.count, 1)
        sync(doc.append(source: .mouse, id: s.id, points: [StrokePoint(x: 0.2, y: 0.2)]))
        XCTAssertEqual(mirror.live[s.id]?.points.count, 2)
        sync(doc.end(source: .mouse, id: s.id))
        XCTAssertTrue(mirror.live.isEmpty)
        XCTAssertEqual(mirror.orderedStrokes, doc.orderedStrokes)
        sync(doc.undo(source: .mouse))
        XCTAssertTrue(mirror.committed.isEmpty)
    }
}
