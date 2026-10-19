import Foundation

/// Mutable model of one note page: vector strokes (TOTALPATH) + the MAINLAYER bitmap that the
/// Nomad displays. New strokes are painted onto the existing bitmap so untouched ink stays
/// byte-identical; erasing / moving regenerates the bitmap from stroke contours.
public final class PageEditor {
    public let index: Int
    public let width: Int
    public let height: Int
    public private(set) var path: TotalPath
    public private(set) var mainCodes: [UInt8]
    public private(set) var isDirty = false
    /// Visible layers under / over MAINLAYER, pre-composited (0xFF = transparent).
    let underlay: [UInt8]
    let overlay: [UInt8]?
    let x2: Bool

    private struct Snapshot { var objects: [TotalPathObject]; var main: Data }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    public static let undoLimit = 20   // same as the device

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var strokes: [NoteStroke] { path.strokes }

    public init(note: NoteFile, index: Int) throws {
        let page = note.pages[index]
        // Landscape pages store stroke contours in rotated space; not handled yet.
        guard !page.isHorizontal else { throw NoteWriter.WriteError.landscapeNotSupported(index) }
        let (w, h) = note.pageSize
        self.index = index; width = w; height = h
        x2 = note.supportsHighResGrayscale
        path = TotalPath(data: page.totalPath, pageWidth: note.pageSize.width, pageHeight: note.pageSize.height)

        guard let main = page.layers.first(where: { $0.name == "MAINLAYER" }) else {
            throw NoteWriter.WriteError.pageHasNoMainLayer(index)
        }
        if let bitmap = main.bitmap {
            mainCodes = try RattaRLE.decodeCodes(bitmap, width: w, height: h)
        } else {
            mainCodes = [UInt8](repeating: RattaRLE.transparentCode, count: w * h)
        }

        // Pre-render everything except MAINLAYER so per-stroke redraws only touch one layer.
        let vis = NoteRenderer.layerVisibility(page)
        let order = page.layerOrder.isEmpty ? NotePage.layerKeys : page.layerOrder
        let mainPos = order.firstIndex(of: "MAINLAYER") ?? order.count
        func composite(_ names: ArraySlice<String>, base: UInt8) throws -> [UInt8] {
            var buf = [UInt8](repeating: base, count: w * h)
            for name in names.reversed() where vis[name] ?? true {
                guard let layer = page.layers.first(where: { $0.name == name }), let bmp = layer.bitmap else { continue }
                let px: [UInt8]
                if name == "BGLAYER", page.style?.hasPrefix("user_") == true {
                    guard let png = NoteRenderer.decodePNG(bmp, width: w, height: h) else { continue }
                    px = png
                } else {
                    let allBlank = name == "BGLAYER" && page.style == "style_white" && bmp.count == 0x140E
                    px = try RattaRLE.decode(bmp, width: w, height: h, allBlank: allBlank, x2: note.supportsHighResGrayscale)
                }
                for i in 0 ..< px.count where px[i] != Gray.transparent { buf[i] = px[i] }
            }
            return buf
        }
        underlay = try composite(order[(min(mainPos + 1, order.count))...], base: Gray.white)
        let over = try composite(order[..<mainPos], base: Gray.transparent)
        overlay = over.contains { $0 != Gray.transparent } ? over : nil
    }

    // MARK: Rendering

