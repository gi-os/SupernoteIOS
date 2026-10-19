import PencilKit
import SwiftUI

/// Transparent PencilKit layer sized to the on-screen page.
/// Drawings are stored in page coordinates and scaled to the view, so strokes stay put
/// across iPhone / iPad mini / rotation and map 1:1 onto Supernote pixels for write-back.
struct InkCanvas: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let store: InkStore
    let pageSize: CGSize
    let isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(store: store, pageSize: pageSize) }

    func makeUIView(context: Context) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.onLayout = { [weak coordinator = context.coordinator] size in coordinator?.applyViewSize(size) }
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // Supernote-ish default: fine black ink.
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        let c = context.coordinator
        canvas.drawingPolicy = model.pencilOnly ? .pencilOnly : .anyInput
        canvas.isUserInteractionEnabled = isActive

        DispatchQueue.main.async {
            c.toolPicker.setVisible(isActive, forFirstResponder: canvas)
            c.toolPicker.addObserver(canvas)
            if isActive { canvas.becomeFirstResponder() } else { canvas.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ canvas: PageCanvasView, coordinator: Coordinator) {
        coordinator.persist()
    }

    /// Reports size changes (rotation, split view) so page-space ink can be rescaled.
    final class PageCanvasView: PKCanvasView {
        var onLayout: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let store: InkStore
        let pageSize: CGSize
        let toolPicker = PKToolPicker()
        weak var canvas: PKCanvasView?
        private var viewSize: CGSize = .zero
        private var pageDrawing: PKDrawing
        private var applying = false

        init(store: InkStore, pageSize: CGSize) {
            self.store = store
            self.pageSize = pageSize
            self.pageDrawing = store.load()
        }

        private var viewToPage: CGAffineTransform {
            guard viewSize.width > 0 else { return .identity }
            let s = pageSize.width / viewSize.width
            return CGAffineTransform(scaleX: s, y: s)
        }

        func applyViewSize(_ size: CGSize) {
            guard let canvas, size != viewSize, size.width > 0 else { return }
            viewSize = size
            applying = true
            canvas.drawing = pageDrawing.transformed(using: viewToPage.inverted())
            applying = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying, viewSize.width > 0 else { return }
            pageDrawing = canvasView.drawing.transformed(using: viewToPage)
            store.save(pageDrawing)
        }

        func persist() { store.save(pageDrawing) }
    }
}
