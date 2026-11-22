import BrushKit
import Combine
import SwiftUI
import UIKit

/// Zoomable live view of the Mac display with vector annotations on top.
///
/// Layers, bottom to top: video (or whole-screen stills from the Windows app) → detail still (inside the zoomed content) →
/// strokes (a screen-space view redrawn on every zoom/pan, so strokes stay sharp).
final class CanvasViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let model: RemoteModel
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let videoView = VideoView()
    private let frameView = UIImageView()
    private let detailView = UIImageView()
    private let strokeView = StrokeOverlayView()
    private let placeholder = UILabel()
    private lazy var drawRecognizer = DrawGestureRecognizer(target: self, action: #selector(handleDraw(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    private var cancellables: Set<AnyCancellable> = []
    private var displayLink: CADisplayLink?
    private var pendingPoints: [StrokePoint] = []
    private var pendingErase: [StrokePoint] = []
    private var lastBoundsSize: CGSize = .zero
    private var detailRect: NormRect?

    init(model: RemoteModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.addSubview(scrollView)

        scrollView.addSubview(contentView)
        contentView.addSubview(videoView)
        frameView.contentMode = .scaleToFill
        frameView.isHidden = true
        contentView.addSubview(frameView)
        detailView.contentMode = .scaleToFill
        detailView.isHidden = true
        contentView.addSubview(detailView)

        placeholder.text = "Waiting for the computer’s screen…"
        placeholder.textColor = .secondaryLabel
        placeholder.font = .preferredFont(forTextStyle: .footnote)
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        contentView.addSubview(placeholder)

        strokeView.isUserInteractionEnabled = false
        strokeView.model = model
        strokeView.canvas = self
        view.addSubview(strokeView)

        drawRecognizer.delegate = self
        contentView.addGestureRecognizer(drawRecognizer)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.addGestureRecognizer(doubleTap)

        videoView.onNeedKeyframe = { [weak self] in self?.model.requestKeyframe() }

        model.onVideo = { [weak self] packet in
            self?.frameView.isHidden = true
            self?.videoView.enqueue(packet)
        }
        model.onFrame = { [weak self] packet in self?.showFrame(packet) }
        model.onVideoReset = { [weak self] in self?.videoView.reset() }
        model.onDetail = { [weak self] in self?.showDetail($0) }
        model.onDocumentChanged = { [weak self] in self?.strokeView.setNeedsDisplay() }
        model.onFitRequested = { [weak self] in self?.scrollView.setZoomScale(1, animated: true) }
        model.onDisplayChanged = { [weak self] in
            self?.lastBoundsSize = .zero
            self?.view.setNeedsLayout()
        }
        model.$mode.sink { [weak self] in self?.applyMode($0) }.store(in: &cancellables)
        model.$hasVideo.combineLatest(model.$screenPermission).sink { [weak self] hasVideo, granted in
            self?.placeholder.isHidden = hasVideo
            self?.placeholder.text = granted ? "Waiting for the computer’s screen…"
                : "Screen preview is off: allow Screen Recording for Glasspen Meet on your Mac.\nYou can still draw."
        }.store(in: &cancellables)

        let link = CADisplayLink(target: self, selector: #selector(flush))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        displayLink?.invalidate()
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        strokeView.frame = view.bounds
        guard view.bounds.size != lastBoundsSize else { return }

        // Preserve zoom and the visible center across rotation / display changes.
        let zoom = scrollView.zoomScale
        let center = lastBoundsSize == .zero ? nil : visibleCenterNormalized()
        lastBoundsSize = view.bounds.size

        scrollView.zoomScale = 1
        let fit = Geometry.aspectFit(aspect: CGFloat(model.display.aspect), in: CGRect(origin: .zero, size: view.bounds.size))
        contentView.frame = CGRect(origin: .zero, size: fit.size)
        videoView.frame = contentView.bounds
        frameView.frame = contentView.bounds
        placeholder.frame = contentView.bounds.insetBy(dx: 24, dy: 24)
        layoutDetail()
        scrollView.contentSize = fit.size
        scrollView.zoomScale = zoom
        centerContent()
        if let center { scroll(toNormalizedCenter: center) }
        strokeView.setNeedsDisplay()
    }

    private func centerContent() {
        let b = scrollView.bounds.size
        let c = scrollView.contentSize
        let h = max((b.width - c.width) / 2, 0)
        let v = max((b.height - c.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: v, left: h, bottom: v, right: h)
    }

    private func visibleCenterNormalized() -> CGPoint {
        let center = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
        let p = scrollView.convert(center, to: contentView)
        return CGPoint(x: p.x / max(contentView.bounds.width, 1), y: p.y / max(contentView.bounds.height, 1))
    }

    private func scroll(toNormalizedCenter c: CGPoint) {
        let target = CGPoint(x: c.x * scrollView.contentSize.width - scrollView.bounds.width / 2,
                             y: c.y * scrollView.contentSize.height - scrollView.bounds.height / 2)
        let inset = scrollView.contentInset
        let maxX = max(scrollView.contentSize.width - scrollView.bounds.width + inset.right, -inset.left)
        let maxY = max(scrollView.contentSize.height - scrollView.bounds.height + inset.bottom, -inset.top)
        scrollView.contentOffset = CGPoint(x: min(max(target.x, -inset.left), maxX), y: min(max(target.y, -inset.top), maxY))
    }

    /// Display-normalized rect → frame in the stroke view (screen space).
    func contentFrameInStrokeView() -> CGRect {
        contentView.convert(contentView.bounds, to: strokeView)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        strokeView.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        strokeView.setNeedsDisplay()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { reportViewport() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportViewport() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportViewport() }
    }

    /// Asks the Mac for a sharp still of the visible region once zoom settles at ≥2×.
    private func reportViewport() {
        guard scrollView.zoomScale >= 2 else {
            showDetail(nil)
            model.sendViewport(nil, pixels: .zero)
            return
        }
        let visible = scrollView.convert(scrollView.bounds, to: contentView).intersection(contentView.bounds)
        guard !visible.isNull, contentView.bounds.width > 0 else { return }
        let norm = CGRect(x: visible.minX / contentView.bounds.width, y: visible.minY / contentView.bounds.height,
                          width: visible.width / contentView.bounds.width, height: visible.height / contentView.bounds.height)
        let scale = view.window?.screen.scale ?? 3
        let pixels = CGSize(width: visible.width * scrollView.zoomScale * scale, height: visible.height * scrollView.zoomScale * scale)
        model.sendViewport(norm, pixels: pixels)
    }

    private func showFrame(_ packet: DetailPacket) {
        guard let image = UIImage(data: packet.jpeg) else { return }
        frameView.image = image
        frameView.isHidden = false
    }

    private func showDetail(_ packet: DetailPacket?) {
        guard let packet, scrollView.zoomScale >= 2, let image = UIImage(data: packet.jpeg) else {
            detailView.isHidden = true
            detailView.image = nil
            detailRect = nil
            return
        }
        detailRect = packet.rect
        detailView.image = image
        layoutDetail()
        detailView.isHidden = false
    }

    private func layoutDetail() {
        guard let r = detailRect else { return }
        let b = contentView.bounds
        detailView.frame = CGRect(x: CGFloat(r.x) * b.width, y: CGFloat(r.y) * b.height,
                                  width: CGFloat(r.w) * b.width, height: CGFloat(r.h) * b.height)
    }

    // MARK: Modes & gestures

    private func applyMode(_ mode: CanvasMode) {
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        switch mode {
        case .navigate:
            // Fingers navigate; Apple Pencil always draws.
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
            drawRecognizer.allowedTouchTypes = [pencil]
            doubleTap.isEnabled = true
        case .paint:
            // One finger draws; two fingers pinch/pan.
            scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
            drawRecognizer.allowedTouchTypes = [finger, pencil]
            doubleTap.isEnabled = false
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            // Zoom to 3× around the tapped point (rect is in unzoomed content coordinates).
            let p = g.location(in: contentView)
            let w = scrollView.bounds.width / 3, h = scrollView.bounds.height / 3
            scrollView.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Drawing coexists with the scroll view's pinch/pan so a second finger can take over.
        g === drawRecognizer
    }

    private func normalized(_ touch: UITouch, coalesced: UITouch? = nil) -> StrokePoint {
        let t = coalesced ?? touch
        let p = t.location(in: contentView)
        var pressure: CGFloat = 1
        if t.type == .pencil, t.maximumPossibleForce > 0 {
            pressure = min(max(t.force / t.maximumPossibleForce, 0.05), 1)
        }
        return Geometry.normalize(p, in: contentView.bounds.size, pressure: pressure)
    }

    @objc private func handleDraw(_ g: DrawGestureRecognizer) {
        guard let touch = g.trackedTouch else {
            if g.state == .cancelled || g.state == .failed { model.cancelLocalStroke(); pendingPoints.removeAll() }
            return
        }
        let state = model.toolState
        switch g.state {
        case .began:
            let p = normalized(touch)
            if state.tool == .eraser {
                pendingErase = [p]
                return
            }
            let stroke = Stroke(sourceID: model.sourceID, tool: state.tool, color: state.color,
                                width: state.width.normalized(displayWidth: model.display.width), points: [p])
            pendingPoints.removeAll()
            model.beginLocalStroke(stroke)
        case .changed:
            let samples = (g.lastEvent?.coalescedTouches(for: touch) ?? [touch]).map { normalized(touch, coalesced: $0) }
            if state.tool == .eraser {
                pendingErase.append(contentsOf: samples)
                return
            }
            model.appendLocal(points: samples, send: false)
            pendingPoints.append(contentsOf: samples)
            strokeView.predicted = (g.lastEvent?.predictedTouches(for: touch) ?? []).map { normalized(touch, coalesced: $0) }
            strokeView.setNeedsDisplay()
        case .ended:
            if state.tool == .eraser { flush(); return }
            flush()
            strokeView.predicted = []
            model.endLocalStroke()
        case .cancelled, .failed:
            pendingPoints.removeAll()
            pendingErase.removeAll()
            strokeView.predicted = []
            model.cancelLocalStroke()
        default: break
        }
    }

    /// Sends batched points once per display refresh.
    @objc private func flush() {
        if !pendingPoints.isEmpty, let s = model.localStroke {
            let pts = pendingPoints
            pendingPoints.removeAll()
            model.sendAppend(id: s.id, points: pts)
        }
        if !pendingErase.isEmpty {
            model.erase(points: pendingErase)
            pendingErase.removeAll()
        }
    }
}

/// Draws all strokes in screen space, mapped through the scroll view's current zoom/pan.
final class StrokeOverlayView: UIView {
    weak var model: RemoteModel?
    weak var canvas: CanvasViewController?
    var predicted: [StrokePoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let model, let canvas, let ctx = UIGraphicsGetCurrentContext() else { return }
        let frame = canvas.contentFrameInStrokeView()
        guard frame.width > 0 else { return }
        let transform = CGAffineTransform(translationX: frame.minX, y: frame.minY)
        ctx.clip(to: frame)
        for s in model.mirror.orderedStrokes {
            StrokeRenderer.draw(s, in: ctx, size: frame.size, transform: transform)
        }
        for s in model.mirror.live.values {
            StrokeRenderer.draw(s, in: ctx, size: frame.size, transform: transform)
        }
        if var local = model.localStroke {
            if !predicted.isEmpty, !local.tool.isShape { local.points.append(contentsOf: predicted) }
            if model.mirror.committed[local.id] == nil {
                StrokeRenderer.draw(local, in: ctx, size: frame.size, transform: transform)
            }
        }
    }
}

/// Tracks exactly one touch for drawing. A second touch cancels the stroke so
/// the scroll view's pinch/pan can take over.
final class DrawGestureRecognizer: UIGestureRecognizer {
    private(set) var trackedTouch: UITouch?
    private(set) var lastEvent: UIEvent?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        lastEvent = event
        if trackedTouch != nil || touches.count > 1 || (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 {
            state = (state == .began || state == .changed) ? .cancelled : .failed
            return
        }
        trackedTouch = touches.first
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        lastEvent = event
        guard let t = trackedTouch, touches.contains(t) else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lastEvent = event
        guard let t = trackedTouch, touches.contains(t) else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lastEvent = event
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        lastEvent = nil
    }
}

struct CanvasView: UIViewControllerRepresentable {
    let model: RemoteModel
    func makeUIViewController(context: Context) -> CanvasViewController { CanvasViewController(model: model) }
    func updateUIViewController(_ controller: CanvasViewController, context: Context) {}
}
