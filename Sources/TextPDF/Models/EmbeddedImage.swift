//
//  EmbeddedImage.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  An image carried inside the PDF.
//
//  JPEG is the one format a PDF takes without decoding: the compressed bytes
//  go in exactly as they arrived, under `/DCTDecode`, and the reader does the
//  work. Nothing else is that easy.
//
//  PNG has to be decoded and re-compressed, because its zlib runs over
//  filtered scanlines and PDF's `/FlateDecode` runs over raw ones. The system
//  supplies both halves — ImageIO reads the pixels, Compression deflates them
//  — so this stays free of any package dependency while being lossless in both
//  directions. Transparency becomes a soft mask, because PDF has no notion of
//  an alpha channel inside an image and a cut-out logo without one arrives on
//  a black square.
//

import CoreGraphics
import Foundation
import ImageIO

/// An image embedded in the document.
public final class EmbeddedImage: @unchecked Sendable {

    /// Pixel dimensions, as the file declares them.
    public let width: Int
    public let height: Int

    /// The bytes as they go into the file.
    let data: Data

    /// 1 for greyscale, 3 for colour.
    let components: Int

    /// How the reader should decode them.
    let filter: Filter

    /// Per-pixel transparency, where the source had any.
    ///
    /// A separate greyscale image the reader multiplies through. PDF has no
    /// notion of an alpha channel inside an image; a soft mask is how
    /// transparency is expressed, and without one a cut-out logo arrives on a
    /// black square.
    let alpha: Data?

    enum Filter: String {
        case dct = "DCTDecode"
        case flate = "FlateDecode"
        case none = ""
    }

    private init(
        width: Int, height: Int, components: Int,
        data: Data, filter: Filter, alpha: Data? = nil
    ) {
        self.width = width
        self.height = height
        self.components = components
        self.data = data
        self.filter = filter
        self.alpha = alpha
    }

