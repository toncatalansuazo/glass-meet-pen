import XCTest
@testable import BrushKit

final class TextStrokeTests: XCTestCase {
    private func textStroke(_ text: String = "Hello") -> Stroke {
        Stroke(sourceID: .mouse, tool: .text, color: RGBAColor.palette[0], width: 0.004,
               points: [StrokePoint(x: 0.2, y: 0.3), StrokePoint(x: 0.4, y: 0.35)], text: text)
    }

    func testTextTravelsInMessages() throws {
        let s = textStroke()
        let decoded = try MessageCodec.decode(ServerMessage.self, from: MessageCodec.encode(ServerMessage.liveBegan(s)))
        XCTAssertEqual(decoded, .liveBegan(s))
    }

    /// Strokes from a computer that doesn't send "text" at all still decode.
    func testStrokeWithoutTextKeyStillDecodes() throws {
        let pen = Stroke(sourceID: .mouse, tool: .pen, color: RGBAColor.palette[0], width: 0.004, points: [StrokePoint(x: 0, y: 0)])
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: MessageCodec.encode(pen), format: nil) as? [String: Any])
        XCTAssertNil(plist["text"], "no text key is sent for other tools")
        plist["text"] = nil
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let decoded = try MessageCodec.decode(Stroke.self, from: data)
        XCTAssertEqual(decoded, pen)
        XCTAssertNil(decoded.text)
    }

    func testTextIsDrawnInsideItsBox() throws {
        let size = CGSize(width: 1000, height: 1000)
        let r = try XCTUnwrap(StrokeRenderer.render(textStroke(), size: size))
        guard case .fill = r.mode else { return XCTFail("text is filled glyph outlines") }
        let bounds = r.path.boundingBoxOfPath
        XCTAssertFalse(bounds.isEmpty)
        let box = CGRect(x: 200, y: 300, width: 200, height: 50).insetBy(dx: -1, dy: -1)
        XCTAssertTrue(box.contains(bounds), "\(bounds) not in \(box)")
        XCTAssertEqual(bounds.minX, 200, accuracy: 4, "text starts at the box's left edge")
    }

    func testEmptyTextDrawsNothing() {
        XCTAssertNil(StrokeRenderer.render(textStroke(""), size: CGSize(width: 100, height: 100)))
    }

    func testTextSizeGrowsWithFontSizeAndLength() {
        let small = TextLayout.size(of: "Hi", fontSize: 12), big = TextLayout.size(of: "Hi", fontSize: 24)
        XCTAssertGreaterThan(big.width, small.width)
        XCTAssertEqual(big.height, TextLayout.lineHeight(forFontSize: 24))
        XCTAssertGreaterThan(TextLayout.size(of: "Hello there", fontSize: 12).width, small.width)
    }

    func testFontSizeFollowsTheWidthPreset() {
        XCTAssertEqual(WidthPreset.allCases.map(TextLayout.fontSize(for:)), [12, 24, 44, 72])
    }

    /// The Mac measures the box; every client draws into that box. The glyphs must fill it.
    func testTextFillsTheBoxItWasMeasuredFor() {
        // Descenders (g j p q y) and accents (É) must stay inside the box too.
        for text in ["Hello", "gjpqy", "Égy"] {
            for fontSize in [12, 24, 72] as [CGFloat] {
                assertFills(text, fontSize: fontSize)
            }
        }
    }

    private func assertFills(_ text: String, fontSize: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let s = TextLayout.size(of: text, fontSize: fontSize)
            let b = TextLayout.path(text, in: CGRect(origin: CGPoint(x: 100, y: 100), size: s)).boundingBoxOfPath
            XCTAssertGreaterThanOrEqual(b.minX, 100 - 1, "\(text) \(fontSize)", file: file, line: line)
            XCTAssertLessThanOrEqual(b.maxX, 100 + s.width + 1, "\(text) \(fontSize)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(b.width, 0.8 * s.width, "\(text) \(fontSize)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(b.minY, 100 - 1, "\(text) \(fontSize)", file: file, line: line)
            XCTAssertLessThanOrEqual(b.maxY, 100 + s.height + 1, "\(text) \(fontSize)", file: file, line: line)
        }
    }

    /// The outline is cached at one size and scaled: a box twice as big gives a path twice as big.
    func testTextPathScalesWithTheBox() {
        let a = TextLayout.path("Hi", in: CGRect(x: 0, y: 0, width: 40, height: 30)).boundingBoxOfPath
        let b = TextLayout.path("Hi", in: CGRect(x: 0, y: 0, width: 80, height: 60)).boundingBoxOfPath
        XCTAssertEqual(b.width, a.width * 2, accuracy: 0.01)
        XCTAssertEqual(b.height, a.height * 2, accuracy: 0.01)
    }

    func testEmojiOnlyTextHasNothingToDraw() {
        XCTAssertTrue(TextLayout.path("😀", in: CGRect(x: 0, y: 0, width: 50, height: 30)).isEmpty)
        XCTAssertFalse(TextLayout.isDrawable("😀"))
        XCTAssertFalse(TextLayout.isDrawable("   "))
        XCTAssertTrue(TextLayout.isDrawable("Hi 😀"))
    }

    // MARK: Where typed text lands

    private let view = CGSize(width: 1000, height: 500)
    private let textSize = CGSize(width: 100, height: 30)

    func testBoxIsCentredOnTheFieldAndNormalized() {
        let c = TextLayout.corners(textSize: textSize, fieldFrame: CGRect(x: 200, y: 100, width: 300, height: 34), in: view)
        XCTAssertEqual(c[0].x, 202 / 1000, accuracy: 0.0001) // 2 pt field padding
        XCTAssertEqual(c[0].y, 102 / 500, accuracy: 0.0001)  // (34 - 30) / 2 = 2
        XCTAssertEqual(c[1].x, 302 / 1000, accuracy: 0.0001)
        XCTAssertEqual(c[1].y, 132 / 500, accuracy: 0.0001)
    }

    /// Near an edge the box moves inside the screen instead of being cut, so the text keeps its size.
    func testBoxNearAnEdgeKeepsItsSize() {
        for frame in [CGRect(x: 980, y: -20, width: 120, height: 34), CGRect(x: -5, y: 490, width: 300, height: 34)] {
            let c = TextLayout.corners(textSize: textSize, fieldFrame: frame, in: view)
            XCTAssertEqual(CGFloat(c[1].x - c[0].x) * view.width, textSize.width, accuracy: 0.01, "\(frame)")
            XCTAssertEqual(CGFloat(c[1].y - c[0].y) * view.height, textSize.height, accuracy: 0.01, "\(frame)")
            XCTAssertTrue(c.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
    }

    func testEraserHitsAnywhereInsideTheTextBox() {
        let s = textStroke()
        XCTAssertTrue(Geometry.hitTest(stroke: s, point: StrokePoint(x: 0.3, y: 0.32), radius: 0.001, aspect: 1))
        XCTAssertFalse(Geometry.hitTest(stroke: s, point: StrokePoint(x: 0.6, y: 0.6), radius: 0.001, aspect: 1))
    }

    func testThePhoneDoesNotOfferTheTextTool() {
        XCTAssertFalse(Tool.phoneTools.contains(.text))
        XCTAssertEqual(Tool.phoneTools.count, Tool.allCases.count - 1)
    }
}

final class ToolShortcutTests: XCTestCase {
    /// ⌃⌥1…⌃⌥0 follow the toolbar order, as the user asked ("option 1 for the pencil and so on").
    func testGlobalShortcutsFollowTheToolbarOrder() {
        XCTAssertEqual(Tool.pen.shortcutDigit, 1)
        XCTAssertEqual(Tool.highlighter.shortcutDigit, 2)
        XCTAssertEqual(Tool.rectangle.shortcutDigit, 5)
        XCTAssertEqual(Tool.text.shortcutDigit, 9)
        XCTAssertEqual(Tool.eraser.shortcutDigit, 0)
        XCTAssertEqual(Tool.pen.globalShortcut, "⌃⌥1")
    }

    /// An 11th tool would silently share ⌃⌥1 with the pen: this fails first.
    func testEveryToolHasItsOwnShortcuts() {
        XCTAssertLessThanOrEqual(Tool.allCases.count, 10, "only ten number keys for ⌃⌥1…⌃⌥0")
        XCTAssertEqual(Set(Tool.allCases.map(\.shortcutDigit)).count, Tool.allCases.count)
        XCTAssertEqual(Set(Tool.allCases.map(\.shortcutKey)).count, Tool.allCases.count)
    }
}

/// The fix for the screen that stayed all white: the toolbar always takes the board away.
final class WhiteboardTests: XCTestCase {
    func testBoardShowsAtItsOpacityWhileTheToolbarIsUp() {
        XCTAssertEqual(Whiteboard.visibleOpacity(enabled: true, opacity: 0.8, toolbarVisible: true), 0.8, accuracy: 0.0001)
    }

    func testHidingTheToolbarHidesTheBoard() {
        XCTAssertEqual(Whiteboard.visibleOpacity(enabled: true, opacity: 1, toolbarVisible: false), 0)
    }

    func testBoardOffShowsNothing() {
        XCTAssertEqual(Whiteboard.visibleOpacity(enabled: false, opacity: 1, toolbarVisible: true), 0)
    }
}
