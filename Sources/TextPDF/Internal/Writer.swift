//
//  Writer.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Turns page content streams into a PDF file.
//
//  The cross-reference table is the part that has to be exact: readers seek
//  directly to the byte offsets it records, so an off-by-one produces a file
//  that opens in one viewer and fails in another. Offsets are therefore
//  measured from the assembled output rather than calculated.
//

import Foundation

enum Writer {

    /// Encodes a built stream as single-byte text.
    ///
    /// Every string reaching here has already been through
    /// ``PDFEncoding/escape(_:)``, so each scalar is one Windows-1252 byte.
    /// Encoding as UTF-8 would re-expand `£` (U+00A3) into two bytes and the
    /// reader would show `Â£` — the double-encoding that makes a currency
    /// symbol look broken on every invoice.
    private static func bytes(_ string: String) -> Data {
        string.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(string.utf8)
    }

    /// Serialises pages into PDF bytes.
    static func write(
        pages: [String],
        width: Double,
        height: Double,
        metadata: [String: String],
        creationDate: Date,
        embedded: EmbeddedFont? = nil
    ) -> Data {
        let streams = pages.isEmpty ? [""] : pages

        var objects: [Int: String] = [:]
        var pageRefs: [String] = []

        // 1 Catalog, 2 Pages, 3–5 base fonts, 6 Info, 7–11 the embedded font
        // when there is one, then page/content pairs.
        let embeddedObjects = 5
        let embeddedFirst = 7
        let usesEmbedded = embedded?.isUsed == true
        let firstPage = usesEmbedded ? embeddedFirst + embeddedObjects : embeddedFirst

        var fontResources = "/F1 3 0 R /F2 4 0 R /F3 5 0 R"
        if usesEmbedded { fontResources += " /F4 \(embeddedFirst) 0 R" }

        for (index, stream) in streams.enumerated() {
            let pageObject = firstPage + (index * 2)
            let contentObject = pageObject + 1
            pageRefs.append("\(pageObject) 0 R")

            objects[pageObject] = "<</Type /Page /Parent 2 0 R "
                + "/Resources <</Font <<\(fontResources)>>>> "
                + "/Contents \(contentObject) 0 R>>"

            // One byte per scalar, because the stream is Latin-1 by then.
            let length = stream.unicodeScalars.count
            objects[contentObject] = "<</Length \(length)>>\nstream\n\(stream)\nendstream"
        }

        objects[1] = "<</Type /Catalog /Pages 2 0 R>>"
        objects[2] = "<</Type /Pages /Kids [\(pageRefs.joined(separator: " "))] /Count \(streams.count)"
            + String(format: " /MediaBox [0 0 %.2F %.2F]>>", width, height)
        objects[3] = baseFont(.helvetica)
        objects[4] = baseFont(.helveticaBold)
        objects[5] = baseFont(.courier)
        objects[6] = info(metadata, creationDate: creationDate)

        var binaries: [Int: Data] = [:]
        if usesEmbedded, let embedded, let parts = embedded.embeddable() {
            addEmbedded(embedded, parts: parts, at: embeddedFirst, into: &objects, binaries: &binaries)
        }

        return serialise(objects, upTo: firstPage + (streams.count * 2) - 1, binaries: binaries)
    }

    /// Writes the five objects a CID font needs.
    ///
    /// A Type0 wrapper points at a CIDFontType2 descendant, which points at a
    /// descriptor, which points at the subset bytes. The ToUnicode map is what
    /// makes the text selectable and searchable afterwards — without it a
    /// reader shows glyph indices when you copy from the page.
    private static func addEmbedded(
        _ font: EmbeddedFont,
        parts: (data: Data, mapping: [Int: Int], widths: [(cid: Int, width: Int)], toUnicode: [(cid: Int, scalar: UInt32)]),
        at first: Int,
        into objects: inout [Int: String],
        binaries: inout [Int: Data]
    ) {
        let type0 = first, descendant = first + 1, descriptor = first + 2
        let fileObject = first + 3, toUnicodeObject = first + 4

        objects[type0] = "<</Type /Font /Subtype /Type0 /BaseFont /\(font.name) "
            + "/Encoding /Identity-H /DescendantFonts [\(descendant) 0 R] /ToUnicode \(toUnicodeObject) 0 R>>"

        let widths = parts.widths
            .filter { $0.width > 0 }
            .map { "\($0.cid) [\($0.width)]" }
            .joined(separator: " ")

        objects[descendant] = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /\(font.name) "
            + "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> "
            + "/FontDescriptor \(descriptor) 0 R /DW 1000 /W [\(widths)] /CIDToGIDMap /Identity>>"

        // Flags bit 3 marks a symbolic font, which is the honest description
        // of an Identity-H subset: it has no standard character set.
        objects[descriptor] = "<</Type /FontDescriptor /FontName /\(font.name) /Flags 4 "
            + "/FontBBox [-1000 -400 2000 1200] /ItalicAngle 0 /Ascent 900 /Descent -200 "
            + "/CapHeight 700 /StemV 80 /FontFile2 \(fileObject) 0 R>>"

        objects[fileObject] = "<</Length \(parts.data.count) /Length1 \(parts.data.count)>>\nstream\n\u{0}STREAM\u{0}\nendstream"
        binaries[fileObject] = parts.data

        objects[toUnicodeObject] = toUnicodeMap(parts.toUnicode)
    }

