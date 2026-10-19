import Foundation
import XCTest
@testable import NoteKit
import SyncKit

final class NoteKitTests: XCTestCase {
    func fixture(_ name: String) throws -> NoteFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "note"))
        return try NoteFile(contentsOf: url)
    }

    func testParsesNomadNote() throws {
        let note = try fixture("nomad_portrait")
        XCTAssertEqual(note.fileType, "note")
        XCTAssertEqual(note.equipment, "N6")          // N6 = Nomad (A6X2)
        XCTAssertTrue(note.supportsHighResGrayscale)
        XCTAssertEqual(note.pageSize.width, 1404)
        XCTAssertEqual(note.pageSize.height, 1872)
        XCTAssertEqual(note.pages.count, 1)
        XCTAssertNotNil(note.pages[0].layers.first { $0.name == "MAINLAYER" }?.bitmap)
    }

    // Hashes match supernotelib's ImageConverter output pixel-for-pixel.
    func testRenderMatchesSupernotelibPortrait() throws {
        let img = try NoteRenderer.render(try fixture("nomad_portrait"), page: 0)
        XCTAssertEqual(img.width, 1404); XCTAssertEqual(img.height, 1872)
        XCTAssertEqual(Data(img.pixels).supernoteMD5, "84592052e687da50cdf496d064cee023")
    }

    func testRenderMatchesSupernotelibLandscape() throws {
        let note = try fixture("nomad_landscape")
        XCTAssertTrue(note.pages[0].isHorizontal)
        let img = try NoteRenderer.render(note, page: 0)
        XCTAssertEqual(img.width, 1872); XCTAssertEqual(img.height, 1404)
        XCTAssertEqual(Data(img.pixels).supernoteMD5, "e51c96f9fa1e429bad8f3672960de4dd")
    }

    func testParamsKeepDuplicateKeysInOrder() {
        let p = NoteParams.parse("<PAGE1:10><TITLE_00010001:5><TITLE_00010001:9><X:a:b>")
        XCTAssertEqual(p.int("PAGE1"), 10)
        XCTAssertEqual(p.all("TITLE_00010001"), ["5", "9"])
        XCTAssertEqual(p["X"], "a:b")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try NoteFile(data: Data(repeating: 0, count: 64)))
    }

    func testRLEBasicRuns() throws {
        // 0x61 (black) x3, 0x62 (transparent) x1 => 4 px
        let px = try RattaRLE.decode(Data([0x61, 0x02, 0x62, 0x00]), width: 4, height: 1, x2: true)
        XCTAssertEqual(px, [Gray.black, Gray.black, Gray.black, Gray.transparent])
    }
}