    /// The aspect ratio, for sizing a box to the image rather than the reverse.
    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 1
    }

    // MARK: Loading

    /// Loads a `.jpg` or `.png` from disk.
    public static func load(_ url: URL) throws -> EmbeddedImage {
        guard let data = try? Data(contentsOf: url) else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        return try decode(data, named: url.lastPathComponent)
    }

    /// The eight bytes every PNG starts with.
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Reads a PNG's pixels out and re-compresses them for the file.
    ///
    /// A PNG cannot be passed through the way a JPEG can: its compression is
    /// zlib over filtered scanlines, and PDF's FlateDecode is zlib over raw
    /// ones. So the image is decoded, the rows are taken unfiltered, and the
    /// result is deflated again. Lossless both ways — the pixels that come out
    /// are the pixels that went in.
    static func png(_ data: Data, named name: String) throws -> EmbeddedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageError.undecodable(name)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ImageError.undecodable(name) }

        // Redrawn into a known layout rather than trusted: a PNG can be
        // indexed, sixteen bits a channel, or greyscale with alpha, and
        // reading whichever it happens to be is the codec this avoids being.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageError.undecodable(name)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colour = [UInt8](); colour.reserveCapacity(width * height * 3)
        var mask = [UInt8](); mask.reserveCapacity(width * height)
        var transparent = false

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[index + 3]
            if a != 255 { transparent = true }

            // The context premultiplied; PDF wants the colour back out of it,
            // or a semi-transparent pixel arrives darkened by its own alpha.
            if a == 0 {
                colour.append(contentsOf: [0, 0, 0])
            } else if a == 255 {
                colour.append(contentsOf: [pixels[index], pixels[index + 1], pixels[index + 2]])
            } else {
                let scale = 255.0 / Double(a)
                colour.append(UInt8(min(255, Double(pixels[index]) * scale)))
                colour.append(UInt8(min(255, Double(pixels[index + 1]) * scale)))
                colour.append(UInt8(min(255, Double(pixels[index + 2]) * scale)))
            }
            mask.append(a)
        }

        let raw = Data(colour)
        let packed = Deflate.zlib(raw)

        return EmbeddedImage(
            width: width, height: height, components: 3,
            data: packed ?? raw,
            filter: packed == nil ? .none : .flate,
            alpha: transparent ? (Deflate.zlib(Data(mask)) ?? Data(mask)) : nil
        )
    }

    /// Reads the dimensions and colour model out of JPEG bytes.
    ///
    /// Only the frame header is parsed. Everything else — the tables, the
    /// entropy-coded scan — is what gets handed to the reader verbatim, so
    /// there is nothing to be gained by understanding it here.
    static func decode(_ data: Data, named name: String) throws -> EmbeddedImage {
        let bytes = [UInt8](data)

        if bytes.count > 8, Array(bytes[0..<8]) == pngSignature {
            return try png(data, named: name)
        }
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw ImageError.unsupportedFormat(name)
        }

        var index = 2
        while index + 3 < bytes.count {
            // Segments begin with 0xFF; padding bytes of 0xFF are legal.
            guard bytes[index] == 0xFF else { index += 1; continue }

            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }

            // Standalone markers carry no length.
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            guard index + 3 < bytes.count else { break }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { break }

            switch marker {
            // Baseline and the extended/arithmetic baselines.
            case 0xC0, 0xC1, 0xC9, 0xCB:
                guard index + 9 < bytes.count else { throw ImageError.unsupportedFormat(name) }
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                let components = Int(bytes[index + 9])

                guard width > 0, height > 0 else { throw ImageError.unsupportedFormat(name) }
                guard components == 1 || components == 3 else {
                    throw ImageError.unsupportedColour(name, components)
                }
                // Passed through exactly as it arrived — that is the whole
                // point of DCTDecode.
                return EmbeddedImage(width: width, height: height,
                                     components: components, data: data, filter: .dct)

            // Progressive. The bytes would embed and most readers would show
            // nothing, so it is named rather than passed through.
            case 0xC2, 0xCA:
                throw ImageError.progressive(name)

            default:
                index += 2 + length
            }
        }
        throw ImageError.unsupportedFormat(name)
    }

    // MARK: Emitting

    /// The XObject dictionary and the bytes it wraps.
    ///
    /// `mask` is the object number of the soft mask, where there is one.
    func xobject(mask: Int? = nil) -> (dictionary: String, bytes: Data) {
        let space = components == 1 ? "DeviceGray" : "DeviceRGB"
        var dictionary = "<</Type /XObject /Subtype /Image "
            + "/Width \(width) /Height \(height) /ColorSpace /\(space) "
            + "/BitsPerComponent 8"
        if filter != .none { dictionary += " /Filter /\(filter.rawValue)" }
        if let mask { dictionary += " /SMask \(mask) 0 R" }
        dictionary += " /Length \(data.count)>>"
        return (dictionary, data)
    }

    /// The soft mask, where the source carried transparency.
    func maskObject() -> (dictionary: String, bytes: Data)? {
        guard let alpha else { return nil }
        let dictionary = "<</Type /XObject /Subtype /Image "
            + "/Width \(width) /Height \(height) /ColorSpace /DeviceGray "
            + "/BitsPerComponent 8 /Filter /FlateDecode /Length \(alpha.count)>>"
        return (dictionary, alpha)
    }
}

// MARK: - Errors

/// Why an image could not be embedded, each with the command that fixes it.
public enum ImageError: Error, LocalizedError, Equatable {

    case unreadable(String)
    case unsupportedFormat(String)
    case undecodable(String)
    case progressive(String)
    case unsupportedColour(String, Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read \(name)."
        case .unsupportedFormat(let name):
            return "\(name) is neither a JPEG nor a PNG. Convert with: sips -s format jpeg in.tiff --out out.jpg"
        case .undecodable(let name):
            return "\(name) is a PNG the system could not read. It may be truncated."
        case .progressive(let name):
            return "\(name) is a progressive JPEG. It would embed without complaint and show as nothing in most readers. Re-save it as baseline: sips -s format jpeg \(name) --out baseline.jpg"
        case .unsupportedColour(let name, let components):
            return "\(name) has \(components) colour components. Only greyscale and RGB are supported; a CMYK JPEG needs an ICC profile and a /Decode array this writer does not produce."
        }
    }
}
