import Foundation
import XCTest
@testable import NoteKit

final class EditingTests: XCTestCase {
    func fixture(_ name: String) throws -> NoteFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "note"))
        return try NoteFile(contentsOf: url)
    }

    func testRLEEncodeRoundTripsDeviceLayer() throws {
        let note = try fixture("nomad_strokes")
        let main = try XCTUnwrap(note.pages[0].layers.first { $0.name == "MAINLAYER" }?.bitmap)
        let codes = try RattaRLE.decodeCodes(main, width: 1404, height: 1872)
        let encoded = RattaRLE.encode(codes)
        XCTAssertEqual(try RattaRLE.decodeCodes(encoded, width: 1404, height: 1872), codes)
    }

    func testRLEEncodeEdgeRunLengths() throws {
        for n in [1, 2, 127, 128, 129, 130, 255, 256, 16383, 16384, 16385, 40000] {
            let codes = [UInt8](repeating: 0x61, count: n) + [0x62] + [UInt8](repeating: 0x9D, count: n)
            let w = codes.count
            XCTAssertEqual(try RattaRLE.decodeCodes(RattaRLE.encode(codes), width: w, height: 1), codes, "n=\(n)")
        }
    }

    func testTotalPathDecodesAndReencodesByteExact() throws {
        let note = try fixture("nomad_strokes")
        let raw = try XCTUnwrap(note.pages[0].totalPath)
        let tp = TotalPath(data: raw, pageWidth: 1404, pageHeight: 1872)
        XCTAssertEqual(tp.strokes.count, 57)
        XCTAssertEqual(tp.encoded(), raw)
        let s = tp.strokes[0]
        XCTAssertEqual(s.penType, 10)
        XCTAssertEqual(s.points.count, s.pressures.count)
        XCTAssertEqual(s.contours.count, 1)
    }

    func testModifiedStrokeReencodesAndDecodes() throws {
        let note = try fixture("nomad_strokes")
        var tp = TotalPath(data: note.pages[0].totalPath, pageWidth: 1404, pageHeight: 1872)
        guard case var .stroke(s) = tp.objects[3] else { return XCTFail() }
        let before = s.points[0]
        s.translate(dx: 10, dy: -5)
        tp.objects[3] = .stroke(s)
        let again = TotalPath(data: tp.encoded(), pageWidth: 1404, pageHeight: 1872)
        let moved = again.strokes[3]
        XCTAssertEqual(moved.points[0].x, before.x + 10, accuracy: 0.2)
        XCTAssertEqual(moved.points[0].y, before.y - 5, accuracy: 0.2)
        XCTAssertEqual(moved.points.count, s.points.count)
    }

    func testContourFillMatchesDeviceBitmap() throws {
        let note = try fixture("nomad_strokes")
        let page = try PageEditor(note: note, index: 0)
        let device = page.mainCodes
        page.regenerateMainLayer()
        let ours = page.mainCodes
        var inter = 0, union = 0
        for i in 0 ..< device.count {
            let a = device[i] != RattaRLE.transparentCode, b = ours[i] != RattaRLE.transparentCode
            if a && b { inter += 1 }
            if a || b { union += 1 }
        }
        print("contour IoU", Double(inter) / Double(union)); XCTAssertGreaterThan(Double(inter) / Double(union), 0.9)
    }

    func testAddStrokeWriteAndReload() throws {
        let note = try fixture("nomad_strokes")
        let page = try PageEditor(note: note, index: 0)
        let pts = (0 ..< 50).map { PagePoint(x: 300 + Double($0) * 6, y: 1500 + sin(Double($0) / 5) * 40) }
        let stroke = try XCTUnwrap(page.addStroke(points: pts, pressures: Array(repeating: 2000, count: 50),
                                                  pen: .needlePoint, color: .black, widthMM: 0.4))
        XCTAssertTrue(page.isDirty)
        XCTAssertEqual(page.mainCodes[1500 * 1404 + 300], 0x61)

        let data = try NoteWriter.write(note, edits: [0: page.makeEdit()])
        let reloaded = try NoteFile(data: data)
        XCTAssertGreaterThan(data.count, note.raw.count)
        XCTAssertEqual(data.prefix(note.raw.count - 8), note.raw.prefix(note.raw.count - 8)) // append-only

        let tp = TotalPath(data: reloaded.pages[0].totalPath, pageWidth: 1404, pageHeight: 1872)
        XCTAssertEqual(tp.strokes.count, 58)
        let last = try XCTUnwrap(tp.strokes.last)
        XCTAssertEqual(last.points.count, 50)
        XCTAssertEqual(last.points[0].x, 300, accuracy: 0.2)
        XCTAssertEqual(last.width, 400)
        XCTAssertEqual(last.contours[0].count, stroke.contours[0].count)
        // Still renders, and the new ink is there.
        let img = try NoteRenderer.render(reloaded, page: 0)
        XCTAssertEqual(img.pixels[1500 * 1404 + 300], Gray.black)
    }

    func testEraseUndoRedo() throws {
        let note = try fixture("nomad_strokes")
        let page = try PageEditor(note: note, index: 0)
        let target = page.strokes[0].points[10]
        XCTAssertEqual(page.eraseStrokes(along: [target], radius: 3), 1)
        XCTAssertEqual(page.strokes.count, 56)
        page.undo()
        XCTAssertEqual(page.strokes.count, 57)
        page.redo()
        XCTAssertEqual(page.strokes.count, 56)
    }

    func testLassoMoveAndDelete() throws {
        let note = try fixture("nomad_strokes")
        let page = try PageEditor(note: note, index: 0)
        let b = page.strokes[3].bounds
        let lasso = [PagePoint(x: b.minX - 2, y: b.minY - 2), PagePoint(x: b.maxX + 2, y: b.minY - 2),
                     PagePoint(x: b.maxX + 2, y: b.maxY + 2), PagePoint(x: b.minX - 2, y: b.maxY + 2)]
        let sel = page.select(lasso: lasso)
        XCTAssertTrue(sel.contains(3))
        page.move(sel, dx: 0, dy: 100)
        XCTAssertEqual(page.strokes[3].bounds.minY, b.minY + 100, accuracy: 0.01)
        page.delete(sel)
        XCTAssertEqual(page.strokes.count, 57 - sel.count)
        let data = try NoteWriter.write(note, edits: [0: page.makeEdit()])
        XCTAssertEqual(TotalPath(data: try NoteFile(data: data).pages[0].totalPath, pageWidth: 1404, pageHeight: 1872).strokes.count, 57 - sel.count)
    }
}

