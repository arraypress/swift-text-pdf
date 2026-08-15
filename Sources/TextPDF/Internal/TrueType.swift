//
//  TrueType.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A minimal TrueType reader and subsetter.
//
//  Embedding a whole font is not an option: Arial is 480 KB and Arial Unicode
//  is 23 MB, against an invoice that is otherwise 6 KB. So the glyphs actually
//  used are extracted into a new font.
//
//  Glyph IDs are renumbered into a compact range as they are first used, which
//  keeps `loca` proportional to the subset rather than to the original's fifty
//  thousand glyphs. Because the new IDs are dense from zero, the PDF's
//  CIDToGIDMap stays Identity and the text operator can write the new IDs
//  directly.
//
//  Only the tables a CID font needs are emitted — head, hhea, maxp, hmtx,
//  loca, glyf. `cmap` is deliberately absent: with Identity-H the PDF maps
//  character codes to glyphs itself, so a cmap in the embedded file would be
//  weight nobody reads.
//

import Foundation

/// A face's vertical metrics, in 1/1000 em.
///
/// Read from the font rather than assumed. A fixed ascender ratio is a
/// tolerable approximation for a fallback face drawing the odd Cyrillic name,
/// but a document *set* in a face positions every baseline from it — and the
/// ratio varies enough between families to be visible. Inter's cap height is
/// 727 units where EB Garamond's is 662; centring both on 717 leaves one
/// riding high and the other sitting low in the same band.
struct FontMetrics: Sendable, Equatable {

    let ascender: Double
    /// Negative, as the font declares it.
    let descender: Double
    let capHeight: Double
    let xHeight: Double
    let italicAngle: Double
    let bbox: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    let isItalic: Bool
    let isBold: Bool

    /// OS/2 usWeightClass — 400 regular, 600 semibold, 700 bold.
    let weightClass: Int

    static func == (lhs: FontMetrics, rhs: FontMetrics) -> Bool {
        lhs.ascender == rhs.ascender && lhs.descender == rhs.descender
            && lhs.capHeight == rhs.capHeight && lhs.xHeight == rhs.xHeight
            && lhs.italicAngle == rhs.italicAngle && lhs.bbox == rhs.bbox
            && lhs.isItalic == rhs.isItalic && lhs.isBold == rhs.isBold
            && lhs.weightClass == rhs.weightClass
    }

    /// What the base-14 ratios assume, for a font that declares nothing useful.
    static let fallback = FontMetrics(
        ascender: 780, descender: -220, capHeight: 717, xHeight: 523,
        italicAngle: 0, bbox: (-200, -400, 1000, 1000),
        isItalic: false, isBold: false, weightClass: 400
    )
}

/// A parsed TrueType font, enough of one to subset it.
struct TrueTypeFont {

    let data: Data
    let unitsPerEm: Int
    let glyphCount: Int

    /// Vertical metrics, scaled to 1/1000 em.
    let metrics: FontMetrics

    /// Whether the file is a variable font, which this cannot subset honestly.
    let isVariable: Bool

    /// Offsets into `glyf` for every glyph, `glyphCount + 1` entries.
    private let loca: [Int]
    private let glyfRange: Range<Int>
    private let tables: [String: Range<Int>]

    /// Advance widths, in font units.
    private let advances: [Int]

    // MARK: Parsing