    /// Grayscale composite of the whole page (what the Nomad shows).
    public func render() -> GrayImage {
        var px = underlay
        let lut = RattaRLE.grayLUT(x2: x2)
        for i in 0 ..< mainCodes.count {
            let c = mainCodes[i]
            if c != RattaRLE.transparentCode { px[i] = lut[Int(c)] }
        }
        if let overlay {
            for i in 0 ..< overlay.count where overlay[i] != Gray.transparent { px[i] = overlay[i] }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    // MARK: Editing

    private func checkpoint() {
        undoStack.append(Snapshot(objects: path.objects, main: RattaRLE.encode(mainCodes)))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    private func restore(_ s: Snapshot) {
        path.objects = s.objects
        mainCodes = (try? RattaRLE.decodeCodes(s.main, width: width, height: height)) ?? mainCodes
    }

    public func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(objects: path.objects, main: RattaRLE.encode(mainCodes)))
        restore(s)
    }

    public func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(objects: path.objects, main: RattaRLE.encode(mainCodes)))
        restore(s)
    }

    /// Adds a pen stroke (page pixel coordinates, pressure 0...4095).
    @discardableResult
    public func addStroke(points: [PagePoint], pressures: [UInt16], pen: PenType, color: InkColor, widthMM: Double) -> NoteStroke? {
        guard !points.isEmpty, let template = path.templateStroke ?? StrokeTemplate.nomad else { return nil }
        checkpoint()
        let stroke = StrokeCodec.makeStroke(points: points, pressures: pressures, pen: pen, color: color,
                                            widthMM: widthMM, id: path.maxStrokeID + 1, template: template)
        path.objects.append(.stroke(stroke))
        Raster.draw(stroke, into: &mainCodes, width: width, height: height)
        return stroke
    }

    /// Stroke eraser: removes every main-layer stroke the eraser path touches.
    @discardableResult
    public func eraseStrokes(along points: [PagePoint], radius: Double) -> Int {
        let hit = path.objects.indices.filter { i in
            guard case let .stroke(s) = path.objects[i], s.layer == 1 else { return false }
            return points.contains { StrokeGeometry.hits(s, $0, radius: radius) }
        }
        guard !hit.isEmpty else { return 0 }
        checkpoint()
        removeObjects(Set(hit))
        regenerateMainLayer()
        return hit.count
    }

    /// Erase all: clears the main layer.
    public func eraseAll() {
        guard path.objects.contains(where: { if case let .stroke(s) = $0 { s.layer == 1 } else { false } }) else { return }
        checkpoint()
        removeObjects(Set(path.objects.indices.filter { if case let .stroke(s) = path.objects[$0] { s.layer == 1 } else { false } }))
        mainCodes = [UInt8](repeating: RattaRLE.transparentCode, count: width * height)
    }

    /// Lasso: indices of main-layer strokes mostly inside the polygon.
    public func select(lasso: [PagePoint]) -> Set<Int> {
        guard lasso.count >= 3 else { return [] }
        return Set(path.objects.indices.filter { i in
            guard case let .stroke(s) = path.objects[i], s.layer == 1, !s.points.isEmpty else { return false }
            let inside = s.points.filter { StrokeGeometry.contains(lasso, $0) }.count
            return Double(inside) / Double(s.points.count) >= 0.6
        })
    }

    public func move(_ selection: Set<Int>, dx: Double, dy: Double) {
        guard !selection.isEmpty, dx != 0 || dy != 0 else { return }
        checkpoint()
        for i in selection {
            if case var .stroke(s) = path.objects[i] { s.translate(dx: dx, dy: dy); path.objects[i] = .stroke(s) }
        }
        regenerateMainLayer()
    }

    public func delete(_ selection: Set<Int>) {
        guard !selection.isEmpty else { return }
        checkpoint()
        removeObjects(selection)
        regenerateMainLayer()
    }

    public func bounds(of selection: Set<Int>) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var b: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
        for i in selection {
            guard case let .stroke(s) = path.objects[i] else { continue }
            let sb = s.bounds
            b = b.map { (min($0.minX, sb.minX), min($0.minY, sb.minY), max($0.maxX, sb.maxX), max($0.maxY, sb.maxY)) } ?? sb
        }
        return b
    }

    private func removeObjects(_ indices: Set<Int>) {
        path.objects = path.objects.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
    }

    /// Rebuilds the bitmap from stroke contours (≈ the device's own rasterization).
    func regenerateMainLayer() {
        mainCodes = [UInt8](repeating: RattaRLE.transparentCode, count: width * height)
        for case let .stroke(s) in path.objects where s.layer == 1 {
            Raster.draw(s, into: &mainCodes, width: width, height: height)
        }
    }

    // MARK: Saving

    public func makeEdit() -> NoteWriter.PageEdit {
        NoteWriter.PageEdit(mainLayerRLE: RattaRLE.encode(mainCodes), totalPath: path.encoded())
    }

    public func markSaved() { isDirty = false }
}

extension RattaRLE {
    static func grayLUT(x2: Bool) -> [UInt8] {
        let map = colormap(x2: x2)
        return (0 ..< 256).map { map[UInt8($0)] ?? (x2 ? UInt8($0) : Gray.transparent) }
    }
}