final class FactoryTests: XCTestCase {
    func testBlankNoteParsesAndEdits() throws {
        for t in NoteFactory.Template.allCases {
            let data = NoteFactory.blankNote(template: t)
            let note = try NoteFile(data: data, strict: true)
            XCTAssertEqual(note.equipment, "N6")
            XCTAssertEqual(note.pages.count, 1)
            let img = try NoteRenderer.render(note, page: 0)
            XCTAssertEqual(img.width, 1404)
            let page = try PageEditor(note: note, index: 0)
            page.addStroke(points: [PagePoint(x: 100, y: 100), PagePoint(x: 400, y: 120)], pressures: [1500, 1500],
                           pen: .inkPen, color: .black, widthMM: 0.5)
            let edited = try NoteFile(data: NoteWriter.write(note, edits: [0: page.makeEdit()]))
            XCTAssertEqual(TotalPath(data: edited.pages[0].totalPath, pageWidth: 1404, pageHeight: 1872).strokes.count, 1)
        }
    }

    func testAppendPages() throws {
        let note = try NoteFile(data: NoteFactory.blankNote(template: .dots))
        let page = try PageEditor(note: note, index: 0)
        page.addStroke(points: [PagePoint(x: 10, y: 10), PagePoint(x: 50, y: 50)], pressures: [900, 900],
                       pen: .needlePoint, color: .black, widthMM: 0.3)
        let data = try NoteWriter.appendPages(note, count: 2, edits: [0: page.makeEdit()])
        let n = try NoteFile(data: data)
        XCTAssertEqual(n.pages.count, 3)
        XCTAssertEqual(n.pages.map(\.footerKey), ["PAGE1", "PAGE2", "PAGE3"])
        XCTAssertEqual(n.pages[2].style, "style_5mm_dots")
        XCTAssertNotEqual(n.pages[1].pageID, n.pages[2].pageID)
        XCTAssertEqual(TotalPath(data: n.pages[0].totalPath, pageWidth: 1404, pageHeight: 1872).strokes.count, 1)
        _ = try NoteRenderer.render(n, page: 2)
    }
}
