import PDFKit
import QuickLook
import SwiftUI

/// Viewer for non-note files (notes open in `NoteEditorView`).
struct DocumentView: View {
    let url: URL

    var body: some View {
        switch url.pathExtension.lowercased() {
        case "pdf": PDFViewer(url: url).ignoresSafeArea(edges: .bottom).navigationTitle(url.lastPathComponent)
        default: QuickLookViewer(url: url).navigationTitle(url.lastPathComponent)
        }
    }
}

struct PDFViewer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}

struct QuickLookViewer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
