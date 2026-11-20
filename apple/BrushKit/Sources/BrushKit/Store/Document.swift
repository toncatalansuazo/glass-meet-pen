import Foundation

/// Changes produced by the document, consumed by renderers and the network layer.
public enum DocumentEvent: Equatable, Sendable {
    /// A source started a live (in-progress) stroke.
    case liveBegan(Stroke)
    /// Points were added to a live stroke. For shapes, `points` is the new [start, end].
    case liveUpdated(id: UUID, points: [StrokePoint], replace: Bool)
    /// A live stroke was discarded without committing.
    case liveCancelled(id: UUID)
    /// The committed set changed: strokes added (or restored) and strokes removed.
    case committedChanged(added: [Stroke], removed: [UUID])
}

/// The single source of truth for all annotations. Value type with pure
/// mutating operations that return the events they produced, so it is easy to
/// test and to drive from any actor (the Mac app owns it on the main actor).
public struct Document: Sendable {
    private enum Action: Sendable {
        case add(Stroke)
        case erase([Stroke])
        case clear([Stroke])
    }

    public private(set) var committed: [UUID: Stroke] = [:]
    public private(set) var live: [SourceID: Stroke] = [:]
    private var undoStacks: [SourceID: [Action]] = [:]
    private var redoStacks: [SourceID: [Action]] = [:]
    private var nextSeq: UInt64 = 1

    public static let maxUndoDepth = 200

    public init() {}

    /// Committed strokes in z-order (oldest first).
    public var orderedStrokes: [Stroke] {
        committed.values.sorted { $0.seq < $1.seq }
    }

    // MARK: Live strokes

    @discardableResult
    public mutating func begin(_ stroke: Stroke) -> [DocumentEvent] {
        var events: [DocumentEvent] = []
        if let existing = live[stroke.sourceID] {
            // A source can only have one live stroke; a new one implicitly cancels the old.
            live[stroke.sourceID] = nil
            events.append(.liveCancelled(id: existing.id))
        }
        var s = stroke
        if s.tool.isShape, let first = s.points.first {
            s.points = [first, s.points.last ?? first]
        }
        live[stroke.sourceID] = s
        events.append(.liveBegan(s))
        return events
    }

    @discardableResult
    public mutating func append(source: SourceID, id: UUID, points: [StrokePoint]) -> [DocumentEvent] {
        guard var s = live[source], s.id == id, !points.isEmpty else { return [] }
        if s.tool.isShape {
            let start = s.points.first ?? points[0]
            s.points = [start, points[points.count - 1]]
            live[source] = s
            return [.liveUpdated(id: id, points: s.points, replace: true)]
        }
        s.points.append(contentsOf: points)
        live[source] = s
        return [.liveUpdated(id: id, points: points, replace: false)]
    }

    @discardableResult
    public mutating func end(source: SourceID, id: UUID) -> [DocumentEvent] {
        guard var s = live[source], s.id == id else { return [] }
        live[source] = nil
        guard !s.points.isEmpty else { return [.liveCancelled(id: id)] }
        s.seq = nextSeq; nextSeq += 1
        committed[s.id] = s
        push(.add(s), for: source)
        return [.committedChanged(added: [s], removed: [])]
    }

    @discardableResult
    public mutating func cancel(source: SourceID, id: UUID? = nil) -> [DocumentEvent] {
        guard let s = live[source], id == nil || s.id == id else { return [] }
        live[source] = nil
        return [.liveCancelled(id: s.id)]
    }

    // MARK: Editing

    /// Removes every committed stroke that passes within `radius` of any of `points`.
    /// Coordinates are normalized; `aspect` (width / height) keeps the hit area round.
    @discardableResult
    public mutating func erase(source: SourceID, at points: [StrokePoint], radius: Float, aspect: Float) -> [DocumentEvent] {
        let hits = committed.values.filter { stroke in
            points.contains { Geometry.hitTest(stroke: stroke, point: $0, radius: radius, aspect: aspect) }
        }
        guard !hits.isEmpty else { return [] }
        for h in hits { committed[h.id] = nil }
        push(.erase(hits), for: source)
        return [.committedChanged(added: [], removed: hits.map(\.id))]
    }

