import NoteKit
import SwiftUI

/// Page-at-a-time `.note` viewer, like flipping pages on the Nomad. Pen layer on top when enabled.
struct NoteView: View {
    @Environment(AppModel.self) private var model
    let url: URL

    @State private var note: NoteFile?
    @State private var error: String?
    @State private var page = 0
    @State private var penMode = false

    var body: some View {
        Group {
            if let note {
                TabView(selection: $page) {
                    ForEach(note.pages.indices, id: \.self) { i in
                        NotePageView(note: note, index: i, noteURL: url, penMode: penMode && model.penEnabled)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(Color(white: 0.92))
            } else if let error {
                ContentUnavailableView("Can't open note", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let note {
                ToolbarItem(placement: .status) { Text("\(page + 1) / \(note.pages.count)").monospacedDigit() }
            }
            if model.penEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $penMode) { Image(systemName: "pencil.tip") }
                        .toggleStyle(.button)
                        .accessibilityLabel("Pen")
                }
            }
        }
        .task(id: url) {
            do { note = try await Task.detached(priority: .userInitiated) { try NoteFile(contentsOf: url) }.value }
            catch { self.error = "\(error)" }
        }
    }
}

struct NotePageView: View {
    let note: NoteFile
    let index: Int
    let noteURL: URL
    let penMode: Bool

    @State private var image: CGImage?

    var body: some View {
        let page = note.pages[index]
        var (w, h) = note.pageSize
        if page.isHorizontal { swap(&w, &h) }
        let pageSize = CGSize(width: w, height: h)

        return GeometryReader { geo in
            let scale = min(geo.size.width / pageSize.width, geo.size.height / pageSize.height)
            let shown = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            ZStack {
                Color.white
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                } else {
                    ProgressView()
                }
                InkCanvas(store: InkStore(noteURL: noteURL, pageKey: page.pageID ?? "p\(index)"),
                          pageSize: pageSize, isActive: penMode)
                    .allowsHitTesting(penMode)
            }
            .frame(width: shown.width, height: shown.height)
            .shadow(radius: 2)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .task(id: index) {
            image = await Task.detached(priority: .userInitiated) {
                try? NoteRenderer.render(note, page: index).cgImage
            }.value
        }
    }
}
