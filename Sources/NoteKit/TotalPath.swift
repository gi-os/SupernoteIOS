import Foundation

// TOTALPATH: the vector layer of a page (every pen stroke, plus text boxes / digests).
//
// Layout from jdkruzr/go-sn docs/note-format.md (Apache-2.0) plus our own analysis of
// Nomad files (contours + hierarchy tail):
//
//   [u32 objectCount][u32 size0][obj0][u32 size1][obj1]...
//
// Stroke object (offsets relative to object start):
//   [0]   penType  [4] color  [8] width (mm*1000)  [28] layer (1 = main)
//   [100..124] bbox in page px: minX, minY, centerX, centerY, maxX, maxY (i32)
//   [128] tpPageH  [132] tpPageW          (device units, ~0.01 mm; 15819 x 11864 on Nomad)
//   [48]  "others\0\0"                     (stroke marker)
//   [212] N, then N x (rawX u32, rawY u32)     rawX ~ page Y, rawY ~ (tpW - page X)
//   u32 N, N x u16 pressure (0...4095)
//   u32 N, N x u32 (timing)
//   u32 N, N x u8  (flags)
//   74-byte block (stroke id at +16)
//   u32 C, C x (u32 k, k x (f32 x, f32 y))      outline contours in page px
//   u32 C, C x (i32 next, prev, child, parent)  OpenCV-style contour hierarchy
//   firmware-specific trailer (copied verbatim from a template stroke)

public struct PagePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum PenType: UInt32, Sendable, CaseIterable {
    // Codes observed in real files. Needle/ink/marker mapping is a best guess —
    // run `snsync strokes` on a page where you drew each pen on the Nomad to confirm.
    case needlePoint = 1
    case inkPen = 10
    case marker = 11
}

public enum InkColor: UInt32, Sendable, CaseIterable {
    case black = 0
    case darkGray = 157
    case lightGray = 201
    case white = 254

    /// RATTA_RLE (X2) code used in the layer bitmap.
    public func bitmapCode(marker: Bool) -> UInt8 {
        switch self {
        case .black: marker ? 0x66 : 0x61
        case .darkGray: marker ? 0x9E : 0x9D
        case .lightGray: marker ? 0xCA : 0xC9
        case .white: 0x65
        }
    }
}

public struct NoteStroke: Sendable {
    public var penType: UInt32
    public var color: UInt32
    public var width: UInt32
    public var layer: UInt32
    public var points: [PagePoint]
    public var pressures: [UInt16]
    public var contours: [[PagePoint]]
    /// next, prev, child, parent per contour (even-odd fill makes this only informational for rendering).
    public var hierarchy: [[Int32]]
    /// The bytes this stroke was decoded from (or the template it will be encoded with).
    var template: Data
    /// Untouched device strokes are written back byte-for-byte.
    var isModified = false

    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let pts = contours.flatMap { $0 }.isEmpty ? points : contours.flatMap { $0 }
        var b = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for p in pts { b.minX = min(b.minX, p.x); b.minY = min(b.minY, p.y); b.maxX = max(b.maxX, p.x); b.maxY = max(b.maxY, p.y) }
        return b
    }

    public var isMarker: Bool { penType == PenType.marker.rawValue || penType == 5 || penType == 16 }

    public var bitmapCode: UInt8 {
        (InkColor(rawValue: color) ?? .black).bitmapCode(marker: isMarker)
    }

    public mutating func translate(dx: Double, dy: Double) {
        isModified = true
        points = points.map { PagePoint(x: $0.x + dx, y: $0.y + dy) }
        contours = contours.map { $0.map { PagePoint(x: $0.x + dx, y: $0.y + dy) } }
    }
}

public enum TotalPathObject: Sendable {
    case stroke(NoteStroke)
    case other(Data)   // text boxes, digests, or anything we can't safely decode — kept verbatim
}

public struct TotalPath: Sendable {
    public var objects: [TotalPathObject]
    public var pageWidth: Int
    public var pageHeight: Int

    public var strokes: [NoteStroke] {
        objects.compactMap { if case let .stroke(s) = $0 { s } else { nil } }
    }

    /// A stroke object from this page we can clone headers / trailers from.
    public var templateStroke: Data? {
        for case let .stroke(s) in objects { return s.template }
        return nil
    }

    public init(objects: [TotalPathObject] = [], pageWidth: Int, pageHeight: Int) {
        self.objects = objects; self.pageWidth = pageWidth; self.pageHeight = pageHeight
    }

    public init(data: Data?, pageWidth: Int, pageHeight: Int) {
        self.pageWidth = pageWidth; self.pageHeight = pageHeight
        objects = []
        guard let data, data.count >= 8 else { return }
        let r = ByteReader(data)
        var off = 8
        var size = r.u32(4)
        var first = true
        while off < data.count {
            if !first {
                guard off + 4 <= data.count else { break }
                size = r.u32(off); off += 4
            }
            first = false
            let end = min(off + size, data.count)
            let obj = data.subdata(in: data.startIndex + off ..< data.startIndex + end)
            if let s = StrokeCodec.decode(obj, pageWidth: pageWidth, pageHeight: pageHeight) {
                objects.append(.stroke(s))
            } else {
                objects.append(.other(obj))
            }
            off = end
        }
    }

