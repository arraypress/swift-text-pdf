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
        embedded: [(name: String, font: EmbeddedFont)] = [],
        images: [(name: String, image: EmbeddedImage)] = [],
        annotations: [Int: [String]] = [:],
        language: String = ""
    ) -> Data {
        let streams = pages.isEmpty ? [""] : pages

        var objects: [Int: String] = [:]
        var binaries: [Int: Data] = [:]
        var pageRefs: [String] = []

        // 1 Catalog, 2 Pages, 3–5 base fonts, 6 Info, then five objects per
        // embedded face, one per image, then page/content pairs.
        let objectsPerFace = 5
        let firstFace = 7
        let firstImage = firstFace + (embedded.count * objectsPerFace)
        // Two slots per image: the image, and the soft mask it may need. The
        // slot is reserved whether or not the mask exists, because numbering
        // it conditionally would renumber every page after the first
        // transparent PNG.
        let firstPage = firstImage + (images.count * 2)

        // The resource names come from the caller, which assigned them as the
        // content streams were written. A face whose subset cannot be built
        // keeps its object slot — dropping it would renumber every face after
        // it, and the streams already name them.
        var fontResources = "/F1 3 0 R /F2 4 0 R /F3 5 0 R"
        for (index, face) in embedded.enumerated() {
            let first = firstFace + (index * objectsPerFace)
            guard let parts = face.font.embeddable() else { continue }
            fontResources += " /\(face.name) \(first) 0 R"
            addEmbedded(face.font, parts: parts, at: first, into: &objects, binaries: &binaries)
        }

        var imageResources = ""
        for (index, picture) in images.enumerated() {
            let object = firstImage + (index * 2)
            let maskObject = object + 1

            let mask = picture.image.maskObject()
            let (dictionary, bytes) = picture.image.xobject(mask: mask == nil ? nil : maskObject)

            imageResources += " /\(picture.name) \(object) 0 R"
            objects[object] = "\(dictionary)\nstream\n\u{0}STREAM\u{0}\nendstream"
            binaries[object] = bytes

            if let mask {
                objects[maskObject] = "\(mask.dictionary)\nstream\n\u{0}STREAM\u{0}\nendstream"
                binaries[maskObject] = mask.bytes
            }
        }

        var resources = "/Font <<\(fontResources)>>"
        if !imageResources.isEmpty { resources += " /XObject <<\(imageResources.dropFirst())>>" }

        for (index, stream) in streams.enumerated() {
            let pageObject = firstPage + (index * 2)
            let contentObject = pageObject + 1
            pageRefs.append("\(pageObject) 0 R")

            // Link areas are written straight into the array rather than as
            // objects of their own. The specification allows a direct
            // dictionary there, and numbering a dozen annotations would mean
            // renumbering every page after them.
            var annots = ""
            if let links = annotations[index], !links.isEmpty {
                annots = " /Annots [\(links.joined(separator: " "))]"
            }

            objects[pageObject] = "<</Type /Page /Parent 2 0 R "
                + "/Resources <<\(resources)>>\(annots) "
                + "/Contents \(contentObject) 0 R>>"

            // One byte per scalar, because the stream is Latin-1 by then.
            let length = stream.unicodeScalars.count
            objects[contentObject] = "<</Length \(length)>>\nstream\n\(stream)\nendstream"
        }

        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        objects[1] = "<</Type /Catalog /Pages 2 0 R"
            + (tag.isEmpty ? "" : " /Lang (\(PDFEncoding.escape(tag)))")
            + ">>"
        objects[2] = "<</Type /Pages /Kids [\(pageRefs.joined(separator: " "))] /Count \(streams.count)"
            + String(format: " /MediaBox [0 0 %.2F %.2F]>>", width, height)
        objects[3] = baseFont(.helvetica)
        objects[4] = baseFont(.helveticaBold)
        objects[5] = baseFont(.courier)
        objects[6] = info(metadata, creationDate: creationDate)

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
        // of an Identity-H subset: it has no standard character set. Bit 7
        // marks italic, which a reader uses when it has to synthesise a
        // missing face.
        let metrics = font.metrics
        let flags = 4 | (metrics.isItalic ? 64 : 0)

        // StemV has no equivalent in a TrueType file, and readers use it to
        // synthesise a substitute when the embedded font is unavailable.
        // Approximated from the weight class rather than left at a constant
        // that would describe every face as regular.
        let stemV = max(50, Int((Double(metrics.weightClass) / 65).rounded()) * 10 - 10)

        objects[descriptor] = "<</Type /FontDescriptor /FontName /\(font.name) /Flags \(flags) "
            + String(
                format: "/FontBBox [%.0F %.0F %.0F %.0F] /ItalicAngle %.1F /Ascent %.0F /Descent %.0F ",
                metrics.bbox.minX, metrics.bbox.minY, metrics.bbox.maxX, metrics.bbox.maxY,
                metrics.italicAngle, metrics.ascender, metrics.descender
            )
            + String(format: "/CapHeight %.0F ", metrics.capHeight)
            + "/StemV \(stemV) /FontFile2 \(fileObject) 0 R>>"

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
