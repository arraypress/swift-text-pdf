//
//  RegressionTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Fixes proven by a reader, so they cannot quietly come back.
//
//  Each of these began as a file that looked right in the bytes and read
//  wrongly in PDFKit — which is the reader the output meets first on every
//  Mac. The test is therefore written against PDFKit where one can be.
//

import PDFKit
import XCTest
@testable import TextPDF

final class RegressionTests: XCTestCase {

    private func open(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: data), "PDFKit refused the file", file: file, line: line)
    }

    // MARK: - Text strings outside the content stream

    // Info entries and outline titles are read as PDFDocEncoding or UTF-16,
    // never CP1252. Written as CP1252 they opened with the euro, the dashes
    // and the curly quotes swapped for the 0x80–0x9F window's other glyphs:
    // "Invoice — €500" came back "Invoice Š •500".

    func testNonASCIIMetadataRoundTripsThroughPDFKit() throws {
        let pdf = Document()
        pdf.text("body")

        let title = "Invoice — €500 “Final”"
        let author = "Åse Ünçel"
        let opened = try open(pdf.render(metadata: ["Title": title, "Author": author]))

        XCTAssertEqual(opened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)
        XCTAssertEqual(opened.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, author)
    }

    func testNonASCIIBookmarkTitleRoundTripsThroughPDFKit() throws {
        let pdf = Document()
        pdf.bookmark("Payslip — A Moreau")
        pdf.text("body")

        let opened = try open(pdf.render())
        XCTAssertEqual(opened.outlineRoot?.child(at: 0)?.label, "Payslip — A Moreau")
    }

    func testEncryptedNonASCIIStringsSurviveTheLock() throws {
        // The encrypted path used to seal UTF-8 bytes, which a reader then
        // took as PDFDocEncoding — so even "ä" broke the moment a password
        // was set, not only the CP1252 window.
        let pdf = Document()
        pdf.bookmark("Payslip — B Müller")
        pdf.text("body")

        let data = pdf.render(metadata: ["Title": "Payslip — März €"], password: "secret123")
        let opened = try open(data)
        XCTAssertTrue(opened.unlock(withPassword: "secret123"))
        XCTAssertEqual(opened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       "Payslip — März €")
        XCTAssertEqual(opened.outlineRoot?.child(at: 0)?.label, "Payslip — B Müller")
    }

    func testASCIIStringsStayPlainLiterals() throws {
        // The escape hatch is only for text ASCII cannot carry; an ordinary
        // title should stay readable in the raw bytes.
        let pdf = Document()
        pdf.text("body")
        let rendered = String(decoding: pdf.render(metadata: ["Title": "Invoice 42"]), as: UTF8.self)
        XCTAssertTrue(rendered.contains("/Title (Invoice 42)"))
    }

    // MARK: - The header an encrypted file claims

    func testAnEncryptedFileClaimsPDF17() throws {
        let pdf = Document()
        pdf.text("body")
        let data = pdf.render(password: "secret123")
        XCTAssertTrue(String(decoding: data.prefix(8), as: UTF8.self).hasPrefix("%PDF-1.7"))
    }

    func testAPlainFileStillClaimsPDF14() throws {
        let pdf = Document()
        pdf.text("body")
        XCTAssertTrue(String(decoding: pdf.render().prefix(8), as: UTF8.self).hasPrefix("%PDF-1.4"))
    }

    // MARK: - Zero-width glyphs in /W

    private let unicodeFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")

    func testEveryDrawnCIDHasAPublishedWidth() throws {
        // Zero-width entries were filtered out of /W to save bytes, which
        // handed those glyphs /DW instead — 1000 units of nothing after every
        // combining mark, so a decomposed "Zoë" rendered with a hole in it.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: unicodeFont.path),
                          "Arial Unicode is not installed")
        let face = try EmbeddedFont.load(unicodeFont)

        let pdf = Document()
        pdf.embeddedFont = face
        pdf.text("Zoe\u{0308} and Дмитрий", size: 12)

        let rendered = String(decoding: pdf.render(), as: UTF8.self)
        // The array nests brackets — "0 [656] 1 [753] …" — so it runs to the
        // key that follows it rather than to the first "]".
        let start = try XCTUnwrap(rendered.range(of: "/W ["), "no /W array in the descendant font")
        let end = try XCTUnwrap(rendered.range(of: "/CIDToGIDMap", range: start.upperBound..<rendered.endIndex))
        let wArray = String(rendered[start.upperBound..<end.lowerBound])

        // Every CID the content stream draws must be priced, zero or not.
        let drawn = rendered.matches(of: /<([0-9A-F]{4,})> Tj/).flatMap { match in
            stride(from: 0, to: match.1.count, by: 4).map { offset -> Int in
                let start = match.1.index(match.1.startIndex, offsetBy: offset)
                let end = match.1.index(start, offsetBy: 4)
                return Int(match.1[start..<end], radix: 16) ?? 0
            }
        }
        XCTAssertFalse(drawn.isEmpty, "nothing drawn under Identity-H")
        for cid in Set(drawn) {
            XCTAssertTrue(wArray.contains("\(cid) ["), "CID \(cid) has no /W entry")
        }
    }

    func testADecomposedNameMeasuresLikeItsPrecomposedTwin() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: unicodeFont.path),
                          "Arial Unicode is not installed")
        let face = try EmbeddedFont.load(unicodeFont)

        // Only meaningful when the mark really is zero-width in this face.
        let mark = face.widthOf("\u{0308}", size: 12)
        try XCTSkipUnless(mark == 0, "combining diaeresis has an advance in this font")

        let pdf = Document()
        pdf.embeddedFont = face
        pdf.text("Zoë", size: 12)
        pdf.text("Zoe\u{0308}", size: 12)

        let opened = try open(pdf.render())
        let matches = opened.findString("Zoë", withOptions: [])
        XCTAssertEqual(matches.count, 2, "both spellings should extract as the same name")

        let page = try XCTUnwrap(opened.page(at: 0))
        let widths = matches.map { $0.bounds(for: page).width }
        // Before the fix the decomposed line was exactly one /DW — 12pt —
        // wider than its twin.
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5)
    }

    // MARK: - Per-page callbacks accumulate

    func testASecondFooterDoesNotDeleteTheFirst() throws {
        let pdf = Document()
        pdf.text("body")
        pdf.onEachPage { document, page, total in
            document.textAt("Page \(page) of \(total)", x: document.left(), y: 30, size: 8)
        }
        pdf.onEachPage { document, _, _ in
            document.textAt("CONFIDENTIAL", x: document.right() - 80, y: 30, size: 8)
        }

        let text = try XCTUnwrap(try open(pdf.render()).string)
        XCTAssertTrue(text.contains("Page 1 of 1"))
        XCTAssertTrue(text.contains("CONFIDENTIAL"))
    }

    func testAWatermarkOverTheContentCoexistsWithAFooter() throws {
        // watermark(over: true) registers through onEachPage; it used to
        // replace the template's page numbers rather than join them.
        let pdf = Document()
        pdf.text("body")
        pdf.onEachPage { document, page, total in
            document.textAt("Page \(page) of \(total)", x: document.left(), y: 30, size: 8)
        }
        pdf.watermark("DRAFT", over: true)

        let text = try XCTUnwrap(try open(pdf.render()).string)
        XCTAssertTrue(text.contains("Page 1 of 1"), "the footer must survive the watermark")
        XCTAssertTrue(text.contains("DRAFT"), "the watermark must survive the footer")
    }

    func testBackgroundsAccumulateToo() throws {
        let pdf = Document()
        pdf.text("body")
        pdf.behindEachPage { document, _, _ in
            document.rect(x: 0, y: 0, width: 40, height: document.height(), color: .grey(240))
        }
        pdf.watermark("COPY")   // behind by default

        let text = try XCTUnwrap(try open(pdf.render()).string)
        XCTAssertTrue(text.contains("COPY"), "the watermark must draw despite the earlier panel")
    }

    // MARK: - Extra XMP

    func testMetadataExtrasReachThePacket() throws {
        let pdf = Document()
        pdf.text("body")
        pdf.metadataExtras = ["""
            <rdf:Description rdf:about="" xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">
              <fx:ConformanceLevel>MINIMUM</fx:ConformanceLevel>
            </rdf:Description>
        """]

        let rendered = String(decoding: pdf.render(standard: .pdfA3b), as: UTF8.self)
        XCTAssertTrue(rendered.contains("fx:ConformanceLevel"), "the fragment should sit in the packet")
        XCTAssertTrue(rendered.contains("pdfaid:part"), "the standard's own packet must remain")
    }

    // MARK: - Tables short a width

    func testAWidthsListShorterThanTheRowStillDrawsEveryColumn() throws {
        // Three widths for four columns used to leave the fourth at zero,
        // and a zero-width cell is simply not drawn — the Total column
        // vanished because the widths list was one short.
        let pdf = Document()
        let table = Table(headers: ["Item", "Qty", "Rate", "Total"])
        table.widths([2, 1, 1])
        table.row(["Mixing", "2", "£300.00", "£600.00"])
        table.draw(pdf)

        let text = try XCTUnwrap(try open(pdf.render()).string)
        XCTAssertTrue(text.contains("Total"), "the header short a width must still appear")
        XCTAssertTrue(text.contains("£600.00"), "the cell short a width must still appear")
    }

    // MARK: - Malformed SVG commands

    func testABareDrawingCommandDrawsNothing() {
        // "M 10 10 L" — a lineto with no numbers used to read zeroes and
        // draw a stray line toward the origin.
        let operators = SVGPath.toPDF("M 10 10 L", svgHeight: 24)
        XCTAssertFalse(operators.contains(" l\n"), "a bare L must not invent a line")
        XCTAssertTrue(operators.contains(" m\n"), "the valid moveto before it survives")
    }

    func testMetadataExtrasAreIgnoredWithoutAStandard() throws {
        // No packet is written for an ordinary PDF, so the fragment has
        // nowhere to go — and must not invent one.
        let pdf = Document()
        pdf.text("body")
        pdf.metadataExtras = ["<rdf:Description rdf:about=\"\"/>"]

        let rendered = String(decoding: pdf.render(), as: UTF8.self)
        XCTAssertFalse(rendered.contains("rdf:Description"))
    }
}