    @discardableResult
    public mutating func clear(source: SourceID) -> [DocumentEvent] {
        var events: [DocumentEvent] = []
        for (src, s) in live {
            live[src] = nil
            events.append(.liveCancelled(id: s.id))
        }
        let all = orderedStrokes
        if !all.isEmpty {
            committed.removeAll()
            push(.clear(all), for: source)
            events.append(.committedChanged(added: [], removed: all.map(\.id)))
        }
        return events
    }

    /// Removes strokes permanently (e.g. fading ink). Not undoable; also purged from history.
    @discardableResult
    public mutating func expire(_ ids: [UUID]) -> [DocumentEvent] {
        let present = ids.filter { committed[$0] != nil }
        guard !present.isEmpty else { return [] }
        let set = Set(present)
        for id in present { committed[id] = nil }
        func purge(_ stacks: inout [SourceID: [Action]]) {
            for key in stacks.keys {
                stacks[key] = stacks[key]!.compactMap { action in
                    switch action {
                    case .add(let s): return set.contains(s.id) ? nil : action
                    case .erase(let ss):
                        let rest = ss.filter { !set.contains($0.id) }
                        return rest.isEmpty ? nil : .erase(rest)
                    case .clear(let ss):
                        let rest = ss.filter { !set.contains($0.id) }
                        return rest.isEmpty ? nil : .clear(rest)
                    }
                }
            }
        }
        purge(&undoStacks)
        purge(&redoStacks)
        return [.committedChanged(added: [], removed: present)]
    }

    // MARK: Undo / redo (per source)

    public func canUndo(_ source: SourceID) -> Bool { !(undoStacks[source] ?? []).isEmpty }
    public func canRedo(_ source: SourceID) -> Bool { !(redoStacks[source] ?? []).isEmpty }

    @discardableResult
    public mutating func undo(source: SourceID) -> [DocumentEvent] {
        guard let action = undoStacks[source]?.popLast() else { return [] }
        redoStacks[source, default: []].append(action)
        return apply(action, inverse: true)
    }

    @discardableResult
    public mutating func redo(source: SourceID) -> [DocumentEvent] {
        guard let action = redoStacks[source]?.popLast() else { return [] }
        undoStacks[source, default: []].append(action)
        return apply(action, inverse: false)
    }

    private mutating func apply(_ action: Action, inverse: Bool) -> [DocumentEvent] {
        switch (action, inverse) {
        case (.add(let s), true):
            guard committed[s.id] != nil else { return [] }
            committed[s.id] = nil
            return [.committedChanged(added: [], removed: [s.id])]
        case (.add(let s), false):
            committed[s.id] = s
            return [.committedChanged(added: [s], removed: [])]
        case (.erase(let ss), true), (.clear(let ss), true):
            for s in ss { committed[s.id] = s }
            return [.committedChanged(added: ss, removed: [])]
        case (.erase(let ss), false), (.clear(let ss), false):
            let ids = ss.map(\.id).filter { committed[$0] != nil }
            for id in ids { committed[id] = nil }
            return ids.isEmpty ? [] : [.committedChanged(added: [], removed: ids)]
        }
    }

    private mutating func push(_ action: Action, for source: SourceID) {
        undoStacks[source, default: []].append(action)
        if undoStacks[source]!.count > Self.maxUndoDepth {
            undoStacks[source]!.removeFirst()
        }
        redoStacks[source] = []
    }
}

/// Mirror of the document on a client (phone): applies events received from the Mac.
public struct DocumentMirror: Sendable {
    public private(set) var committed: [UUID: Stroke] = [:]
    public private(set) var live: [UUID: Stroke] = [:]

    public init() {}

    public var orderedStrokes: [Stroke] { committed.values.sorted { $0.seq < $1.seq } }

    public mutating func reset(snapshot: [Stroke]) {
        committed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        live = [:]
    }

    public mutating func apply(_ event: DocumentEvent) {
        switch event {
        case .liveBegan(let s):
            live[s.id] = s
        case .liveUpdated(let id, let points, let replace):
            guard var s = live[id] else { return }
            if replace { s.points = points } else { s.points.append(contentsOf: points) }
            live[id] = s
        case .liveCancelled(let id):
            live[id] = nil
        case .committedChanged(let added, let removed):
            for id in removed { committed[id] = nil }
            for s in added {
                committed[s.id] = s
                live[s.id] = nil
            }
        }
    }
}
