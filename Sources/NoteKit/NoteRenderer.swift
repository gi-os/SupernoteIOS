import Foundation

/// 8-bit grayscale page image. 0xFF = paper / transparent.
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    /// Binary PGM, handy for CLI debugging (`snsync render`).
    public func pgm() -> Data {
        var d = Data("P5\n\(width) \(height)\n255\n".utf8)
        d.append(contentsOf: pixels)
        return d
    }
}

public enum NoteRenderer {
    /// Flattens all visible layers of a page, matching supernotelib's ImageConverter.
    public static func render(_ note: NoteFile, page index: Int) throws -> GrayImage {
        let page = note.pages[index]
        var (w, h) = note.pageSize
        if page.isHorizontal { swap(&w, &h) }

        var canvas = [UInt8](repeating: Gray.white, count: w * h)
        let visibility = layerVisibility(page)
        let order = page.layerOrder.isEmpty ? NotePage.layerKeys : page.layerOrder

        // LAYERSEQ lists top-most first; paint bottom-up.
        for name in order.reversed() where visibility[name] ?? true {
            guard let layer = page.layers.first(where: { $0.name == name }), let bitmap = layer.bitmap else { continue }
            if name == "BGLAYER", page.style?.hasPrefix("user_") == true {
                // Custom template: the layer is a plain PNG (needs ImageIO, so Apple platforms only).
                if let px = decodePNG(bitmap, width: w, height: h) { canvas = px }
                continue
            }
            guard layer.layerProtocol == "RATTA_RLE" else {
                throw NoteError.unknownProtocol(layer.layerProtocol ?? "nil")
            }
            let allBlank = name == "BGLAYER" && page.style == "style_white" && bitmap.count == 0x140E
            let px = try RattaRLE.decode(bitmap, width: w, height: h, allBlank: allBlank,
                                         x2: note.supportsHighResGrayscale)
            for i in 0 ..< px.count where px[i] != Gray.transparent {
                canvas[i] = px[i]
            }
        }
        return GrayImage(width: w, height: h, pixels: canvas)
    }

    static func layerVisibility(_ page: NotePage) -> [String: Bool] {
        guard var info = page.params["LAYERINFO"], info != "none" else { return [:] }
        info = info.replacingOccurrences(of: "#", with: ":")
        var json = Data(info.utf8)
        if (try? JSONSerialization.jsonObject(with: json)) == nil, let decoded = Data(base64Encoded: info) {
            json = decoded
        }
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [:] }

        var vis: [String: Bool] = [:]
        for l in arr {
            let isBG = l["isBackgroundLayer"] as? Bool ?? false
            let id = l["layerId"] as? Int ?? -1
            let visible = l["isVisible"] as? Bool ?? true
            if isBG { vis["BGLAYER"] = visible }
            else if id == 0 { vis["MAINLAYER"] = visible }
            else { vis["LAYER\(id)"] = visible }
        }
        if vis["MAINLAYER"] == nil { vis["MAINLAYER"] = true }
        return vis
    }

    /// Handwriting recognition text (if the device ran realtime recognition).
    public static func recognizedText(_ page: NotePage) -> String? {
        guard let raw = page.recognText, let json = Data(base64Encoded: raw),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let elements = obj["elements"] as? [[String: Any]] else { return nil }
        let lines = elements.filter { $0["type"] as? String == "Text" }.compactMap { $0["label"] as? String }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO

extension NoteRenderer {
    static func decodePNG(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: Gray.white, count: width * height)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }
}

extension GrayImage {
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#else
extension NoteRenderer {
    static func decodePNG(_ data: Data, width: Int, height: Int) -> [UInt8]? { nil }
}
#endif
