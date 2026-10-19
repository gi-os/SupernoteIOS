import Foundation

// Port of jya-dev/supernotelib parser.py (Apache-2.0) for X / X2-series `.note` files.
//
// Layout: "note" + "SN_FILE_VER_yyyymmdd" signature, then data blocks. The last 4 bytes
// hold the footer address. Every block is <u32 LE length><payload>; metadata blocks are
// `<KEY:VALUE><KEY:VALUE>...` strings that point at other blocks by absolute offset.

public enum NoteError: Error, Equatable {
    case tooShort
    case unsupportedSignature(String)
    case badAddress(Int)
    case missingKey(String)
    case unknownProtocol(String)
    case decodeLengthMismatch(got: Int, expected: Int)
}

/// Ordered `<KEY:VALUE>` parameters. Keys may repeat (e.g. multiple `PAGE` entries).
public struct NoteParams: Sendable {
    public private(set) var entries: [(key: String, value: String)] = []

    public init(_ entries: [(key: String, value: String)] = []) { self.entries = entries }

    public subscript(key: String) -> String? { entries.first { $0.key == key }?.value }
    public func all(_ key: String) -> [String] { entries.filter { $0.key == key }.map(\.value) }
    public func keys(withPrefix prefix: String) -> [String] {
        var seen = Set<String>()
        return entries.map(\.key).filter { $0.hasPrefix(prefix) && seen.insert($0).inserted }
    }
    public func int(_ key: String) -> Int? { self[key].flatMap { Int($0) } }
    mutating func set(_ key: String, _ value: String) {
        if let i = entries.firstIndex(where: { $0.key == key }) { entries[i].value = value } else { entries.append((key, value)) }
    }

    static func parse(_ text: String) -> NoteParams {
        var out: [(String, String)] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "<") {
            guard let colon = text[open...].firstIndex(of: ":"),
                  let close = text[colon...].firstIndex(of: ">") else { break }
            let key = String(text[text.index(after: open)..<colon])
            if key.contains("<") || key.contains(">") { i = text.index(after: open); continue }
            out.append((key, String(text[text.index(after: colon)..<close])))
            i = text.index(after: close)
        }
        return NoteParams(out)
    }
}

public struct NoteLayer: Sendable {
    public var params: NoteParams
    public var bitmap: Data?
    public var name: String { params["LAYERNAME"] ?? "" }
    public var layerProtocol: String? { params["LAYERPROTOCOL"] }
}

public struct NotePage: Sendable {
    public static let layerKeys = ["MAINLAYER", "LAYER1", "LAYER2", "LAYER3", "BGLAYER"]

    public var params: NoteParams
    public var layers: [NoteLayer]
    /// Footer key that points at this page ("PAGE1", "PAGE2", …).
    public var footerKey: String
    /// Vector stroke data (TOTALPATH). Needed later for `.note` write-back / re-rendering.
    public var totalPath: Data?
    public var recognText: Data?

    public var isHorizontal: Bool { ["1090", "1270"].contains(params["ORIENTATION"] ?? "1000") }
    public var style: String? { params["PAGESTYLE"] }
    public var layerOrder: [String] { params["LAYERSEQ"]?.split(separator: ",").map(String.init) ?? [] }
    public var pageID: String? { params["PAGEID"] }
}

public struct NoteFile: Sendable {
    public static let knownSignatures = [
        "SN_FILE_VER_20200001", "SN_FILE_VER_20200005", "SN_FILE_VER_20200006",
        "SN_FILE_VER_20200007", "SN_FILE_VER_20200008", "SN_FILE_VER_20210009",
        "SN_FILE_VER_20210010", "SN_FILE_VER_20220011", "SN_FILE_VER_20220013",
        "SN_FILE_VER_20230014", "SN_FILE_VER_20230015", "SN_FILE_VER_20260016",
    ]

    public var fileType: String
    public var signature: String
    public var header: NoteParams
    public var footer: NoteParams
    public var pages: [NotePage]
    /// The file bytes this was parsed from (edits are appended to these).
    public let raw: Data

