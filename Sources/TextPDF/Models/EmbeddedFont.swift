//
//  EmbeddedFont.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A font carried inside the PDF, so text outside Latin-1 can be drawn.
//
//  The base-14 fonts every reader is required to have cover Windows-1252 and
//  nothing else, which is why a Cyrillic or CJK name comes out as question
//  marks. Embedding lifts that: characters are written as glyph IDs under
//  Identity-H, and the glyphs travel with the document.
//
//  What this does not do is reorder or reshape text. Arabic and Hebrew are
//  right-to-left, and Arabic letters change form by position; drawing their
//  code points in logical order produces disconnected letters in the wrong
//  sequence. That needs a shaping engine, so those scripts are refused rather
//  than rendered wrongly.
//

import CoreText
import Foundation

/// A TrueType font embedded in the document.
public final class EmbeddedFont: @unchecked Sendable {

    /// The PostScript name written into the PDF.
    public let name: String

    /// Design units per em, for scaling advances.
    let unitsPerEm: Int

    private let font: CTFont
    private let source: TrueTypeFont

    /// Glyphs in the order they were first drawn; the index is the CID.
    ///
    /// The CID has to be settled when the text is written, long before the
    /// subset is built, so it is assigned here and the subset is made to fit
    /// rather than the other way round.
    private var order: [Int] = [0]

    /// The reverse of `order`.
    private var cids: [Int: Int] = [0: 0]

    /// Character-to-glyph results, cached because a document repeats text.
    private var glyphCache: [UInt32: Int] = [:]

    /// Which Unicode scalar produced each glyph, for the ToUnicode map.
    private var reverse: [Int: UInt32] = [:]

    private let lock = NSLock()

    // MARK: Loading

    /// Loads a `.ttf` from disk.
    ///
    /// TrueType outlines only. A `.otf` with PostScript outlines needs a
    /// different PDF font type, and a `.ttc` is a collection rather than one
    /// font — both are refused with a reason rather than embedded wrongly.
    public static func load(_ url: URL) throws -> EmbeddedFont {
        guard let data = try? Data(contentsOf: url) else {
            throw EmbeddingError.unreadable(url.lastPathComponent)
        }
        guard let parsed = TrueTypeFont(data: data) else {
            throw EmbeddingError.unsupportedFormat(url.lastPathComponent)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider)
        else {
            throw EmbeddingError.unreadable(url.lastPathComponent)
        }

        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 1000, nil, nil)
        let postScript = (CTFontCopyPostScriptName(ctFont) as String)
        return EmbeddedFont(name: postScript, font: ctFont, source: parsed)
    }

    private init(name: String, font: CTFont, source: TrueTypeFont) {
        // A PDF name cannot carry spaces or delimiters.
        self.name = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" }
        self.font = font
        self.source = source
        self.unitsPerEm = source.unitsPerEm
    }

    // MARK: Measuring and mapping

    /// The glyph for a scalar, or `nil` when the font has none.
    func glyph(for scalar: Unicode.Scalar) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = glyphCache[scalar.value] {
            return cached == 0 ? nil : cached
        }

        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)

        // A surrogate pair yields the glyph in the first slot and 0 in the
        // second; a genuinely missing character yields 0 outright.
        let found = Int(glyphs.first ?? 0)
        glyphCache[scalar.value] = found
        if found != 0 { reverse[found] = scalar.value }
        return found == 0 ? nil : found
    }

    /// Records glyphs as used and returns the hex string a PDF text operator
    /// wants, along with the width in 1/1000 em.
    func encode(_ text: String, size: Double) -> (hex: String, width: Double) {
        var hex = ""
        var units = 0

        for scalar in text.unicodeScalars {
            // A character with no glyph becomes .notdef rather than vanishing:
            // an empty box is a visible fault, a silently dropped letter is not.
            let found = glyph(for: scalar)
            lock.lock()
            let cid = found.map(assignCID) ?? 0
            lock.unlock()

            hex += String(format: "%04X", cid)
            units += found.map(source.advance) ?? 0
        }
        return (hex, Double(units) * size / 1000)
    }

    /// The CID for a glyph, assigning the next free one on first use.
    ///
    /// Must be called with the lock held.
    private func assignCID(_ glyph: Int) -> Int {
        if let existing = cids[glyph] { return existing }
        let assigned = order.count
        order.append(glyph)
        cids[glyph] = assigned
        return assigned
    }

    /// The width of text at a size, without marking anything used.
    public func widthOf(_ text: String, size: Double) -> Double {
        var units = 0
        for scalar in text.unicodeScalars {
            guard let glyph = glyph(for: scalar) else { continue }
            units += source.advance(glyph)
        }
        return Double(units) * size / 1000
    }

    /// Whether the text can be drawn correctly with this font.
    ///
    /// Having the glyphs is not sufficient. Arabic and Hebrew need reordering
    /// and contextual shaping, so a font that covers them still cannot be used
    /// to place them left to right — those are refused here rather than drawn
    /// into an unreadable line.
    public func covers(_ text: String) -> Bool {
        guard Script.unsupported(in: text) == nil else { return false }
        return text.unicodeScalars.allSatisfy { glyph(for: $0) != nil }
    }

    // MARK: Emitting

    /// The subset font, the glyph renumbering, and the widths to publish.
    func embeddable() -> (data: Data, mapping: [Int: Int], widths: [(cid: Int, width: Int)], toUnicode: [(cid: Int, scalar: UInt32)])? {
        lock.lock()
        let requested = order
        let scalars = reverse
        lock.unlock()

        guard requested.count > 1 else { return nil }
        guard let (data, mapping) = source.subset(ordered: requested) else { return nil }

        var widths: [(cid: Int, width: Int)] = []
        var unicode: [(cid: Int, scalar: UInt32)] = []
        for (old, new) in mapping.sorted(by: { $0.value < $1.value }) {
            widths.append((cid: new, width: source.advance(old)))
            if let scalar = scalars[old] { unicode.append((cid: new, scalar: scalar)) }
        }
        return (data, mapping, widths, unicode)
    }

    /// Whether anything has been drawn with this font.
    var isUsed: Bool {
        lock.lock(); defer { lock.unlock() }
        return order.count > 1
    }
}

// MARK: - Errors

public enum EmbeddingError: Error, LocalizedError, Equatable {

    case unreadable(String)
    case unsupportedFormat(String)
    case unsupportedScript(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Could not read \(name)."
        case .unsupportedFormat(let name):
            return "\(name) is not a TrueType font. PostScript-outline .otf and .ttc collections are not supported; use a .ttf."
        case .unsupportedScript(let script):
            return "\(script) needs bidirectional layout and contextual shaping, which this writer does not do. Text would render as disconnected letters in the wrong order."
        }
    }
}

// MARK: - Script detection

enum Script {

    /// Scripts that cannot be drawn by placing code points left to right.
    ///
    /// Refused rather than rendered: Arabic letters change form by position
    /// and both scripts run right to left, so the output would be wrong in a
    /// way a reader who does not speak the language could not detect.
    static func unsupported(in text: String) -> String? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: return "Hebrew"
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "Arabic"
            case 0x0700...0x074F: return "Syriac"
            case 0x0780...0x07BF: return "Thaana"
            default: continue
            }
        }
        return nil
    }
}
