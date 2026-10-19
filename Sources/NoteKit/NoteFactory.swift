import Foundation

/// Creates new Nomad notes and pages with the same block layout the device writes.
public enum NoteFactory {
    public enum Template: String, CaseIterable, Sendable {
        case blank = "style_white"
        case dots = "style_5mm_dots"

        public var title: String { self == .blank ? "Blank" : "Dots 5mm" }

        var background: Data {
            guard let url = Bundle.module.url(forResource: "Resources/\(rawValue)", withExtension: "rle"),
                  let d = try? Data(contentsOf: url) else { return RattaRLE.encode(blankCodes) }
            return d
        }
    }

    static let signature = "SN_FILE_VER_20230015"
    static let pageSize = (width: 1404, height: 1872)
    static var blankCodes: [UInt8] { [UInt8](repeating: RattaRLE.transparentCode, count: pageSize.width * pageSize.height) }

    static let layerInfo = ##"[{"layerId"#3,"name"#"Layer 3","isBackgroundLayer"#false,"isAllowAdd"#false,"isCurrentLayer"#false,"isVisible"#true,"isDeleted"#true,"isAllowUp"#false,"isAllowDown"#false},{"layerId"#2,"name"#"Layer 2","isBackgroundLayer"#false,"isAllowAdd"#false,"isCurrentLayer"#false,"isVisible"#true,"isDeleted"#true,"isAllowUp"#false,"isAllowDown"#false},{"layerId"#1,"name"#"Layer 1","isBackgroundLayer"#false,"isAllowAdd"#false,"isCurrentLayer"#false,"isVisible"#true,"isDeleted"#true,"isAllowUp"#false,"isAllowDown"#false},{"layerId"#0,"name"#"Main Layer","isBackgroundLayer"#false,"isAllowAdd"#false,"isCurrentLayer"#true,"isVisible"#true,"isDeleted"#false,"isAllowUp"#false,"isAllowDown"#false},{"layerId"#-1,"name"#"Background Layer","isBackgroundLayer"#true,"isAllowAdd"#true,"isCurrentLayer"#false,"isVisible"#true,"isDeleted"#false,"isAllowUp"#false,"isAllowDown"#false}]"##

    /// Device-style ids: prefix + yyyyMMddHHmmss + 6 digits + 12 random alphanumerics.
    static func makeID(_ prefix: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let micros = String(format: "%06d", Int(date.timeIntervalSince1970 * 1_000_000) % 1_000_000)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let rand = String((0 ..< 12).map { _ in alphabet.randomElement()! })
        return prefix + f.string(from: date) + micros + rand
    }

