import CoreGraphics
import Foundation
import NoteKit
import Observation

/// Everything the Nomad-style editor needs for one open `.note`: pages, tools, undo, saving.
@MainActor @Observable
final class NoteSession {
    enum Tool: Equatable {
        case pen(PenType)
        case eraser
        case regionEraser
        case lasso
    }

    struct PenSettings: Equatable {
        var widthMM: Double
        var color: InkColor
    }

    let url: URL
    private(set) var note: NoteFile
    private(set) var pageIndex = 0
    private(set) var pageImage: CGImage?
    private(set) var readOnlyReason: String?
    private(set) var selection: Set<Int> = []
    private(set) var selectionBounds: CGRect?
    private(set) var hasUnsavedChanges = false
    /// Bumped on every edit (drives autosave debounce).
    private(set) var revision = 0
    var error: String?

    var tool: Tool = .pen(.needlePoint) { didSet { if tool != .lasso { clearSelection() } } }
    var pens: [PenType: PenSettings] = [
        .needlePoint: .init(widthMM: 0.4, color: .black),
        .inkPen: .init(widthMM: 0.5, color: .black),
        .marker: .init(widthMM: 1.5, color: .lightGray),
    ]
    var eraserRadiusMM: Double = 1.0

    private var editors: [Int: PageEditor] = [:]
    /// The file as opened (or as of the last page insert). Every save re-applies all touched
    /// pages on top of this, so autosaves don't stack appended copies.
    private var base: NoteFile
    private var touched: Set<Int> = []
    private var backedUp = false

    var pageCount: Int { note.pages.count }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var pageSize: CGSize { CGSize(width: note.pageSize.width, height: note.pageSize.height) }
    var canUndo: Bool { currentEditor?.canUndo ?? false }
    var canRedo: Bool { currentEditor?.canRedo ?? false }
    var currentPen: PenSettings? { if case let .pen(p) = tool { pens[p] } else { nil } }

    init(url: URL) throws {
        self.url = url
        note = try NoteFile(contentsOf: url)
        base = note
        if let last = Int(note.header["FINALOPERATION_PAGE"] ?? ""), last >= 1, last <= note.pages.count {
            pageIndex = last - 1
        }
        loadPage()
    }

    // MARK: Pages

    private var currentEditor: PageEditor? { editors[pageIndex] }

    private func loadPage() {
        readOnlyReason = nil
        clearSelection()
        if editors[pageIndex] == nil {
            do { editors[pageIndex] = try PageEditor(note: note, index: pageIndex) }
            catch NoteWriter.WriteError.landscapeNotSupported { readOnlyReason = "Landscape pages are view-only for now" }
            catch { readOnlyReason = "This page can't be edited: \(error)" }
        }
        refreshImage()
    }

    private func refreshImage() {
        if let editor = currentEditor {
            pageImage = editor.render().cgImage
        } else {
            pageImage = (try? NoteRenderer.render(note, page: pageIndex))?.cgImage
        }
    }

    func go(to index: Int) {
        guard index >= 0, index < pageCount, index != pageIndex else { return }
        pageIndex = index
        loadPage()
    }

    func nextPage() { go(to: pageIndex + 1) }
    func previousPage() { go(to: pageIndex - 1) }

    func thumbnail(for index: Int, width: Int = 180) -> CGImage? {
        let img: GrayImage?
        if let e = editors[index] { img = e.render() } else { img = try? NoteRenderer.render(note, page: index) }
        return img?.cgImage?.scaled(toWidth: width)
    }

    // MARK: Pen / eraser / lasso

    func commitStroke(points: [PagePoint], pressures: [UInt16]) {
        guard case let .pen(pen) = tool, let editor = currentEditor, let s = pens[pen] else { return }
        editor.addStroke(points: points, pressures: pressures, pen: pen, color: s.color, widthMM: s.widthMM)
        changed()
    }

    func erase(along points: [PagePoint]) {
        guard let editor = currentEditor else { return }
        if editor.eraseStrokes(along: points, radius: eraserRadiusMM * StrokeCodec.pixelsPerMM) > 0 { changed() }
    }

    func regionErase(polygon: [PagePoint]) {
        guard let editor = currentEditor else { return }
        let hit = editor.select(lasso: polygon)
        guard !hit.isEmpty else { return }
        editor.delete(hit)
        changed()
    }

    func eraseAll() {
        currentEditor?.eraseAll()
        changed()
    }

    func lasso(polygon: [PagePoint]) {
        guard let editor = currentEditor else { return }
        selection = editor.select(lasso: polygon)
        updateSelectionBounds()
    }

    func moveSelection(dx: Double, dy: Double) {
        guard let editor = currentEditor, !selection.isEmpty else { return }
        editor.move(selection, dx: dx, dy: dy)
        updateSelectionBounds()
        changed()
    }

    func deleteSelection() {
        guard let editor = currentEditor, !selection.isEmpty else { return }
        editor.delete(selection)
        clearSelection()
        changed()
    }

    func clearSelection() {
        selection = []
        selectionBounds = nil
    }

    private func updateSelectionBounds() {
        guard let b = currentEditor?.bounds(of: selection) else { selectionBounds = nil; return }
        selectionBounds = CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY).insetBy(dx: -6, dy: -6)
    }

    func undo() { currentEditor?.undo(); clearSelection(); changed() }
    func redo() { currentEditor?.redo(); clearSelection(); changed() }

    private func changed() {
        touched.insert(pageIndex)
        revision += 1
        hasUnsavedChanges = editors.values.contains { $0.isDirty }
        refreshImage()
    }

    // MARK: Saving

    /// Writes dirty pages (and optionally new pages) back to the `.note`, keeping a backup of the
    /// previous version. Returns true if the file changed on disk.
    @discardableResult
    func save(appendingPages newPages: Int = 0) -> Bool {
        let dirty = editors.filter { $0.value.isDirty }
        guard !dirty.isEmpty || newPages > 0 else { return false }
        do {
            var edits: [Int: NoteWriter.PageEdit] = [:]
            for i in touched { if let e = editors[i] { edits[i] = e.makeEdit() } }
            let data = newPages > 0
                ? try NoteWriter.appendPages(base, count: newPages, edits: edits)
                : try NoteWriter.write(base, edits: edits)
            if !backedUp { try Backups.keep(url); backedUp = true }   // pre-session version
            try data.write(to: url, options: .atomic)
            note = try NoteFile(data: data)
            if newPages > 0 { base = note; touched = [] }
            dirty.values.forEach { $0.markSaved() }
            hasUnsavedChanges = false
            return true
        } catch {
            self.error = "Couldn't save: \(error)"
            return false
        }
    }

    func addPage() {
        guard save(appendingPages: 1) else { return }
        // Editors hold page models, not file offsets, so they stay valid across the rewrite.
        go(to: pageCount - 1)
    }

    // MARK: Export

    func exportPNG() -> URL? {
        guard let image = pageImage else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(title)_\(pageIndex + 1).png")
        return image.writePNG(to: out) ? out : nil
    }
}

/// Keeps the last few versions of every note we overwrite (Application Support/Backups).
enum Backups {
    static let keepPerFile = 5

    static func keep(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent
        try fm.copyItem(at: url, to: dir.appendingPathComponent("\(name).\(stamp).note"))
        let old = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix(name + ".") }.sorted().dropLast(keepPerFile) ?? []
        for f in old { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
    }
}
