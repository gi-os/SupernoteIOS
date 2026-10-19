import Foundation

// Port of supernotelib RattaRleDecoder / RattaRleX2Decoder (Apache-2.0).
// Output is 8-bit grayscale; 0xFF means transparent.

public enum Gray {
    public static let black: UInt8 = 0x00
    public static let darkGray: UInt8 = 0x9D
    public static let gray: UInt8 = 0xC9
    public static let white: UInt8 = 0xFE
    public static let transparent: UInt8 = 0xFF
    static let darkGrayCompat: UInt8 = 0x30
    static let grayCompat: UInt8 = 0x50
}

public enum RattaRLE {
    static let specialLengthMarker: UInt8 = 0xFF
    static let specialLength = 0x4000
    static let specialLengthForBlank = 0x400

    static func colormap(x2: Bool) -> [UInt8: UInt8] {
        var map: [UInt8: UInt8] = [
            0x61: Gray.black,
            0x62: Gray.transparent,
            0x65: Gray.white,
            0x66: Gray.black, // marker black
        ]
        if x2 {
            map[0x9D] = Gray.darkGray; map[0xC9] = Gray.gray
            map[0x9E] = Gray.darkGray; map[0xCA] = Gray.gray
            map[0x63] = Gray.darkGrayCompat; map[0x64] = Gray.grayCompat
        } else {
            map[0x63] = Gray.darkGray; map[0x64] = Gray.gray
            map[0x67] = Gray.darkGray; map[0x68] = Gray.gray
        }
        return map
    }

    /// - Parameters:
    ///   - allBlank: hint for the blank "style_white" background layer.
    ///   - x2: use the X2-series (Nomad / Manta) palette.
    public static func decode(_ data: Data, width: Int, height: Int, allBlank: Bool = false, x2: Bool) throws -> [UInt8] {
        let map = colormap(x2: x2)
        var lut = [UInt8](repeating: Gray.transparent, count: 256)
        for v in 0 ..< 256 {
            // X2: unknown codes are literal gray values; X: fall back to transparent.
            lut[v] = map[UInt8(v)] ?? (x2 ? UInt8(v) : Gray.transparent)
        }
        return try decodeCodes(data, width: width, height: height, allBlank: allBlank).map { lut[Int($0)] }
    }

    /// Raw RLE color codes (0x62 = transparent) — the editable form of a layer.
    public static func decodeCodes(_ data: Data, width: Int, height: Int, allBlank: Bool = false) throws -> [UInt8] {
        let expected = width * height
        var out = [UInt8]()
        out.reserveCapacity(expected)

        func emit(_ code: UInt8, _ length: Int) {
            out.append(contentsOf: repeatElement(code, count: length))
        }

        var holder: (code: UInt8, length: UInt8)?
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            let code = bytes[i]
            var length = Int(bytes[i + 1])
            i += 2
            var pushed = false

            if let (prevCode, prevLength) = holder {
                holder = nil
                if code == prevCode {
                    length = 1 + length + ((Int(prevLength & 0x7F) + 1) << 7)
                    emit(code, length)
                    pushed = true
                } else {
                    emit(prevCode, (Int(prevLength & 0x7F) + 1) << 7)
                }
            }

            if !pushed {
                if UInt8(length) == specialLengthMarker {
                    emit(code, allBlank ? specialLengthForBlank : specialLength)
                } else if length & 0x80 != 0 {
                    holder = (code, UInt8(length))
                } else {
                    emit(code, length + 1)
                }
            }
        }

        if let (code, length) = holder {
            let gap = expected - out.count
            for shift in stride(from: 7, through: 0, by: -1) {
                let l = (Int(length & 0x7F) + 1) << shift
                if l <= gap { emit(code, l); break }
            }
        }

        guard out.count == expected else {
            throw NoteError.decodeLengthMismatch(got: out.count, expected: expected)
        }
        return out
    }

    public static let transparentCode: UInt8 = 0x62

    /// Inverse of `decodeCodes`. Runs > 128 use the two-pair form (c, 0x80|h)(c, low);
    /// runs of exactly 0x4000 use the 0xFF marker.
    public static func encode(_ codes: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(codes.count / 8)
        var i = 0
        while i < codes.count {
            let c = codes[i]
            var j = i + 1
            while j < codes.count && codes[j] == c { j += 1 }
            var n = j - i
            while n > 0 {
                if n >= specialLength {
                    out += [c, specialLengthMarker]; n -= specialLength
                } else if n > 128 {
                    let h = (n - 1) >> 7          // 1...127
                    let low = (n - 1) & 0x7F
                    out += [c, UInt8(0x80 | (h - 1)), c, UInt8(low)]
                    n = 0
                } else {
                    out += [c, UInt8(n - 1)]; n = 0
                }
            }
            i = j
        }
        return Data(out)
    }
}
