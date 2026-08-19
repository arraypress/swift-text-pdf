//
//  ReaderTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The output, opened by somebody else's parser.
//
//  Every other test in this suite checks the bytes this writer meant to
//  produce. That catches a wrong number but not a wrong idea: a
//  cross-reference table that is internally consistent and still not what the
//  specification asks for passes all of them and opens in nothing.
//
//  PDFKit is the reader on the machine the output is most likely to be opened
//  on, and it is not this code. If it can find the pages, read the text back
//  out and name the fonts, the file is a PDF rather than merely a plausible
//  one.
//

import CoreGraphics
import PDFKit
import XCTest
@testable import TextPDF

final class ReaderTests: XCTestCase {

    private func open(_ pdf: Data, file: StaticString = #filePath, line: UInt = #line) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: pdf), "PDFKit refused the file", file: file, line: line)
    }

    // MARK: Structure

    func testAPlainDocumentOpens() throws {
        let pdf = Document()
        pdf.text("Invoice INV-2026-0042")

        let opened = try open(pdf.render())
        XCTAssertEqual(opened.pageCount, 1)
        XCTAssertEqual(opened.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Invoice INV-2026-0042")
    }

    func testEveryPageSurvives() throws {
        let pdf = Document()
        for page in 1...4 {
            pdf.text("Page \(page) body")
            if page < 4 { pdf.pageBreak() }
        }

        let opened = try open(pdf.render())
        XCTAssertEqual(opened.pageCount, 4)
        for index in 0..<4 {
            let page = try XCTUnwrap(opened.page(at: index))
            XCTAssertTrue(page.string?.contains("Page \(index + 1) body") == true)
        }
    }

    func testMetadataIsReadBack() throws {
        let pdf = Document()
        pdf.text("body")

        let opened = try open(pdf.render(metadata: ["Title": "INVOICE INV-1", "Author": "Meridian Studio Ltd"]))
        let attributes = try XCTUnwrap(opened.documentAttributes)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "INVOICE INV-1")
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Meridian Studio Ltd")
    }

    func testCurrencyAndPunctuationComeBackIntact() throws {
        // The double-encoding bug: `£` re-expanded to two bytes reads as `Â£`.
        let pdf = Document()
        pdf.text("Total due £924.48 — paid")

        let opened = try open(pdf.render())
        let read = try XCTUnwrap(opened.string)
        XCTAssertTrue(read.contains("£924.48"), "read back: \(read)")
        XCTAssertFalse(read.contains("Â"))
    }

    // MARK: Embedded families

