import NoteKit
import SwiftUI

/// Nomad-style "Files": e-ink grid of folders and note thumbnails over the local sync mirror.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let folder: URL

    @State private var items: [Item] = []
    @State private var openSession: NoteSession?
    @State private var showSettings = false
    @State private var showNewNote = false
    @State private var error: String?

    struct Item: Identifiable, Hashable {
        let url: URL
        let isDir: Bool
        let modified: Date
        var id: URL { url }
        var isNote: Bool { url.pathExtension.lowercased() == "note" }
    }

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    if item.isDir {
                        NavigationLink(value: item.url) { FolderTile(item: item) }.buttonStyle(.plain)
                    } else if item.isNote {
                        Button { open(item.url) } label: { NoteTile(item: item) }.buttonStyle(.plain)
                    } else {
                        NavigationLink(value: item.url) { FileTile(item: item) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(EInk.paper)
        .overlay {
            if items.isEmpty {
                Text(folder == model.mirrorRoot ? "Pull down to sync" : "Empty folder")
                    .font(.system(size: 15)).foregroundStyle(EInk.muted)
            }
        }
        .refreshable { await model.sync() }
        .navigationTitle(folder == model.mirrorRoot ? "Files" : folder.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: URL.self) { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                LibraryView(folder: url)
            } else {
                DocumentView(url: url)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showNewNote = true } label: { Image(systemName: "plus") }.accessibilityLabel("New note")
                SyncButton()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        .confirmationDialog("New note", isPresented: $showNewNote) {
            ForEach(NoteFactory.Template.allCases, id: \.self) { t in
                Button(t.title) { createNote(t) }
            }
        } message: { Text("Choose a template") }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $openSession, onDismiss: reload) { session in
            NoteEditorView(session: session)
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task(id: model.revision) { reload() }
        .einkStatic()
    }

    private func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u, isDir: v?.isDirectory ?? false, modified: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            if a.isDir { return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending }
            return a.modified > b.modified   // newest notes first, like the device
        }
    }

    private func open(_ url: URL) {
        do { openSession = try NoteSession(url: url) }
        catch { self.error = "Can't open \(url.lastPathComponent): \(error)" }
    }

    private func createNote(_ template: NoteFactory.Template) {
        // At the root, new notes go into Note/ like on the device.
        let dir = folder == model.mirrorRoot ? folder.appendingPathComponent("Note", isDirectory: true) : folder
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(NoteFactory.defaultFileName())
            try NoteFactory.blankNote(template: template).write(to: url, options: .withoutOverwriting)
            reload()
            open(url)
        } catch {
            self.error = "Couldn't create note: \(error)"
        }
    }
}

extension NoteSession: Identifiable {
    nonisolated var id: URL { url }
}

// MARK: Tiles

private struct TileFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: 120, height: 160)
            .background(EInk.paper)
            .overlay(Rectangle().stroke(EInk.ink, lineWidth: 1))
    }
}

private struct TileLabel: View {
    let item: LibraryView.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13)).lineLimit(2).foregroundStyle(EInk.ink)
            if !item.isDir {
                Text(item.modified, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                    .font(.system(size: 10)).foregroundStyle(EInk.muted)
            }
        }
        .frame(width: 120, alignment: .leading)
    }
}

private struct FolderTile: View {
    let item: LibraryView.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileFrame { Image(systemName: "folder").font(.system(size: 44, weight: .light)).foregroundStyle(EInk.ink) }
            TileLabel(item: item)
        }
    }
}

private struct FileTile: View {
    let item: LibraryView.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileFrame {
                VStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 40, weight: .light))
                    Text(item.url.pathExtension.uppercased()).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(EInk.ink)
            }
            TileLabel(item: item)
        }
    }

    private var icon: String {
        switch item.url.pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "epub": "book"
        case "png", "jpg", "jpeg": "photo"
        default: "doc"
        }
    }
}

private struct NoteTile: View {
    let item: LibraryView.Item
    @State private var thumb: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileFrame {
                if let thumb {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "pencil.and.scribble").font(.system(size: 30, weight: .light)).foregroundStyle(EInk.muted)
                }
            }
            TileLabel(item: item)
        }
        .task(id: item.modified) { thumb = await Thumbnails.shared.thumbnail(for: item.url, modified: item.modified) }
    }
}

/// First-page thumbnails, rendered off the main thread and cached in memory.
actor Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: CGImage] = [:]

    func thumbnail(for url: URL, modified: Date) -> CGImage? {
        let key = url.path + "|\(modified.timeIntervalSince1970)"
        if let c = cache[key] { return c }
        guard let note = try? NoteFile(contentsOf: url), !note.pages.isEmpty,
              let img = try? NoteRenderer.render(note, page: 0).cgImage?.scaled(toWidth: 240) else { return nil }
        cache[key] = img
        return img
    }
}
