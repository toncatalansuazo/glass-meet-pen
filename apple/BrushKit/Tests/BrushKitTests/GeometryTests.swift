import XCTest
@testable import BrushKit

final class GeometryTests: XCTestCase {
    func testNormalizeRoundTrip() {
        let size = CGSize(width: 1512, height: 982)
        let p = CGPoint(x: 300, y: 700)
        let n = Geometry.normalize(p, in: size)
        let back = Geometry.denormalize(n, in: size)
        XCTAssertEqual(back.x, p.x, accuracy: 0.01)
        XCTAssertEqual(back.y, p.y, accuracy: 0.01)
    }

    func testNormalizeClampsToDisplay() {
        let n = Geometry.normalize(CGPoint(x: -10, y: 5000), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(n.x, 0)
        XCTAssertEqual(n.y, 1)
    }

    /// The 6× precision scenario: a phone view of a 1512×982 display, zoomed 6× onto a
    /// 20 pt icon. A touch on the icon's center in the zoomed content must map to the icon's
    /// desktop position, and the preset width must be the same desktop width as from the mouse.
    func testZoomedTouchMapsToDesktopPosition() {
        let display = CGSize(width: 1512, height: 982)
        let icon = CGPoint(x: 1200, y: 64) // desktop point
        // Phone content view (unzoomed) is the display aspect-fitted into a 390-wide view.
        let content = CGSize(width: 390, height: 390 / display.width * display.height)
        // UIScrollView gives touch locations in the content view's own (unzoomed) space,
        // regardless of zoom; at 6× a finger move of 6 pt equals 1 pt of content.
        let zoom: CGFloat = 6
        let touchInContent = CGPoint(x: icon.x / display.width * content.width,
                                     y: icon.y / display.height * content.height)
        let n = Geometry.normalize(touchInContent, in: content)
        let desktop = Geometry.denormalize(n, in: display)
        XCTAssertEqual(desktop.x, icon.x, accuracy: 0.5)
        XCTAssertEqual(desktop.y, icon.y, accuracy: 0.5)

        // A 10 pt circle radius drawn at 6× is 10/6 content pt per screen... the mapped
        // radius on the desktop must still be 10 desktop pt.
        let radiusOnPhoneScreen: CGFloat = 10 * content.width / display.width * zoom
        let radiusInContent = radiusOnPhoneScreen / zoom
        let edge = Geometry.denormalize(Geometry.normalize(CGPoint(x: touchInContent.x + radiusInContent, y: touchInContent.y), in: content), in: display)
        XCTAssertEqual(edge.x - desktop.x, 10, accuracy: 0.5)

        // Width presets are desktop-relative: identical normalized width at any zoom.
        let w = WidthPreset.medium.normalized(displayWidth: Float(display.width))
        XCTAssertEqual(Geometry.viewWidth(w, viewWidth: display.width), CGFloat(WidthPreset.medium.points), accuracy: 0.001)
    }

    func testAspectFitLetterbox() {
        let r = Geometry.aspectFit(aspect: 16.0 / 9.0, in: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(r.width, 390, accuracy: 0.01)
        XCTAssertEqual(r.height, 390 * 9 / 16, accuracy: 0.01)
        XCTAssertEqual(r.midY, 422, accuracy: 0.01)
    }

    func testConstrainRectangleToSquareInPixels() {
        let aspect: Float = 16.0 / 9.0
        let end = Geometry.constrain(tool: .rectangle, start: StrokePoint(x: 0.1, y: 0.1),
                                     end: StrokePoint(x: 0.3, y: 0.2), aspect: aspect)
        let wPx = (end.x - 0.1) * 1600, hPx = (end.y - 0.1) * 900
        XCTAssertEqual(wPx, hPx, accuracy: 0.5)
    }

    func testConstrainLineSnapsTo45Degrees() {
        let end = Geometry.constrain(tool: .line, start: StrokePoint(x: 0.5, y: 0.5),
                                     end: StrokePoint(x: 0.7, y: 0.52), aspect: 1)
        XCTAssertEqual(end.y, 0.5, accuracy: 0.0001)
    }

    func testArrowheadIsBehindTip() {
        let (a, b) = Geometry.arrowhead(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), lineWidth: 4)
        XCTAssertLessThan(a.x, 100)
        XCTAssertLessThan(b.x, 100)
        XCTAssertEqual(a.y, -b.y, accuracy: 0.001)
        XCTAssertEqual(hypot(100 - a.x, a.y), 16, accuracy: 0.001)
    }

    func testHitTestRectangleOutlineOnly() {
        let rect = Stroke(sourceID: .mouse, tool: .rectangle, color: RGBAColor.palette[0], width: 0.002,
                          points: [StrokePoint(x: 0.2, y: 0.2), StrokePoint(x: 0.8, y: 0.8)])
        XCTAssertTrue(Geometry.hitTest(stroke: rect, point: StrokePoint(x: 0.2, y: 0.5), radius: 0.005, aspect: 1))
        XCTAssertFalse(Geometry.hitTest(stroke: rect, point: StrokePoint(x: 0.5, y: 0.5), radius: 0.005, aspect: 1))
    }

    func testConstrainKeepsFigureProportions() {
        // 2:1 display; a drag 0.1 wide and 0.05 tall is bounded by its height: 0.5 high → 0.275 wide in height units.
        let end = Geometry.constrain(tool: .person, start: StrokePoint(x: 0.1, y: 0.1),
                                     end: StrokePoint(x: 0.2, y: 0.6), aspect: 2)
        XCTAssertEqual(end.y, 0.6, accuracy: 0.0001)
        XCTAssertEqual((end.x - 0.1) * 2 / (end.y - 0.1), 0.55, accuracy: 0.0001)
    }

    func testHitTestFigureInsideBox() {
        let phone = Stroke(sourceID: .mouse, tool: .phone, color: RGBAColor.palette[0], width: 0.002,
                           points: [StrokePoint(x: 0.2, y: 0.2), StrokePoint(x: 0.4, y: 0.6)])
        XCTAssertTrue(Geometry.hitTest(stroke: phone, point: StrokePoint(x: 0.3, y: 0.4), radius: 0.005, aspect: 1))
        XCTAssertFalse(Geometry.hitTest(stroke: phone, point: StrokePoint(x: 0.6, y: 0.4), radius: 0.005, aspect: 1))
    }

    func testRendererProducesPaths() {
        let size = CGSize(width: 1000, height: 600)
        for tool in Tool.allCases {
            let s = Stroke(sourceID: .mouse, tool: tool, color: RGBAColor.palette[1], width: 0.005,
                           points: [StrokePoint(x: 0.1, y: 0.1, p: 0.2), StrokePoint(x: 0.3, y: 0.2, p: 0.9), StrokePoint(x: 0.5, y: 0.5, p: 0.5)],
                           text: tool.isText ? "Hi" : nil)
            let r = StrokeRenderer.render(s, size: size)
            XCTAssertNotNil(r, "\(tool)")
            XCTAssertFalse(r!.path.isEmpty, "\(tool)")
        }
        // Highlighter is translucent.
        let h = Stroke(sourceID: .mouse, tool: .highlighter, color: RGBAColor.palette[2], width: 0.005,
                       points: [StrokePoint(x: 0.1, y: 0.1)])
        XCTAssertLessThan(StrokeRenderer.render(h, size: size)!.alpha, 0.5)
    }

    func testRendererScalesWidthWithTransform() {
        let s = Stroke(sourceID: .mouse, tool: .line, color: RGBAColor.palette[0], width: 0.01,
                       points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 1, y: 1)])
        let r1 = StrokeRenderer.render(s, size: CGSize(width: 100, height: 100))!
        let r6 = StrokeRenderer.render(s, size: CGSize(width: 100, height: 100), transform: CGAffineTransform(scaleX: 6, y: 6))!
        guard case .stroke(let w1) = r1.mode, case .stroke(let w6) = r6.mode else { return XCTFail() }
        XCTAssertEqual(w6 / w1, 6, accuracy: 0.001)
    }
}
