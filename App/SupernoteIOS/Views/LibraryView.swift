import SwiftUI

/// Browses the local mirror (Note/, Document/, EXPORT/, …) just like the Supernote file manager.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @Binding var selection: URL?
    @State private var items: [(url: URL, isDir: Bool)] = []

    var body: some View {
        List(selection: $selection) {
            ForEach(items, id: \.url) { item in
                let url = item.url
                if item.isDir {
                    NavigationLink {
                        LibraryView(folder: url, selection: $selection)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder")
                    }
                } else {
                    Label(url.lastPathComponent, systemImage: icon(for: url)).tag(url as URL?)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Empty", systemImage: "tray", description: Text("Pull to sync."))
            }
        }
        .navigationTitle(folder == model.mirrorRoot ? "Supernote" : folder.lastPathComponent)
        .refreshable { await model.sync() }
        .task(id: model.revision) { reload() }
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        items = urls
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 }
                return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
            }
            .map { (url: $0.0, isDir: $0.1) }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "note": "pencil.and.scribble"
        case "pdf": "doc.richtext"
        case "epub": "book"
        case "png", "jpg", "jpeg": "photo"
        case "mark": "highlighter"
        default: "doc"
        }
    }
}