    init?(data: Data) {
        guard data.count > 12 else { return nil }
        self.data = data

        let tag = data.u32(0)
        // 0x00010000 is TrueType outlines; 'true' is the older Apple spelling.
        // 'OTTO' means CFF outlines, which need a different PDF font type
        // entirely, and 'ttcf' is a collection rather than a single font.
        guard tag == 0x0001_0000 || tag == 0x74727565 else { return nil }

        let numTables = Int(data.u16(4))
        var found: [String: Range<Int>] = [:]

        for index in 0..<numTables {
            let record = 12 + index * 16
            guard record + 16 <= data.count else { return nil }
            let name = String(decoding: data[data.startIndex + record ..< data.startIndex + record + 4], as: UTF8.self)
            let offset = Int(data.u32(record + 8))
            let length = Int(data.u32(record + 12))
            guard offset + length <= data.count else { continue }
            found[name] = offset..<(offset + length)
        }
        tables = found

        guard let head = found["head"], let maxp = found["maxp"],
              let hhea = found["hhea"], let hmtx = found["hmtx"],
              let locaRange = found["loca"], let glyf = found["glyf"]
        else { return nil }

        // A variable font carries one set of outlines plus the deltas that
        // move them between weights. Subsetting keeps the outlines and drops
        // the deltas, so the file would embed correctly and render every
        // weight as the default instance — a document asking for bold and
        // getting regular, with nothing to indicate it. Refused instead.
        isVariable = found["fvar"] != nil

        unitsPerEm = Int(data.u16(head.lowerBound + 18))
        let longLoca = data.u16(head.lowerBound + 50) == 1
        glyphCount = Int(data.u16(maxp.lowerBound + 4))
        glyfRange = glyf

        // loca is either 16-bit halved offsets or 32-bit, per head.
        var offsets: [Int] = []
        offsets.reserveCapacity(glyphCount + 1)
        for index in 0...glyphCount {
            if longLoca {
                let at = locaRange.lowerBound + index * 4
                guard at + 4 <= data.count else { return nil }
                offsets.append(Int(data.u32(at)))
            } else {
                let at = locaRange.lowerBound + index * 2
                guard at + 2 <= data.count else { return nil }
                offsets.append(Int(data.u16(at)) * 2)
            }
        }
        loca = offsets

        // hmtx holds numberOfHMetrics full entries, then the remaining glyphs
        // share the last advance.
        let metricCount = max(1, Int(data.u16(hhea.lowerBound + 34)))
        var widths: [Int] = []
        widths.reserveCapacity(glyphCount)
        var last = 0
        for glyph in 0..<glyphCount {
            if glyph < metricCount {
                let at = hmtx.lowerBound + glyph * 4
                guard at + 2 <= data.count else { break }
                last = Int(data.u16(at))
            }
            widths.append(last)
        }
        advances = widths

        metrics = Self.readMetrics(
            data: data, tables: found, head: head, hhea: hhea, unitsPerEm: unitsPerEm
        )
    }