    /// A CMap mapping each CID back to the character it came from.
    private static func toUnicodeMap(_ pairs: [(cid: Int, scalar: UInt32)]) -> String {
        var body = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange

            """

        // A CMap allows at most 100 entries per block.
        for chunk in stride(from: 0, to: pairs.count, by: 100) {
            let slice = Array(pairs[chunk..<min(chunk + 100, pairs.count)])
            body += "\(slice.count) beginbfchar\n"
            for pair in slice {
                let scalar = Unicode.Scalar(pair.scalar).map { String(String.UnicodeScalarView([$0])) } ?? ""
                let utf16 = Array(scalar.utf16).map { String(format: "%04X", $0) }.joined()
                body += "<\(String(format: "%04X", pair.cid))> <\(utf16)>\n"
            }
            body += "endbfchar\n"
        }
        body += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"

        return "<</Length \(body.unicodeScalars.count)>>\nstream\n\(body)\nendstream"
    }

    /// One of the base-14 fonts, with its metrics published.
    ///
    /// The widths are optional for these fonts — a reader is required to know
    /// Helvetica already — but leaving them out means trusting its built-in
    /// table, and those tables predate the euro. Without this the euro is
    /// advanced by nothing and the next digit is drawn on top of it.
    private static func baseFont(_ font: Font) -> String {
        let table = font.widths
        let widths = (32...255).map { String(table[$0] ?? 0) }.joined(separator: " ")
        return "<</Type /Font /Subtype /Type1 /BaseFont /\(font.rawValue)"
            + " /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255"
            + " /Widths [\(widths)]>>"
    }

    private static func info(_ metadata: [String: String], creationDate: Date) -> String {
        var parts: [String] = []

        for field in ["Title", "Author", "Subject", "Keywords", "Creator"] {
            let value = (metadata[field] ?? metadata[field.lowercased()] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                parts.append("/\(field) (\(PDFEncoding.escape(value)))")
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        parts.append("/Producer (arraypress/swift-text-pdf)")
        parts.append("/CreationDate (D:\(formatter.string(from: creationDate))Z)")

        return "<<" + parts.joined(separator: " ") + ">>"
    }

    /// Serialises objects with a correct cross-reference table.
    private static func serialise(_ objects: [Int: String], upTo max: Int, binaries: [Int: Data] = [:]) -> Data {
        var pdf = bytes("%PDF-1.4\n")
        var offsets: [Int: Int] = [:]

        for number in 1...max {
            offsets[number] = pdf.count
            let body = objects[number] ?? "<<>>"

            // A font file is binary and cannot survive Latin-1 round-tripping,
            // so it is spliced in as raw bytes around its dictionary.
            if let binary = binaries[number], let marker = body.range(of: "\u{0}STREAM\u{0}") {
                pdf.append(bytes("\(number) 0 obj\n" + String(body[body.startIndex..<marker.lowerBound])))
                pdf.append(binary)
                pdf.append(bytes(String(body[marker.upperBound...]) + "\nendobj\n"))
            } else {
                pdf.append(bytes("\(number) 0 obj\n\(body)\nendobj\n"))
            }
        }

        let xref = pdf.count
        pdf.append(bytes("xref\n0 \(max + 1)\n0000000000 65535 f \n"))

        for number in 1...max {
            pdf.append(bytes(String(format: "%010d 00000 n \n", offsets[number] ?? 0)))
        }

        pdf.append(bytes("trailer\n<</Size \(max + 1) /Root 1 0 R /Info 6 0 R>>\nstartxref\n\(xref)\n%%EOF"))
        return pdf
    }
}
