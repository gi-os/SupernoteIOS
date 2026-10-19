import Foundation
import PencilKit

/// Persists pen strokes per note page, in Supernote page coordinates (1404×1872 on Nomad).
///
/// Strokes live in Application Support — *outside* the sync mirror — so they never upload as
/// stray files. Once NoteKit can write `.note` layers, `InkExporter` will merge these into the
/// note's MAINLAYER + TOTALPATH and the file syncs back to the Nomad like any device edit.
struct InkStore {
    let fileURL: URL

    init(noteURL: URL, pageKey: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ink", isDirectory: true)
        // Key by the note's path inside the mirror so renames on the device start a fresh layer.
        let noteKey = noteURL.standardizedFileURL.path
            .components(separatedBy: "/Documents/Supernote/").last ?? noteURL.lastPathComponent
        let safe = noteKey.replacingOccurrences(of: "/", with: "__")
        fileURL = base.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("\(pageKey).drawing")
    }

    func load() -> PKDrawing {
        guard let data = try? Data(contentsOf: fileURL) else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    func save(_ drawing: PKDrawing) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if drawing.strokes.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            try? drawing.dataRepresentation().write(to: fileURL, options: .atomic)
        }
    }
}