    /// Device that produced the file (e.g. "N5" = Manta). Nomad / A6X2 / A5X share 1404x1872.
    public var equipment: String? { header["APPLY_EQUIPMENT"] }
    public var pageSize: (width: Int, height: Int) {
        equipment == "N5" ? (1920, 2560) : (1404, 1872)
    }
    /// X2 firmware (Nomad / Manta) uses the high-res grayscale RLE palette.
    public var supportsHighResGrayscale: Bool {
        (Int(signature.suffix(8)) ?? 0) >= 20230015
    }

    public init(data: Data, strict: Bool = false) throws {
        let reader = BlockReader(data: data)
        raw = data
        guard data.count > 24 else { throw NoteError.tooShort }
        fileType = String(decoding: data.prefix(4), as: UTF8.self)
        let sig = String(decoding: data[data.startIndex + 4 ..< data.startIndex + 24], as: UTF8.self)
        let looksValid = sig.hasPrefix("SN_FILE_VER_") && sig.suffix(8).allSatisfy(\.isNumber)
        if !Self.knownSignatures.contains(sig) && (strict || !looksValid) {
            throw NoteError.unsupportedSignature(sig)
        }
        signature = sig

        let footerAddress = try reader.u32(at: data.count - 4)
        let footer = try reader.params(at: footerAddress)
        self.footer = footer
        header = try reader.params(at: footer.int("FILE_FEATURE") ?? 0)

        pages = try footer.keys(withPrefix: "PAGE").compactMap { key in footer.int(key).map { (key, $0) } }.map { key, addr in
            let p = try reader.params(at: addr)
            var layers: [NoteLayer] = []
            for key in NotePage.layerKeys {
                guard let la = p.int(key) else { continue }
                var lp = try reader.params(at: la)
                let bitmap = try lp.int("LAYERBITMAP").flatMap { try reader.block(at: $0) }
                // Workaround from supernotelib: a second MAINLAYER is actually the background.
                if lp["LAYERNAME"] == "MAINLAYER", layers.contains(where: { $0.name == "MAINLAYER" }) {
                    lp.set("LAYERNAME", "BGLAYER")
                }
                layers.append(NoteLayer(params: lp, bitmap: bitmap))
            }
            if layers.isEmpty, let dataAddr = p.int("DATA") {
                // Pre-layer files: a single bitmap that behaves like MAINLAYER.
                var lp = NoteParams([("LAYERNAME", "MAINLAYER")])
                if let proto = p["PROTOCOL"] { lp.set("LAYERPROTOCOL", proto) }
                layers.append(NoteLayer(params: lp, bitmap: try reader.block(at: dataAddr)))
            }
            return NotePage(
                params: p,
                layers: layers,
                footerKey: key,
                totalPath: try p.int("TOTALPATH").flatMap { try reader.block(at: $0) },
                recognText: try p.int("RECOGNTEXT").flatMap { try reader.block(at: $0) }
            )
        }
    }

    /// Serializes params back to the `<KEY:VALUE>` block format.
    static func serialize(_ p: NoteParams) -> Data {
        Data(p.entries.map { "<\($0.key):\($0.value)>" }.joined().utf8)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }
}

struct BlockReader {
    let data: Data

    func u32(at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else { throw NoteError.badAddress(offset) }
        let b = data.startIndex + offset
        return Int(data[b]) | Int(data[b + 1]) << 8 | Int(data[b + 2]) << 16 | Int(data[b + 3]) << 24
    }

    /// Returns nil for address 0 (supernotelib convention: "no block").
    func block(at address: Int) throws -> Data? {
        guard address != 0 else { return nil }
        let len = try u32(at: address)
        let start = address + 4
        guard start + len <= data.count else { throw NoteError.badAddress(address) }
        return data.subdata(in: data.startIndex + start ..< data.startIndex + start + len)
    }

    func params(at address: Int) throws -> NoteParams {
        guard let raw = try block(at: address) else { return NoteParams() }
        return NoteParams.parse(String(decoding: raw, as: UTF8.self))
    }
}
