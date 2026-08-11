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
        creationDate: Date
    ) -> Data {
        let streams = pages.isEmpty ? [""] : pages

        var objects: [Int: String] = [:]
        var pageRefs: [String] = []

        // 1 Catalog, 2 Pages, 3–5 fonts, 6 Info, then page/content pairs.
        let firstPage = 7

        for (index, stream) in streams.enumerated() {
            let pageObject = firstPage + (index * 2)
            let contentObject = pageObject + 1
            pageRefs.append("\(pageObject) 0 R")

            objects[pageObject] = "<</Type /Page /Parent 2 0 R "
                + "/Resources <</Font <</F1 3 0 R /F2 4 0 R /F3 5 0 R>>>> "
                + "/Contents \(contentObject) 0 R>>"

            // One byte per scalar, because the stream is Latin-1 by then.
            let length = stream.unicodeScalars.count
            objects[contentObject] = "<</Length \(length)>>\nstream\n\(stream)\nendstream"
        }

        objects[1] = "<</Type /Catalog /Pages 2 0 R>>"
        objects[2] = "<</Type /Pages /Kids [\(pageRefs.joined(separator: " "))] /Count \(streams.count)"
            + String(format: " /MediaBox [0 0 %.2F %.2F]>>", width, height)
        objects[3] = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
        objects[4] = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>"
        objects[5] = "<</Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding>>"
        objects[6] = info(metadata, creationDate: creationDate)

        return serialise(objects, upTo: firstPage + (streams.count * 2) - 1)
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
    private static func serialise(_ objects: [Int: String], upTo max: Int) -> Data {
        var pdf = bytes("%PDF-1.4\n")
        var offsets: [Int: Int] = [:]

        for number in 1...max {
            offsets[number] = pdf.count
            let body = objects[number] ?? "<<>>"
            pdf.append(bytes("\(number) 0 obj\n\(body)\nendobj\n"))
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