    public func encoded() -> Data {
        var bodies: [Data] = objects.map {
            switch $0 {
            case let .stroke(s): StrokeCodec.encode(s, pageWidth: pageWidth, pageHeight: pageHeight)
            case let .other(d): d
            }
        }
        var out = Data()
        out.appendU32(UInt32(bodies.count))
        guard !bodies.isEmpty else { out.appendU32(0); return out }
        out.appendU32(UInt32(bodies[0].count))
        out.append(bodies.removeFirst())
        for b in bodies { out.appendU32(UInt32(b.count)); out.append(b) }
        return out
    }

    /// Largest stroke id on the page (ids live in the 74-byte block); new strokes continue from here.
    public var maxStrokeID: UInt32 {
        strokes.map { StrokeCodec.strokeID($0.template) }.max() ?? 0
    }
}

public enum StrokeCodec {
    static let marker = Data("others\0\0".utf8)
    static let prefixLength = 74

    struct Layout {
        var n: Int
        var prefixStart: Int    // the 74-byte block
        var contoursStart: Int
        var hierarchyStart: Int
        var trailerStart: Int
    }

    static func layout(_ o: Data) -> Layout? {
        let r = ByteReader(o)
        guard o.count >= 216, o.subdata(in: o.startIndex + 48 ..< o.startIndex + 56) == marker else { return nil }
        let n = r.u32(212)
        guard n > 0, n < 200_000 else { return nil }
        var p = 216 + n * 8
        guard p + 4 <= o.count, r.u32(p) == n else { return nil }
        p += 4 + n * 2
        guard p + 4 <= o.count, r.u32(p) == n else { return nil }
        p += 4 + n * 4
        guard p + 4 <= o.count, r.u32(p) == n else { return nil }
        p += 4 + n
        let prefix = p
        p += prefixLength
        guard p + 4 <= o.count else { return nil }
        let nc = r.u32(p); p += 4
        guard nc < 10_000 else { return nil }
        let contoursStart = p - 4
        for _ in 0 ..< nc {
            guard p + 4 <= o.count else { return nil }
            let k = r.u32(p); p += 4 + k * 8
            guard p <= o.count else { return nil }
        }
        let hier = p
        guard p + 4 <= o.count, r.u32(p) == nc else { return nil }
        p += 4 + nc * 16
        guard p <= o.count else { return nil }
        return Layout(n: n, prefixStart: prefix, contoursStart: contoursStart, hierarchyStart: hier, trailerStart: p)
    }

    public static func decode(_ o: Data, pageWidth: Int, pageHeight: Int) -> NoteStroke? {
        guard let l = layout(o) else { return nil }
        let r = ByteReader(o)
        let tpH = Double(r.u32(128)), tpW = Double(r.u32(132))
        guard tpH > 0, tpW > 0 else { return nil }
        let W = Double(pageWidth), H = Double(pageHeight)

        var points: [PagePoint] = []
        points.reserveCapacity(l.n)
        for i in 0 ..< l.n {
            let rx = Double(r.u32(216 + i * 8)), ry = Double(r.u32(216 + i * 8 + 4))
            points.append(PagePoint(x: (tpW - ry) * W / tpW, y: rx * H / tpH))
        }
        let pBase = 216 + l.n * 8 + 4
        let pressures = (0 ..< l.n).map { UInt16(r.u16(pBase + $0 * 2)) }

        var contours: [[PagePoint]] = []
        var p = l.contoursStart
        let nc = r.u32(p); p += 4
        for _ in 0 ..< nc {
            let k = r.u32(p); p += 4
            contours.append((0 ..< k).map { j in
                PagePoint(x: Double(r.f32(p + j * 8)), y: Double(r.f32(p + j * 8 + 4)))
            })
            p += k * 8
        }
        var hierarchy: [[Int32]] = []
        p = l.hierarchyStart + 4
        for _ in 0 ..< nc {
            hierarchy.append((0 ..< 4).map { Int32(bitPattern: UInt32(r.u32(p + $0 * 4))) })
            p += 16
        }

        return NoteStroke(penType: UInt32(r.u32(0)), color: UInt32(r.u32(4)), width: UInt32(r.u32(8)),
                          layer: UInt32(r.u32(28)), points: points, pressures: pressures,
                          contours: contours, hierarchy: hierarchy, template: o)
    }

