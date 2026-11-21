import CoreGraphics
import CoreText
import Foundation

/// Sizing and outlines for typed text. Text strokes store only a box; the font
/// size follows from the box height, so the text scales with zoom like any stroke.
///
/// Placement (also in docs/protocol.md): font size = box height / 1.25, left edge at
/// the box's left, and the font's full height (ascent + descent) centred in the box:
/// baseline = box top + (box height − (ascent + descent)) / 2 + ascent.
/// Only glyphs with outlines are drawn (not emoji).
public enum TextLayout {
    /// Box height = font size × this (room for ascenders and descenders).
    public static let lineHeightFactor: CGFloat = 1.25

    /// Font size for a width preset: 3, 6, 11, 18 pt lines give 12, 24, 44, 72 pt text.
    public static func fontSize(for width: WidthPreset) -> CGFloat { CGFloat(width.points) * 4 }

    /// Box height for a font size.
    public static func lineHeight(forFontSize fontSize: CGFloat) -> CGFloat { ceil(fontSize * lineHeightFactor) }

    /// The box (in the same units as `fontSize`) that `text` needs, top-left at the origin.
    public static func size(of text: String, fontSize: CGFloat) -> CGSize {
        let width = CTLineGetTypographicBounds(line(text), nil, nil, nil) * fontSize / referenceSize
        return CGSize(width: ceil(width), height: lineHeight(forFontSize: fontSize))
    }

    /// Whether `text` has anything to draw (emoji and spaces have no outlines).
    public static func isDrawable(_ text: String) -> Bool { !unitPath(text).isEmpty }

    /// Normalized [top-left, bottom-right] corners for text of `textSize` typed in a field
    /// at `fieldFrame` (both top-left-origin, in view points). The box is vertically centred
    /// on the field and moved, never shrunk, to stay inside the view.
    public static func corners(textSize: CGSize, fieldFrame: CGRect, in viewSize: CGSize) -> [StrokePoint] {
        let inset: CGFloat = 2 // the text field's own left padding
        var x = fieldFrame.minX + inset
        var y = fieldFrame.minY + (fieldFrame.height - textSize.height) / 2
        x = min(max(x, 0), max(viewSize.width - textSize.width, 0))
        y = min(max(y, 0), max(viewSize.height - textSize.height, 0))
        return [Geometry.normalize(CGPoint(x: x, y: y), in: viewSize),
                Geometry.normalize(CGPoint(x: x + textSize.width, y: y + textSize.height), in: viewSize)]
    }

    /// Glyph outlines of `text` filling `box` (top-left-origin coordinates).
    /// Built once per text at a reference size, then scaled and moved into the box.
    public static func path(_ text: String, in box: CGRect) -> CGPath {
        let scale = box.height / lineHeightFactor / referenceSize
        guard scale > 0 else { return CGMutablePath() }
        var t = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: scale, y: scale)
        return unitPath(text).copy(using: &t) ?? CGMutablePath()
    }

    // MARK: Reference outlines

    private static let referenceSize: CGFloat = 100
    private static let font = CTFontCreateUIFontForLanguage(.system, referenceSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, referenceSize, nil)
    private static let cache = NSCache<NSString, CGPath>()

    /// Outline at the reference size, in a box whose top-left is (0, 0).
    private static func unitPath(_ text: String) -> CGPath {
        if let cached = cache.object(forKey: text as NSString) { return cached }
        let path = CGMutablePath()
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baseline = (referenceSize * lineHeightFactor - (ascent + descent)) / 2 + ascent
        for run in CTLineGetGlyphRuns(line(text)) as? [CTRun] ?? [] {
            addGlyphs(of: run, to: path, baseline: baseline)
        }
        cache.setObject(path, forKey: text as NSString)
        return path
    }

    private static func addGlyphs(of run: CTRun, to path: CGMutablePath, baseline: CGFloat) {
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for i in 0..<count {
            // Glyphs are drawn y-up; flip them into our top-left-origin space.
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: baseline)
            if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) { path.addPath(glyph) }
        }
    }

    private static func line(_ text: String) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        return CTLineCreateWithAttributedString(attributed)
    }
}
