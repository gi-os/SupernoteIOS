import NoteKit
import SwiftUI
import UIKit

/// The page surface. Owns Pencil input and draws live ink until the stroke is committed
/// to the `.note` model (then the page image is replaced by the re-rendered layer).
final class PageCanvasView: UIView {
    struct Callbacks {
        var stroke: ([PagePoint], [UInt16]) -> Void = { _, _ in }
        var erase: ([PagePoint]) -> Void = { _ in }
        var regionErase: ([PagePoint]) -> Void = { _ in }
        var lasso: ([PagePoint]) -> Void = { _ in }
        var moveSelection: (Double, Double) -> Void = { _, _ in }
        var clearSelection: () -> Void = {}
        var nextPage: () -> Void = {}
        var previousPage: () -> Void = {}
        var toggleToolbar: () -> Void = {}
    }

    var callbacks = Callbacks()
    var pageSize = CGSize(width: 1404, height: 1872)
    var tool: NoteSession.Tool = .pen(.needlePoint)
    var penWidthPx: Double = 4.7
    var penGray: CGFloat = 0
    var eraserRadiusPx: Double = 12
    var pencilOnly = true { didSet { swipeLeft.isEnabled = pencilOnly; swipeRight.isEnabled = pencilOnly } }
    var isEditable = true

    var image: CGImage? {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.contents = image
            liveLayer.path = nil
            CATransaction.commit()
        }
    }

    var selection: CGRect? { didSet { layoutSelection() } }

    private let imageLayer = CALayer()
    private let liveLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let swipeLeft = UISwipeGestureRecognizer()
    private let swipeRight = UISwipeGestureRecognizer()

    private var activeTouch: UITouch?
    private var points: [PagePoint] = []
    private var pressures: [UInt16] = []
    private var dragStart: CGPoint?
    private var dragOffset = CGSize.zero

    private var scale: CGFloat { bounds.width / pageSize.width }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isMultipleTouchEnabled = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)

        for l in [liveLayer, lassoLayer, selectionLayer] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        lassoLayer.strokeColor = UIColor.black.cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        selectionLayer.strokeColor = UIColor.black.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [4, 4]

        // One-finger swipe page turning (fingers only; the Pencil always writes).
        swipeLeft.direction = .left
        swipeRight.direction = .right
        for s in [swipeLeft, swipeRight] {
            s.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            s.addTarget(self, action: #selector(swiped(_:)))
            addGestureRecognizer(s)
        }
        // Two-finger double tap: show / hide toolbar (device gesture).
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(twoFingerDoubleTap))
        twoFinger.numberOfTouchesRequired = 2
        twoFinger.numberOfTapsRequired = 2
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(twoFinger)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        liveLayer.frame = bounds
        lassoLayer.frame = bounds
        selectionLayer.frame = bounds
        CATransaction.commit()
        layoutSelection()
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        g.direction == .left ? callbacks.nextPage() : callbacks.previousPage()
    }

    @objc private func twoFingerDoubleTap() { callbacks.toggleToolbar() }

    // MARK: Coordinates

    private func pagePoint(_ p: CGPoint) -> PagePoint {
        PagePoint(x: Double(p.x / scale), y: Double(p.y / scale))
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    // MARK: Touches

    private func accepts(_ t: UITouch) -> Bool {
        isEditable && (!pencilOnly || t.type == .pencil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let t = touches.first(where: accepts) else { return }
        activeTouch = t
        points = []; pressures = []
        let loc = t.location(in: self)

        if tool == .lasso, let sel = selection, viewRect(sel).contains(loc) {
            dragStart = loc
            dragOffset = .zero
            return
        }
        if tool == .lasso { callbacks.clearSelection() }
        append(t, event: event)
        updateLive()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        if let start = dragStart {
            let loc = t.location(in: self)
            dragOffset = CGSize(width: loc.x - start.x, height: loc.y - start.y)
            layoutSelection()
            return
        }
        append(t, event: event)
        updateLive()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        if dragStart != nil {
            dragStart = nil
            let d = dragOffset
            dragOffset = .zero
            callbacks.moveSelection(Double(d.width / scale), Double(d.height / scale))
            return
        }
        append(t, event: event)
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        dragStart = nil; dragOffset = .zero
        points = []; pressures = []
        liveLayer.path = nil; lassoLayer.path = nil
        layoutSelection()
    }

    private func append(_ t: UITouch, event: UIEvent?) {
        let samples = event?.coalescedTouches(for: t) ?? [t]
        for s in samples {
            let p = pagePoint(s.preciseLocation(in: self))
            if let last = points.last, abs(last.x - p.x) < 0.3, abs(last.y - p.y) < 0.3 { continue }
            points.append(p)
            let force = s.type == .pencil && s.maximumPossibleForce > 0 ? s.force / s.maximumPossibleForce : 0.5
            pressures.append(UInt16(max(1, min(4095, force * 4095))))
        }
    }

    private func viewPath(closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let f = points.first else { return path }
        path.move(to: CGPoint(x: f.x * scale, y: f.y * scale))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
        if points.count == 1 { path.addLine(to: CGPoint(x: f.x * scale + 0.1, y: f.y * scale)) }
        if closed { path.closeSubpath() }
        return path
    }

    private func updateLive() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch tool {
        case .pen:
            liveLayer.strokeColor = UIColor(white: penGray, alpha: 1).cgColor
            liveLayer.lineWidth = max(1, penWidthPx * scale)
            liveLayer.lineDashPattern = nil
            liveLayer.path = viewPath(closed: false)
        case .eraser:
            liveLayer.strokeColor = UIColor(white: 0.75, alpha: 1).cgColor
            liveLayer.lineWidth = max(2, eraserRadiusPx * 2 * scale)
            liveLayer.lineDashPattern = nil
            liveLayer.path = viewPath(closed: false)
        case .lasso, .regionEraser:
            lassoLayer.path = viewPath(closed: false)
        }
        CATransaction.commit()
    }

    private func finish() {
        let pts = points, prs = pressures
        points = []; pressures = []
        lassoLayer.path = nil
        guard !pts.isEmpty else { liveLayer.path = nil; return }
        switch tool {
        case .pen: callbacks.stroke(pts, prs)          // live path is cleared when the new image lands
        case .eraser: liveLayer.path = nil; callbacks.erase(pts)
        case .regionEraser: callbacks.regionErase(pts)
        case .lasso: callbacks.lasso(pts)
        }
    }

    private func layoutSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let sel = selection {
            let r = viewRect(sel).offsetBy(dx: dragOffset.width, dy: dragOffset.height)
            selectionLayer.path = CGPath(rect: r, transform: nil)
        } else {
            selectionLayer.path = nil
        }
        CATransaction.commit()
    }
}