    /// Re-encodes a stroke using its template for every field we don't model.
    public static func encode(_ s: NoteStroke, pageWidth: Int, pageHeight: Int) -> Data {
        let t = s.template
        guard s.isModified, let l = layout(t) else { return t }
        let r = ByteReader(t)
        let tpH = Double(r.u32(128)), tpW = Double(r.u32(132))
        let W = Double(pageWidth), H = Double(pageHeight)
        let n = s.points.count

        var header = t.prefix(212)
        header.setU32(0, s.penType)
        header.setU32(4, s.color)
        header.setU32(8, s.width)
        header.setU32(28, s.layer)
        let b = s.bounds
        if b.minX.isFinite {
            header.setI32(100, Int32(b.minX.rounded(.down)))
            header.setI32(104, Int32(b.minY.rounded(.down)))
            header.setI32(108, Int32(((b.minX + b.maxX) / 2).rounded()))
            header.setI32(112, Int32(((b.minY + b.maxY) / 2).rounded()))
            header.setI32(116, Int32(b.maxX.rounded(.up)))
            header.setI32(120, Int32(b.maxY.rounded(.up)))
        }

        var out = Data(header)
        out.appendU32(UInt32(n))
        for p in s.points {
            let rx = max(0, (p.y * tpH / H).rounded())
            let ry = max(0, (tpW - p.x * tpW / W).rounded())
            out.appendU32(UInt32(rx)); out.appendU32(UInt32(ry))
        }
        out.appendU32(UInt32(n))
        for i in 0 ..< n { out.appendU16(i < s.pressures.count ? s.pressures[i] : 1024) }

        // Timing + flags: reuse the template's values when lengths match, else repeat its first entry.
        let tBase = 216 + l.n * 8 + 4 + l.n * 2 + 4
        out.appendU32(UInt32(n))
        for i in 0 ..< n { out.appendU32(UInt32(r.u32(tBase + (n == l.n ? i : 0) * 4))) }
        let fBase = tBase + l.n * 4 + 4
        out.appendU32(UInt32(n))
        for i in 0 ..< n { out.append(t[t.startIndex + fBase + (n == l.n ? i : 0)]) }

        out.append(t.subdata(in: t.startIndex + l.prefixStart ..< t.startIndex + l.prefixStart + prefixLength))

        out.appendU32(UInt32(s.contours.count))
        for c in s.contours {
            out.appendU32(UInt32(c.count))
            for p in c { out.appendF32(Float(p.x)); out.appendF32(Float(p.y)) }
        }
        out.appendU32(UInt32(s.contours.count))
        for i in 0 ..< s.contours.count {
            let h = i < s.hierarchy.count ? s.hierarchy[i] : [-1, -1, -1, -1]
            for v in h { out.appendU32(UInt32(bitPattern: v)) }
        }
        out.append(t.subdata(in: t.startIndex + l.trailerStart ..< t.endIndex))
        return out
    }

    static func strokeID(_ o: Data) -> UInt32 {
        guard let l = layout(o) else { return 0 }
        return UInt32(ByteReader(o).u32(l.prefixStart + 16))
    }

    /// Builds a new stroke from pen input, cloning unknown fields from `template`.
    public static func makeStroke(points: [PagePoint], pressures: [UInt16], pen: PenType, color: InkColor,
                                  widthMM: Double, id: UInt32, template: Data) -> NoteStroke {
        var t = template
        if let l = layout(t) { t.setU32(l.prefixStart + 16, id) }
        let widthPx = widthMM * pixelsPerMM
        let radii = points.indices.map { i -> Double in
            let p = i < pressures.count ? Double(pressures[i]) / 4095 : 0.5
            switch pen {
            case .inkPen: return max(0.6, widthPx / 2 * (0.35 + 0.9 * p))
            case .needlePoint, .marker: return max(0.6, widthPx / 2)
            }
        }
        return NoteStroke(penType: pen.rawValue, color: color.rawValue, width: UInt32((widthMM * 1000).rounded()),
                          layer: 1, points: points, pressures: pressures,
                          contours: [StrokeGeometry.outline(points: points, radii: radii)],
                          hierarchy: [[-1, -1, -1, -1]], template: t, isModified: true)
    }

    /// Nomad/Manta digitizer: ~11.83 px per mm (1872 px over 158.19 mm).
    public static let pixelsPerMM = 1872.0 / 158.19
}

// MARK: - Byte helpers

struct ByteReader {
    let d: Data
    init(_ d: Data) { self.d = d }
    func u32(_ o: Int) -> Int {
        let b = d.startIndex + o
        return Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16 | Int(d[b + 3]) << 24
    }
    func u16(_ o: Int) -> Int { let b = d.startIndex + o; return Int(d[b]) | Int(d[b + 1]) << 8 }
    func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(u32(o))) }
}

extension Data {
    mutating func appendU32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendU16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendF32(_ v: Float) { appendU32(v.bitPattern) }
    mutating func setU32(_ o: Int, _ v: UInt32) {
        let b = startIndex + o
        for i in 0 ..< 4 { self[b + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
    mutating func setI32(_ o: Int, _ v: Int32) { setU32(o, UInt32(bitPattern: v)) }
}
