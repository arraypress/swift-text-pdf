//
//  EmbeddedImage.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A JPEG carried inside the PDF.
//
//  JPEG is the one image format a PDF can take without decoding: the
//  compressed bytes go in exactly as they arrived, under `/DCTDecode`, and the
//  reader does the work. That makes image support about a hundred lines rather
//  than a codec, and it is why this handles JPEG and nothing else.
//
//  PNG would mean inflating the file, un-filtering the scanlines, and
//  re-deflating the result — a zlib implementation and a lot of surface area
//  for a writer whose selling point is having no dependencies. Converting a
//  PNG to a JPEG first is one command, and it is the caller's decision what
//  quality to lose.
//

import Foundation

/// A JPEG image embedded in the document.
public final class EmbeddedImage: @unchecked Sendable {

    /// Pixel dimensions, as the file declares them.
    public let width: Int
    public let height: Int

    /// The original bytes, passed through untouched.
    let data: Data

    /// 1 for greyscale, 3 for colour.
    let components: Int

    private init(width: Int, height: Int, components: Int, data: Data) {
        self.width = width
        self.height = height
        self.components = components
        self.data = data
    }

    /// The aspect ratio, for sizing a box to the image rather than the reverse.
    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 1
    }

    // MARK: Loading

    /// Loads a `.jpg` from disk.
    public static func load(_ url: URL) throws -> EmbeddedImage {
        guard let data = try? Data(contentsOf: url) else {
            throw ImageError.unreadable(url.lastPathComponent)
        }
        return try decode(data, named: url.lastPathComponent)
    }

    /// Reads the dimensions and colour model out of JPEG bytes.
    ///
    /// Only the frame header is parsed. Everything else — the tables, the
    /// entropy-coded scan — is what gets handed to the reader verbatim, so
    /// there is nothing to be gained by understanding it here.
    static func decode(_ data: Data, named name: String) throws -> EmbeddedImage {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw ImageError.notJPEG(name)
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
                guard index + 9 < bytes.count else { throw ImageError.notJPEG(name) }
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                let components = Int(bytes[index + 9])

                guard width > 0, height > 0 else { throw ImageError.notJPEG(name) }
                guard components == 1 || components == 3 else {
                    throw ImageError.unsupportedColour(name, components)
                }
                return EmbeddedImage(width: width, height: height,
                                     components: components, data: data)

            // Progressive. The bytes would embed and most readers would show
            // nothing, so it is named rather than passed through.
            case 0xC2, 0xCA:
                throw ImageError.progressive(name)

            default:
                index += 2 + length
            }
        }
        throw ImageError.notJPEG(name)
    }

    // MARK: Emitting

    /// The XObject dictionary and the bytes it wraps.
    func xobject() -> (dictionary: String, bytes: Data) {
        let space = components == 1 ? "DeviceGray" : "DeviceRGB"
        let dictionary = "<</Type /XObject /Subtype /Image "
            + "/Width \(width) /Height \(height) /ColorSpace /\(space) "
            + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(data.count)>>"
        return (dictionary, data)
    }
}

// MARK: - Errors

public enum ImageError: Error, LocalizedError, Equatable {

    case unreadable(String)
    case notJPEG(String)
    case progressive(String)
    case unsupportedColour(String, Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read \(name)."
        case .notJPEG(let name):
            return "\(name) is not a baseline JPEG. Only JPEG is supported — its bytes go into the PDF undecoded, which is what keeps this writer free of an image codec. Convert with: sips -s format jpeg in.png --out out.jpg"
        case .progressive(let name):
            return "\(name) is a progressive JPEG. It would embed without complaint and show as nothing in most readers. Re-save it as baseline: sips -s format jpeg \(name) --out baseline.jpg"
        case .unsupportedColour(let name, let components):
            return "\(name) has \(components) colour components. Only greyscale and RGB are supported; a CMYK JPEG needs an ICC profile and a /Decode array this writer does not produce."
        }
    }
}
