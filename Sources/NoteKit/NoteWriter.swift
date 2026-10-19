import Foundation

/// Writes edited pages back into a `.note` file, append-only:
/// every original byte stays where it was (so any block we don't understand keeps working),
/// and we append new MAINLAYER bitmap, TOTALPATH, layer + page metadata, and a fresh footer.
public enum NoteWriter {
    public struct PageEdit {
        public var mainLayerRLE: Data
        public var totalPath: Data
        public init(mainLayerRLE: Data, totalPath: Data) { self.mainLayerRLE = mainLayerRLE; self.totalPath = totalPath }
    }

    public enum WriteError: Error, Equatable {
        case pageHasNoMainLayer(Int)
        case landscapeNotSupported(Int)
        case validationFailed(String)
    }

    public static func write(_ note: NoteFile, edits: [Int: PageEdit]) throws -> Data {
        var out = note.raw
        // Drop the trailing "tail" marker + footer address; the old footer becomes dead space.
        let trailerLength = out.suffix(8).prefix(4) == Data("tail".utf8) ? 8 : 4
        out.removeLast(trailerLength)

        @discardableResult
        func appendBlock(_ payload: Data) -> Int {
            let addr = out.count
            out.appendU32(UInt32(payload.count))
            out.append(payload)
            return addr
        }

        var footer = note.footer
        for (index, edit) in edits.sorted(by: { $0.key < $1.key }) {
            let page = note.pages[index]
            guard var layerMeta = page.layers.first(where: { $0.name == "MAINLAYER" })?.params,
                  page.params["MAINLAYER"] != nil else { throw WriteError.pageHasNoMainLayer(index) }

            let bitmapAddr = appendBlock(edit.mainLayerRLE)
            let pathAddr = appendBlock(edit.totalPath)
            layerMeta.set("LAYERBITMAP", String(bitmapAddr))
            layerMeta.set("LAYERPROTOCOL", "RATTA_RLE")
            let layerAddr = appendBlock(NoteFile.serialize(layerMeta))

            var pageMeta = page.params
            pageMeta.set("MAINLAYER", String(layerAddr))
            pageMeta.set("TOTALPATH", String(pathAddr))
            let pageAddr = appendBlock(NoteFile.serialize(pageMeta))
            footer.set(page.footerKey, String(pageAddr))
        }

        let footerAddr = appendBlock(NoteFile.serialize(footer))
        out.append(Data("tail".utf8))
        out.appendU32(UInt32(footerAddr))

        try validate(out, original: note, edits: edits)
        return out
    }

    /// Re-parses the output and decodes every edited layer, so a bad write never reaches disk.
    static func validate(_ data: Data, original: NoteFile, edits: [Int: PageEdit]) throws {
        let reparsed: NoteFile
        do { reparsed = try NoteFile(data: data) } catch { throw WriteError.validationFailed("reparse: \(error)") }
        guard reparsed.pages.count == original.pages.count else {
            throw WriteError.validationFailed("page count \(reparsed.pages.count) != \(original.pages.count)")
        }
        let (w, h) = original.pageSize
        for (index, edit) in edits {
            let page = reparsed.pages[index]
            guard let main = page.layers.first(where: { $0.name == "MAINLAYER" })?.bitmap, main == edit.mainLayerRLE,
                  page.totalPath == edit.totalPath else {
                throw WriteError.validationFailed("page \(index + 1) blocks don't round-trip")
            }
            var (pw, ph) = (w, h)
            if page.isHorizontal { swap(&pw, &ph) }
            do { _ = try RattaRLE.decodeCodes(main, width: pw, height: ph) }
            catch { throw WriteError.validationFailed("page \(index + 1) bitmap: \(error)") }
        }
    }
}