    private func loadArial() throws -> FontFamily {
        let regular = "/System/Library/Fonts/Supplemental/Arial.ttf"
        let bold = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
        try XCTSkipUnless(
            [regular, bold].allSatisfy(FileManager.default.fileExists(atPath:)),
            "Arial is not installed in separate files"
        )
        var family = FontFamily(name: "Arial")
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: regular)), weight: .regular)
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: bold)), weight: .bold)
        return family
    }

    func testTextSetInAFamilyIsStillSelectable() throws {
        // Glyph IDs under Identity-H are meaningless without the ToUnicode
        // map. Without it the page looks right and copies as mojibake — which
        // on a CV means every keyword search misses it.
        let pdf = Document()
        pdf.family = try loadArial()
        pdf.text("Alex Morgan", font: .helveticaBold)
        pdf.text("Senior Engineer")

        let opened = try open(pdf.render())
        let read = try XCTUnwrap(opened.string)
        XCTAssertTrue(read.contains("Alex Morgan"), "read back: \(read)")
        XCTAssertTrue(read.contains("Senior Engineer"), "read back: \(read)")
    }

    func testEverySubsetIsAFontCoreGraphicsWillLoad() throws {
        // The subsetter rewrites loca, glyf, hmtx, hhea and maxp by hand. An
        // off-by-one in any of them produces a file that still opens — the
        // page is there, the text is selectable — and draws nothing where the
        // glyphs should be. Handing each program to CGFont is the check that
        // the bytes are a font rather than merely the right length.
        let pdf = Document()
        pdf.family = try loadArial()
        pdf.text("Alex Morgan", font: .helveticaBold)
        pdf.text("Senior Engineer", font: .helvetica)

        let programs = Self.fontPrograms(in: pdf.render())
        XCTAssertEqual(programs.count, 2, "expected two embedded programs")

        for (index, program) in programs.enumerated() {
            let provider = try XCTUnwrap(CGDataProvider(data: program as CFData))
            let font = try XCTUnwrap(CGFont(provider), "CGFont refused subset \(index)")
            // .notdef plus the glyphs the text actually used.
            XCTAssertGreaterThan(font.numberOfGlyphs, 1)
            XCTAssertLessThan(font.numberOfGlyphs, 30, "the whole face was embedded, not a subset")
        }
    }

    func testTheTwoWeightsPutDifferentInkOnThePage() throws {
        // Everything else here would pass if both weights resolved to the same
        // face. Rasterising is what proves the bold text is actually bold.
        func ink(_ font: Font) throws -> Int {
            let pdf = Document()
            pdf.family = try loadArial()
            pdf.move(to: 700)
            pdf.text("HHHHHHHHHH", size: 40, font: font)

            let page = try XCTUnwrap(try open(pdf.render()).page(at: 0))
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let image = page.thumbnail(of: box.size, for: .mediaBox)
            let raster = try XCTUnwrap(image.cgImage(forProposedRect: &box, context: nil, hints: nil))

            var pixels = [UInt8](repeating: 0, count: raster.width * raster.height)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: raster.width, height: raster.height,
                bitsPerComponent: 8, bytesPerRow: raster.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
            return pixels.count { $0 < 128 }
        }

        let regular = try ink(.helvetica)
        let bold = try ink(.helveticaBold)

        XCTAssertGreaterThan(regular, 0, "nothing was drawn at all")
        XCTAssertGreaterThan(bold, regular, "bold laid down no more ink than regular")
    }

    /// Every `FontFile2` stream in the file.
    ///
    /// Scanned over bytes rather than through a `String`: a CRLF pair inside a
    /// font program is a single Swift `Character`, so string offsets drift
    /// past the first binary blob and every later stream is extracted from the
    /// wrong place.
    private static func fontPrograms(in pdf: Data) -> [Data] {
        let bytes = [UInt8](pdf)

        func find(_ needle: String, from: Int) -> Int? {
            let pattern = [UInt8](needle.utf8)
            guard from >= 0, pattern.count <= bytes.count, from <= bytes.count - pattern.count else { return nil }
            return (from...(bytes.count - pattern.count)).first {
                Array(bytes[$0..<($0 + pattern.count)]) == pattern
            }
        }

        var programs: [Data] = []
        var cursor = 0

        while let marker = find("/Length1 ", from: cursor) {
            var at = marker + 9
            var digits = ""
            while at < bytes.count, (48...57).contains(bytes[at]) {
                digits.append(Character(UnicodeScalar(bytes[at])))
                at += 1
            }
            guard let length = Int(digits), let stream = find("stream\n", from: marker) else { break }

            let start = stream + 7
            guard start + length <= pdf.count else { break }
            programs.append(pdf.subdata(in: start..<(start + length)))
            cursor = start + length
        }
        return programs
    }

    func testAMixedScriptDocumentIsReadBackWhole() throws {
        let path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Arial Unicode is not installed")

        let pdf = Document()
        pdf.embeddedFont = try EmbeddedFont.load(URL(fileURLWithPath: path))
        pdf.text("Invoice INV-001")
        pdf.text("ООО «Ромашка»")

        let opened = try open(pdf.render())
        let read = try XCTUnwrap(opened.string)
        XCTAssertTrue(read.contains("Invoice INV-001"))
        XCTAssertTrue(read.contains("Ромашка"), "read back: \(read)")
    }

    func testAMultiPageTableKeepsItsRows() throws {
        let pdf = Document()
        let table = Table(headers: ["Description", "Amount"])
        table.widths([0.7, 0.3]).align([1: .right])
        for row in 1...60 {
            table.row(["Line item number \(row)", "£\(row).00"])
        }
        table.draw(pdf)

        let opened = try open(pdf.render())
        XCTAssertGreaterThan(opened.pageCount, 1, "60 rows should not fit on one page")

        let read = try XCTUnwrap(opened.string)
        XCTAssertTrue(read.contains("Line item number 1"))
        XCTAssertTrue(read.contains("Line item number 60"), "the last row was lost across the break")
    }
}