    /// Vertical metrics, preferring OS/2's typographic values.
    ///
    /// Three tables disagree about a font's ascender and each is right about
    /// something different: `hhea` carries the values the original designer set
    /// for line spacing, OS/2's `sTypo*` are the ones a modern layout engine is
    /// told to use, and `usWin*` are clipping bounds Windows enforces. OS/2 is
    /// preferred where it is present and non-zero, falling back to `hhea` —
    /// which every valid TrueType font has.
    ///
    /// Cap height and x-height only exist from OS/2 version 2. Below that they
    /// are derived from the em, because the alternative is measuring the `H`
    /// and `x` outlines and no layout decision here justifies that.
    private static func readMetrics(
        data: Data, tables: [String: Range<Int>],
        head: Range<Int>, hhea: Range<Int>, unitsPerEm: Int
    ) -> FontMetrics {
        guard unitsPerEm > 0 else { return .fallback }
        let perMille = 1000.0 / Double(unitsPerEm)

        var ascender = Double(data.i16(hhea.lowerBound + 4)) * perMille
        var descender = Double(data.i16(hhea.lowerBound + 6)) * perMille
        var capHeight = 0.0
        var xHeight = 0.0
        var weightClass = 400
        var italicFromOS2 = false

        if let os2 = tables["OS/2"], os2.count >= 78 {
            let version = data.u16(os2.lowerBound)
            weightClass = Int(data.u16(os2.lowerBound + 4))

            // fsSelection bit 0 is italic, bit 5 bold.
            let selection = data.u16(os2.lowerBound + 62)
            italicFromOS2 = (selection & 0x0001) != 0

            let typoAscender = Double(data.i16(os2.lowerBound + 68)) * perMille
            let typoDescender = Double(data.i16(os2.lowerBound + 70)) * perMille
            if typoAscender != 0 { ascender = typoAscender }
            if typoDescender != 0 { descender = typoDescender }

            if version >= 2, os2.count >= 90 {
                capHeight = Double(data.i16(os2.lowerBound + 88)) * perMille
                xHeight = Double(data.i16(os2.lowerBound + 86)) * perMille
            }
        }

        // macStyle, for fonts whose OS/2 table is absent or lying.
        let macStyle = data.u16(head.lowerBound + 44)
        let isBold = (macStyle & 0x0001) != 0 || weightClass >= 600
        let isItalic = (macStyle & 0x0002) != 0 || italicFromOS2

        var italicAngle = 0.0
        if let post = tables["post"], post.count >= 8 {
            // Fixed 16.16, signed.
            italicAngle = Double(Int32(bitPattern: data.u32(post.lowerBound + 4))) / 65536
        }

        if capHeight <= 0 { capHeight = ascender * 0.92 }
        if xHeight <= 0 { xHeight = capHeight * 0.73 }

        return FontMetrics(
            ascender: ascender,
            descender: descender,
            capHeight: capHeight,
            xHeight: xHeight,
            italicAngle: italicAngle,
            bbox: (
                minX: Double(data.i16(head.lowerBound + 36)) * perMille,
                minY: Double(data.i16(head.lowerBound + 38)) * perMille,
                maxX: Double(data.i16(head.lowerBound + 40)) * perMille,
                maxY: Double(data.i16(head.lowerBound + 42)) * perMille
            ),
            isItalic: isItalic,
            isBold: isBold,
            weightClass: weightClass
        )
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    // MARK: Glyphs

    /// The advance width of a glyph, in 1/1000 em.
    func advance(_ glyph: Int) -> Int {
        guard glyph >= 0, glyph < advances.count, unitsPerEm > 0 else { return 0 }
        return Int((Double(advances[glyph]) * 1000 / Double(unitsPerEm)).rounded())
    }

    private func glyphData(_ glyph: Int) -> Data {
        guard glyph >= 0, glyph + 1 < loca.count else { return Data() }
        let start = glyfRange.lowerBound + loca[glyph]
        let end = glyfRange.lowerBound + loca[glyph + 1]
        guard end > start, end <= data.count else { return Data() }
        return data[data.startIndex + start ..< data.startIndex + end]
    }

    /// Glyphs referenced by a composite glyph, e.g. the `e` and the acute in `é`.
    ///
    /// Missing these leaves accented characters as bare marks, which is the
    /// kind of fault that only shows up on somebody's name.
    private func components(of glyph: Int) -> [Int] {
        let bytes = glyphData(glyph)
        guard bytes.count >= 10, Int16(bitPattern: bytes.u16(0)) < 0 else { return [] }

        var found: [Int] = []
        var cursor = 10
        while cursor + 4 <= bytes.count {
            let flags = bytes.u16(cursor)
            let index = Int(bytes.u16(cursor + 2))
            found.append(index)
            cursor += 4

            cursor += (flags & 0x0001) != 0 ? 4 : 2       // ARG_1_AND_2_ARE_WORDS
            if (flags & 0x0008) != 0 { cursor += 2 }       // WE_HAVE_A_SCALE
            else if (flags & 0x0040) != 0 { cursor += 4 }  // X_AND_Y_SCALE
            else if (flags & 0x0080) != 0 { cursor += 8 }  // TWO_BY_TWO
            if (flags & 0x0020) == 0 { break }             // MORE_COMPONENTS
        }
        return found
    }

    // MARK: Subsetting

    /// A font containing only `requested`, renumbered to that exact order.
    ///
    /// The order is the caller's, not ours: text is written before the subset
    /// exists, so the IDs in the content stream are already fixed and the font
    /// must be built to match them. Composite components are appended after the
    /// requested glyphs, where they cannot disturb those positions.
    func subset(ordered requested: [Int]) -> (data: Data, mapping: [Int: Int])? {
        var ordered: [Int] = []
        var seen: Set<Int> = []

        func include(_ glyph: Int) {
            guard glyph >= 0, glyph < glyphCount, !seen.contains(glyph) else { return }
            seen.insert(glyph)
            ordered.append(glyph)
        }
        include(0)                                  // .notdef must stay at index 0
        for glyph in requested { include(glyph) }

        // Breadth-first, so a component's own components are picked up too.
        var index = 0
        while index < ordered.count {
            for component in components(of: ordered[index]) { include(component) }
            index += 1
        }

        var mapping: [Int: Int] = [:]
        for (new, old) in ordered.enumerated() { mapping[old] = new }

        // Rebuild glyf, rewriting composite references to the new IDs.
        var glyf = Data()
        var newLoca: [Int] = [0]
        for old in ordered {
            var bytes = glyphData(old)
            if bytes.count >= 10, Int16(bitPattern: bytes.u16(0)) < 0 {
                bytes = rewriteComposite(bytes, mapping: mapping)
            }
            glyf.append(bytes)
            // Glyph data must stay 4-byte aligned or offsets drift.
            while glyf.count % 4 != 0 { glyf.append(0) }
            newLoca.append(glyf.count)
        }

        guard let head = tables["head"], let hhea = tables["hhea"], let maxp = tables["maxp"] else { return nil }

        var headData = Data(data[data.startIndex + head.lowerBound ..< data.startIndex + head.upperBound])
        guard headData.count >= 52 else { return nil }
        headData.replaceSubrange(50..<52, with: [0x00, 0x01])       // long loca
        headData.replaceSubrange(8..<12, with: [0, 0, 0, 0])        // checksumAdjustment

        var locaData = Data()
        for offset in newLoca { locaData.append(contentsOf: UInt32(offset).bigEndianBytes) }

        var hmtxData = Data()
        for old in ordered {
            let raw = old < advances.count ? advances[old] : 0
            hmtxData.append(contentsOf: UInt16(clamping: raw).bigEndianBytes)
            hmtxData.append(contentsOf: [0, 0])                     // left side bearing
        }

        var hheaData = Data(data[data.startIndex + hhea.lowerBound ..< data.startIndex + hhea.upperBound])
        guard hheaData.count >= 36 else { return nil }
        hheaData.replaceSubrange(34..<36, with: UInt16(ordered.count).bigEndianBytes)

        var maxpData = Data(data[data.startIndex + maxp.lowerBound ..< data.startIndex + maxp.upperBound])
        guard maxpData.count >= 6 else { return nil }
        maxpData.replaceSubrange(4..<6, with: UInt16(ordered.count).bigEndianBytes)

        return (assemble([
            ("head", headData), ("hhea", hheaData), ("maxp", maxpData),
            ("hmtx", hmtxData), ("loca", locaData), ("glyf", glyf),
        ]), mapping)
    }

    private func rewriteComposite(_ bytes: Data, mapping: [Int: Int]) -> Data {
        // Copied rather than aliased: glyph data arrives as a slice of the whole
        // font, so its indices start deep inside the file, and writing to
        // `cursor` positions would land in another glyph — or past the end.
        var out = Data(bytes)
        var cursor = 10
        while cursor + 4 <= out.count {
            let flags = out.u16(cursor)
            let old = Int(out.u16(cursor + 2))
            let new = mapping[old] ?? 0
            out.replaceSubrange((cursor + 2)..<(cursor + 4), with: UInt16(new).bigEndianBytes)
            cursor += 4
            cursor += (flags & 0x0001) != 0 ? 4 : 2
            if (flags & 0x0008) != 0 { cursor += 2 }
            else if (flags & 0x0040) != 0 { cursor += 4 }
            else if (flags & 0x0080) != 0 { cursor += 8 }
            if (flags & 0x0020) == 0 { break }
        }
        return out
    }

    /// Writes an sfnt with the given tables, in the order readers expect.
    private func assemble(_ parts: [(String, Data)]) -> Data {
        let sorted = parts.sorted { $0.0 < $1.0 }
        let count = sorted.count

        // searchRange and friends are derived from the table count.
        var power = 1
        while power * 2 <= count { power *= 2 }
        let searchRange = power * 16
        let entrySelector = Int(log2(Double(power)))

        var out = Data()
        out.append(contentsOf: UInt32(0x0001_0000).bigEndianBytes)
        out.append(contentsOf: UInt16(count).bigEndianBytes)
        out.append(contentsOf: UInt16(searchRange).bigEndianBytes)
        out.append(contentsOf: UInt16(entrySelector).bigEndianBytes)
        out.append(contentsOf: UInt16(count * 16 - searchRange).bigEndianBytes)

        var offset = 12 + count * 16
        var directory = Data()
        var body = Data()

        for (name, table) in sorted {
            directory.append(contentsOf: Array(name.utf8))
            directory.append(contentsOf: UInt32(checksum(table)).bigEndianBytes)
            directory.append(contentsOf: UInt32(offset).bigEndianBytes)
            directory.append(contentsOf: UInt32(table.count).bigEndianBytes)

            body.append(table)
            var padded = table.count
            while padded % 4 != 0 { body.append(0); padded += 1 }
            offset += padded
        }
        out.append(directory)
        out.append(body)
        return out
    }

    private func checksum(_ table: Data) -> UInt32 {
        var sum: UInt32 = 0
        var index = table.startIndex
        while index < table.endIndex {
            var word: UInt32 = 0
            for byte in 0..<4 {
                let at = table.index(index, offsetBy: byte, limitedBy: table.endIndex) ?? table.endIndex
                word = (word << 8) | UInt32(at < table.endIndex ? table[at] : 0)
            }
            sum = sum &+ word
            index = table.index(index, offsetBy: 4, limitedBy: table.endIndex) ?? table.endIndex
        }
        return sum
    }
}

// MARK: - Byte helpers

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        guard base + 1 < endIndex else { return 0 }
        return UInt16(self[base]) << 8 | UInt16(self[base + 1])
    }

    /// A signed 16-bit big-endian value — an FWord.
    ///
    /// Descenders are negative, so reading them unsigned turns -220 into
    /// 65316 and every line in the document acquires a 65-em gap.
    func i16(_ offset: Int) -> Int16 { Int16(bitPattern: u16(offset)) }

    func u32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        guard base + 3 < endIndex else { return 0 }
        return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16
            | UInt32(self[base + 2]) << 8 | UInt32(self[base + 3])
    }
}

extension UInt16 { var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] } }
extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
