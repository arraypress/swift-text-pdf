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

    // Internal rather than private: the codecs in Internal/ImageCodec
    // construct through this.
    init(
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
