import NoteKit
import SwiftUI

/// Pop-out panels next to the toolbar, styled like the Nomad's option windows.
struct EditorPanelView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: NoteSession
    let panel: EditorPanel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch panel {
            case let .pen(type): penPanel(type)
            case .eraser: eraserPanel
            case .navigation: navigationPanel
            case .layers: layersPanel
            case .pages: pagesPanel
            case .share: sharePanel
            case .more: morePanel
            }
        }
        .padding(14)
        .frame(width: panelWidth, alignment: .leading)
        .einkPanel()
        .einkStatic()
    }

    private var panelWidth: CGFloat { panel == .pages ? 420 : 260 }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 15, weight: .semibold)).foregroundStyle(EInk.ink)
    }

    // MARK: Pens

    static let sizes: [PenType: [Double]] = [
        .needlePoint: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.2, 1.5],
        .inkPen: [0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.2, 1.5, 2.0],
        .marker: [1.5],
    ]

    @ViewBuilder private func penPanel(_ type: PenType) -> some View {
        let name = type == .needlePoint ? "Needle-point pen" : type == .inkPen ? "Ink pen" : "Marker"
        title(name)
        if type != .marker {
            Text("Thickness (mm)").font(.system(size: 12)).foregroundStyle(EInk.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.sizes[type] ?? [], id: \.self) { size in
                    let selected = abs((session.pens[type]?.widthMM ?? 0) - size) < 0.01
                    Button { session.pens[type]?.widthMM = size } label: {
                        VStack(spacing: 2) {
                            Capsule().fill(EInk.ink).frame(width: 26, height: max(1, size * 4))
                            Text(String(format: "%.1f", size)).font(.system(size: 10))
                        }
                        .frame(width: 42, height: 36)
                        .overlay { if selected { RoundedRectangle(cornerRadius: 3).stroke(EInk.ink, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        Text("Color").font(.system(size: 12)).foregroundStyle(EInk.muted)
        HStack(spacing: 12) {
            ForEach(InkColor.allCases, id: \.self) { c in
                let selected = session.pens[type]?.color == c
                Button { session.pens[type]?.color = c } label: {
                    Circle().fill(EInk.gray(c))
                        .overlay(Circle().stroke(EInk.ink, lineWidth: 1))
                        .frame(width: 26, height: 26)
                        .padding(3)
                        .overlay { if selected { Circle().stroke(EInk.ink, lineWidth: 2) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colorName(c))
            }
        }
    }

    private func colorName(_ c: InkColor) -> String {
        switch c { case .black: "Black"; case .darkGray: "Dark grey"; case .lightGray: "Light grey"; case .white: "White" }
    }

    private var eraserPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Eraser")
            Text("Erases whole strokes it touches.").font(.system(size: 12)).foregroundStyle(EInk.muted)
            HStack(spacing: 10) {
                ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { r in
                    Button { session.eraserRadiusMM = r } label: {
                        Circle().stroke(EInk.ink, lineWidth: 1).frame(width: 8 + r * 5, height: 8 + r * 5)
                            .frame(width: 40, height: 40)
                            .overlay { if session.eraserRadiusMM == r { RoundedRectangle(cornerRadius: 3).stroke(EInk.ink, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Navigation / pages

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Navigation")
            let titles = session.note.footer.keys(withPrefix: "TITLE_")
            let keywords = session.note.footer.keys(withPrefix: "KEYWORD_")
            if titles.isEmpty && keywords.isEmpty {
                Text("No headings or keywords in this note.").font(.system(size: 13)).foregroundStyle(EInk.muted)
            }
            ForEach(titles + keywords, id: \.self) { key in
                // TITLE_0001xxxx / KEYWORD_0001xxxx — digits 6...10 are the page number.
                let page = Int(key.dropFirst(key.hasPrefix("TITLE_") ? 6 : 8).prefix(4)) ?? 1
                Button { session.go(to: page - 1); close() } label: {
                    HStack {
                        Image(systemName: key.hasPrefix("TITLE_") ? "textformat" : "tag")
                        Text(key.hasPrefix("TITLE_") ? "Heading" : "Keyword")
                        Spacer()
                        Text("p. \(page)").foregroundStyle(EInk.muted)
                    }
                    .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pagesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Pages (\(session.pageCount))")
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 12), count: 3), spacing: 12) {
                    ForEach(0 ..< session.pageCount, id: \.self) { i in
                        Button { session.go(to: i); close() } label: {
                            VStack(spacing: 4) {
                                PageThumb(session: session, index: i)
                                    .frame(width: 112, height: 150)
                                    .overlay(Rectangle().stroke(EInk.ink, lineWidth: i == session.pageIndex ? 2 : 0.5))
                                Text("\(i + 1)").font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 520)
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Layers")
            let page = session.note.pages[session.pageIndex]
            ForEach(page.layerOrder, id: \.self) { name in
                HStack {
                    Image(systemName: name == "MAINLAYER" ? "pencil" : name == "BGLAYER" ? "doc" : "square.stack")
                    Text(name == "MAINLAYER" ? "Main Layer" : name == "BGLAYER" ? "Background Layer" : name.capitalized)
                    Spacer()
                    if name == "MAINLAYER" { Image(systemName: "checkmark") }
                }
                .font(.system(size: 14))
            }
            Text("Editing applies to the main layer. Extra layers from the Nomad are shown, not edited.")
                .font(.system(size: 11)).foregroundStyle(EInk.muted)
        }
    }

    private var sharePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Share / Export")
            if let png = session.exportPNG() {
                ShareLink(item: png) { Label("Current page as PNG", systemImage: "photo") }
            }
            ShareLink(item: session.url) { Label("Note file (.note)", systemImage: "doc") }
        }
        .font(.system(size: 14))
        .foregroundStyle(EInk.ink)
    }

    private var morePanel: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            title("More")
            Toggle("Apple Pencil only", isOn: $model.pencilOnly)
            Toggle("Left-handed mode", isOn: $model.leftHanded)
            Button("Save now") { session.save() }
            Text("Saved notes sync like your Nomad's own edits. Previous versions are kept in Backups.")
                .font(.system(size: 11)).foregroundStyle(EInk.muted)
        }
        .font(.system(size: 14))
        .tint(EInk.ink)
    }
}

struct PageThumb: View {
    let session: NoteSession
    let index: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
        }
        .task(id: index) { image = session.thumbnail(for: index) }
    }
}