struct PageCanvas: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let session: NoteSession
    @Binding var toolbarHidden: Bool

    func makeUIView(context: Context) -> PageCanvasView { PageCanvasView() }

    func updateUIView(_ v: PageCanvasView, context: Context) {
        v.pageSize = session.pageSize
        if v.image !== session.pageImage { v.image = session.pageImage }
        v.tool = session.tool
        v.isEditable = session.readOnlyReason == nil
        v.pencilOnly = model.pencilOnly
        if let pen = session.currentPen {
            v.penWidthPx = pen.widthMM * StrokeCodec.pixelsPerMM
            v.penGray = CGFloat(pen.color == .black ? 0 : Double(pen.color.rawValue) / 255)
        }
        v.eraserRadiusPx = session.eraserRadiusMM * StrokeCodec.pixelsPerMM
        v.selection = session.selectionBounds
        v.callbacks = .init(
            stroke: { session.commitStroke(points: $0, pressures: $1) },
            erase: { session.erase(along: $0) },
            regionErase: { session.regionErase(polygon: $0) },
            lasso: { session.lasso(polygon: $0) },
            moveSelection: { session.moveSelection(dx: $0, dy: $1) },
            clearSelection: { session.clearSelection() },
            nextPage: { session.nextPage() },
            previousPage: { session.previousPage() },
            toggleToolbar: { toolbarHidden.toggle() }
        )
    }
}
