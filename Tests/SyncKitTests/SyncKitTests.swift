import Foundation
import XCTest
@testable import SyncKit

final class SyncKitTests: XCTestCase {
    func testPasswordHash() {
        // SHA256(MD5("password") + "abc")
        XCTAssertEqual(Hashing.md5Hex(Data("password".utf8)), "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertEqual(Hashing.password("password", randomCode: "abc"),
                       Hashing.sha256Hex("5f4dcc3b5aa765d61d8327deb882cf99abc"))
    }

    func testDecodesListEntry() throws {
        let json = #"{"success":true,"entries":[{"id":123,"name":"a.note","tag":"file","path_display":"/Note/a.note","content_hash":"x","lastUpdateTime":1}]}"#
        let res = try JSONDecoder().decode(ListFolderResponse.self, from: Data(json.utf8))
        XCTAssertEqual(res.entries[0].id, "123")
        XCTAssertEqual(res.entries[0].relativePath, "Note/a.note")
        XCTAssertFalse(res.entries[0].isFolder)
    }

    typealias R = SyncPlanner.Remote

    func plan(_ remote: [String: R], _ local: [String: String], _ base: [String: String]) -> [SyncAction] {
        SyncPlanner.plan(remote: remote, local: local, base: base, deviceName: "iPad")
    }

    func testNewOnEachSide() {
        XCTAssertEqual(plan(["Note/r.note": R(id: "1", md5: "a")], ["Note/l.note": "b"], [:]),
                       [.upload(path: "Note/l.note"), .download(path: "Note/r.note", id: "1")])
    }

    func testOneSidedEdits() {
        let base = ["n": "old"]
        XCTAssertEqual(plan(["n": R(id: "1", md5: "new")], ["n": "old"], base), [.download(path: "n", id: "1")])
        XCTAssertEqual(plan(["n": R(id: "1", md5: "old")], ["n": "new"], base), [.upload(path: "n")])
        XCTAssertEqual(plan(["n": R(id: "1", md5: "same")], ["n": "same"], base), [])
    }

    func testDeletesPropagateOnlyWhenUnchanged() {
        let base = ["n": "old"]
        XCTAssertEqual(plan([:], ["n": "old"], base), [.deleteLocal(path: "n")])
        XCTAssertEqual(plan([:], ["n": "edited"], base), [.upload(path: "n")])
        XCTAssertEqual(plan(["n": R(id: "1", md5: "old")], [:], base), [.deleteRemote(path: "n", id: "1")])
        XCTAssertEqual(plan(["n": R(id: "1", md5: "edited")], [:], base), [.download(path: "n", id: "1")])
    }

    func testConflict() {
        XCTAssertEqual(plan(["Note/a.note": R(id: "1", md5: "r")], ["Note/a.note": "l"], ["Note/a.note": "s"]),
                       [.conflict(path: "Note/a.note", id: "1", conflictPath: "Note/a (conflict iPad).note")])
    }
}
