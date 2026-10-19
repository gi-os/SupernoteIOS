import Foundation
import NoteKit
import SyncKit

// snsync — CLI harness for SyncKit / NoteKit (runs on macOS and Linux).
//
//   snsync info   <file.note>
//   snsync render <file.note> <out-dir>          # one PGM per page
//   snsync strokes <file.note> [page]            # pen type / color / width per stroke
//   snsync scribble <in.note> <out.note> [page]   # write-back test: draws a test stroke
//   snsync new <out.note> [blank|dots] [pages]   # device-style new note
//   snsync ls                                     # needs SN_SERVER / SN_ACCOUNT / SN_PASSWORD
//   snsync sync   <mirror-dir>
//
// Env: SN_SERVER (default https://cloud.supernote.com), SN_ACCOUNT, SN_PASSWORD,
//      SN_EQUIPMENT (stable fake serial; generated + printed if unset), SN_DEVICE_NAME.

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func connect() async throws -> SupernoteClient {
    guard let account = env["SN_ACCOUNT"], let password = env["SN_PASSWORD"] else {
        fail("set SN_ACCOUNT and SN_PASSWORD")
    }
    let server = URL(string: env["SN_SERVER"] ?? "https://cloud.supernote.com")!
    let name = env["SN_DEVICE_NAME"] ?? "snsync"
    let identity: DeviceIdentity
    if let eq = env["SN_EQUIPMENT"] {
        identity = DeviceIdentity(equipmentNo: eq, name: name)
    } else {
        identity = .generate(name: name)
        print("note: using new equipmentNo \(identity.equipmentNo) — export SN_EQUIPMENT to keep it")
    }
    let client = SupernoteClient(baseURL: server, identity: identity)
    try await client.login(account: account, password: password)
    return client
}

do {
    switch args.first {
    case "info":
        guard args.count == 2 else { fail("usage: snsync info <file.note>") }
        let note = try NoteFile(contentsOf: URL(fileURLWithPath: args[1]))
        print("type=\(note.fileType) signature=\(note.signature) equipment=\(note.equipment ?? "?")")
        print("size=\(note.pageSize.width)x\(note.pageSize.height) pages=\(note.pages.count) x2=\(note.supportsHighResGrayscale)")
        for (i, p) in note.pages.enumerated() {
            let layers = p.layers.map { "\($0.name)(\($0.bitmap?.count ?? 0)B)" }.joined(separator: " ")
            print("  page \(i + 1): style=\(p.style ?? "-") \(p.isHorizontal ? "landscape" : "portrait") \(layers)")
            if let text = NoteRenderer.recognizedText(p) { print("    text: \(text.prefix(80))") }
        }

    case "render":
        guard args.count == 3 else { fail("usage: snsync render <file.note> <out-dir>") }
        let note = try NoteFile(contentsOf: URL(fileURLWithPath: args[1]))
        let out = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for i in note.pages.indices {
            let img = try NoteRenderer.render(note, page: i)
            let f = out.appendingPathComponent(String(format: "page-%03d.pgm", i + 1))
            try img.pgm().write(to: f)
            print(f.path)
        }

    case "strokes":
        guard args.count >= 2 else { fail("usage: snsync strokes <file.note> [page]") }
        let note = try NoteFile(contentsOf: URL(fileURLWithPath: args[1]))
        let pageIndex = (args.count > 2 ? Int(args[2]) ?? 1 : 1) - 1
        let tp = TotalPath(data: note.pages[pageIndex].totalPath, pageWidth: note.pageSize.width, pageHeight: note.pageSize.height)
        print("objects=\(tp.objects.count) strokes=\(tp.strokes.count)")
        for (i, s) in tp.strokes.enumerated() {
            let b = s.bounds
            print(String(format: "  #%d pen=%u color=%u width=%u layer=%u points=%d contours=%d bbox=(%.0f,%.0f)-(%.0f,%.0f)",
                         i, s.penType, s.color, s.width, s.layer, s.points.count, s.contours.count, b.minX, b.minY, b.maxX, b.maxY))
        }

    case "scribble":
        guard args.count >= 3 else { fail("usage: snsync scribble <in.note> <out.note> [page]") }
        let note = try NoteFile(contentsOf: URL(fileURLWithPath: args[1]))
        let pageIndex = (args.count > 3 ? Int(args[3]) ?? 1 : 1) - 1
        let editor = try PageEditor(note: note, index: pageIndex)
        // A wave across the lower part of the page in each pen, so it's easy to spot on the Nomad.
        for (row, pen) in PenType.allCases.enumerated() {
            let y = Double(editor.height) - 300 + Double(row) * 70
            let pts = (0 ..< 120).map { PagePoint(x: 150 + Double($0) * 9, y: y + sin(Double($0) / 6) * 20) }
            let pressure = (0 ..< 120).map { UInt16(800 + ($0 * 25) % 2500) }
            editor.addStroke(points: pts, pressures: pressure, pen: pen, color: row == 1 ? .darkGray : .black,
                             widthMM: pen == .marker ? 1.5 : 0.4)
        }
        let data = try NoteWriter.write(note, edits: [pageIndex: editor.makeEdit()])
        try data.write(to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2]) (+\(data.count - note.raw.count) bytes, \(editor.strokes.count) strokes on page \(pageIndex + 1))")

    case "new":
        guard args.count >= 2 else { fail("usage: snsync new <out.note> [blank|dots] [pages]") }
        let t: NoteFactory.Template = args.count > 2 && args[2] == "dots" ? .dots : .blank
        var data = NoteFactory.blankNote(template: t)
        if args.count > 3, let n = Int(args[3]), n > 1 {
            data = try NoteWriter.appendPages(try NoteFile(data: data), count: n - 1)
        }
        try data.write(to: URL(fileURLWithPath: args[1]))
        print("wrote \(args[1])")

    case "ls":
        let client = try await connect()
        for e in try await client.list() {
            print("\(e.isFolder ? "d" : "-") \(e.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(e.contentHash ?? "".padding(toLength: 32, withPad: " ", startingAt: 0)) \(e.relativePath)")
        }

    case "sync":
        guard args.count == 2 else { fail("usage: snsync sync <mirror-dir>") }
        let client = try await connect()
        let engine = SyncEngine(client: client, root: URL(fileURLWithPath: args[1]))
        let report = try await engine.sync()
        print(report)
        report.conflicts.forEach { print("  conflict: \($0)") }

    default:
        fail("commands: info | render | strokes | scribble | new | ls | sync")
    }
} catch {
    fail("\(error)")
}