    /// Device naming for new notes, e.g. "20251207_221454.note".
    public static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date) + ".note"
    }

    static func layerMeta(_ name: String, bitmap: Int) -> NoteParams {
        NoteParams([("LAYERTYPE", "NOTE"), ("LAYERPROTOCOL", "RATTA_RLE"), ("LAYERNAME", name),
                    ("LAYERPATH", "0"), ("LAYERBITMAP", String(bitmap)), ("LAYERVECTORGRAPH", "0"), ("LAYERRECOGN", "0")])
    }

    static func pageMeta(style: String, main: Int, bg: Int) -> NoteParams {
        NoteParams([("PAGESTYLE", style), ("PAGESTYLEMD5", "0"), ("LAYERSEQ", "MAINLAYER,BGLAYER"),
                    ("PAGEID", makeID("P")), ("MAINLAYER", String(main)), ("LAYER1", "0"), ("LAYER2", "0"),
                    ("LAYER3", "0"), ("BGLAYER", String(bg)), ("TOTALPATH", "0"), ("THUMBNAILTYPE", "0"),
                    ("RECOGNSTATUS", "0"), ("RECOGNTEXT", "0"), ("RECOGNFILE", "0"), ("LAYERINFO", layerInfo),
                    ("RECOGNTYPE", "0"), ("RECOGNFILESTATUS", "0"), ("RECOGNLANGUAGE", "none"),
                    ("ORIENTATION", "1000"), ("PAGETEXTBOX", "0"), ("DISABLE", "none")])
    }

    /// A new one-page Nomad (N6) note.
    public static func blankNote(template: Template = .blank) -> Data {
        var out = Data("note".utf8) + Data(signature.utf8)
        func block(_ payload: Data) -> Int {
            let a = out.count
            out.appendU32(UInt32(payload.count)); out.append(payload)
            return a
        }
        let header = NoteParams([
            ("FILE_TYPE", "NOTE"), ("APPLY_EQUIPMENT", "N6"), ("FINALOPERATION_PAGE", "1"),
            ("FINALOPERATION_LAYER", "1"), ("DEVICE_DPI", "0"), ("SOFT_DPI", "0"), ("FILE_PARSE_TYPE", "0"),
            ("RATTA_ETMD", "0"), ("FILE_ID", makeID("F")), ("FILE_RECOGN_TYPE", "0"),
            ("FILE_RECOGN_LANGUAGE", "none"), ("HORIZONTAL_CHECK", "0"), ("IS_OLD_APPLY_EQUIPMENT", "1"),
            ("ANTIALIASING_CONVERT", "2"),
        ])
        let headerAddr = block(NoteFile.serialize(header))
        let styleAddr = block(template.background)
        let mainBitmap = block(RattaRLE.encode(blankCodes))
        let mainMeta = block(NoteFile.serialize(layerMeta("MAINLAYER", bitmap: mainBitmap)))
        let bgMeta = block(NoteFile.serialize(layerMeta("BGLAYER", bitmap: styleAddr)))
        let page = block(NoteFile.serialize(pageMeta(style: template.rawValue, main: mainMeta, bg: bgMeta)))
        let footer = NoteParams([("PAGE1", String(page)), ("DIRTY", "0"), ("FILE_FEATURE", String(headerAddr)),
                                 ("STYLE_\(template.rawValue)", String(styleAddr))])
        let footerAddr = block(NoteFile.serialize(footer))
        out.append(Data("tail".utf8))
        out.appendU32(UInt32(footerAddr))
        return out
    }
}

extension NoteWriter {
    /// Appends `count` empty pages after the last page, using the last page's background template.
    public static func appendPages(_ note: NoteFile, count: Int = 1, edits: [Int: PageEdit] = [:]) throws -> Data {
        guard count > 0 else { return try write(note, edits: edits) }
        // First apply page edits, then append onto that result.
        let base = edits.isEmpty ? note : try NoteFile(data: try write(note, edits: edits))
        guard let last = base.pages.last,
              let bgMeta = last.layers.first(where: { $0.name == "BGLAYER" })?.params else {
            throw WriteError.validationFailed("no background layer to copy")
        }
        let (w, h) = base.pageSize

        var out = base.raw
        out.removeLast(out.suffix(8).prefix(4) == Data("tail".utf8) ? 8 : 4)
        func block(_ payload: Data) -> Int {
            let a = out.count
            out.appendU32(UInt32(payload.count)); out.append(payload)
            return a
        }

        var footer = base.footer
        var pageKeys = base.pages.map(\.footerKey)
        for _ in 0 ..< count {
            let bitmap = block(RattaRLE.encode([UInt8](repeating: RattaRLE.transparentCode, count: w * h)))
            let main = block(NoteFile.serialize(NoteFactory.layerMeta("MAINLAYER", bitmap: bitmap)))
            let bg = block(NoteFile.serialize(bgMeta))
            var meta = NoteFactory.pageMeta(style: last.style ?? "style_white", main: main, bg: bg)
            meta.set("PAGESTYLEMD5", last.params["PAGESTYLEMD5"] ?? "0")
            let page = block(NoteFile.serialize(meta))
            let key = "PAGE\(pageKeys.count + 1)"
            footer.insert(key, String(page), after: pageKeys.last ?? "")
            pageKeys.append(key)
        }
        let footerAddr = block(NoteFile.serialize(footer))
        out.append(Data("tail".utf8))
        out.appendU32(UInt32(footerAddr))

        let reparsed = try NoteFile(data: out)
        guard reparsed.pages.count == base.pages.count + count else {
            throw WriteError.validationFailed("expected \(base.pages.count + count) pages, got \(reparsed.pages.count)")
        }
        return out
    }
}

extension NoteParams {
    mutating func insert(_ key: String, _ value: String, after: String) {
        var e = entries
        let at = (e.lastIndex { $0.key == after }).map { $0 + 1 } ?? 0
        e.insert((key, value), at: at)
        self = NoteParams(e)
    }
}
