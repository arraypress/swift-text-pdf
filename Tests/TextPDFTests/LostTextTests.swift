//
//  LostTextTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Text that did not reach the page as written is reported, never silent:
//  cut with an ellipsis, drawn off the edge of the page, or set in a font
//  that has no glyphs for it. Each is invisible on the page itself — a cut
//  value looks short, a clipped one looks like the end of the line, and a
//  question mark looks like a typo — so the document has to say.
//

import PDFKit
import XCTest
@testable import TextPDF

final class LostTextTests: XCTestCase {

    private func pageText(_ pdf: Document) throws -> String {
        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
    }

    // MARK: Shortening

    func testFitRecordsWhatItCut() {
        let pdf = Document()
        let long = "Katherine Johnson, NASA Langley Research Center"
        let shown = pdf.fit(long, into: 60, size: 10)

        XCTAssertTrue(shown.hasSuffix("..."))
        XCTAssertEqual(pdf.shortened, [Document.Shortening(text: long, shown: shown)])
        XCTAssertEqual(pdf.textWarnings.count, 1)
        XCTAssertTrue(pdf.textWarnings[0].contains(long))
    }

    func testFitThatCutsNothingRecordsNothing() {
        let pdf = Document()
        XCTAssertEqual(pdf.fit("Ada", into: 200, size: 10), "Ada")
        XCTAssertTrue(pdf.shortened.isEmpty)
        XCTAssertTrue(pdf.textWarnings.isEmpty)
    }

    // MARK: Off the page

    func testARunPastTheRightEdgeIsRecorded() throws {
        let pdf = Document(width: 200, height: 100, margin: 10)
        let url = "https://example.com/a/very/long/path/that/cannot/possibly/fit"
        pdf.textAt(url, x: 10, y: 50, size: 10)

        XCTAssertEqual(pdf.outsidePage, [url])
        XCTAssertEqual(pdf.textWarnings, ["\"\(url)\" runs off the edge of the page."])
        // And it really is clipped: the reader stops at the page box.
        XCTAssertFalse(try pageText(pdf).contains("fit"))
    }

    func testARunBelowTheFootIsRecorded() {
        let pdf = Document(width: 200, height: 100, margin: 10)
        pdf.textAt("Gone", x: 10, y: -20, size: 10)
        XCTAssertEqual(pdf.outsidePage, ["Gone"])
    }

    func testARunAboveTheTopIsRecorded() {
        let pdf = Document(width: 200, height: 100, margin: 10)
        pdf.textAt("Gone", x: 10, y: 99, size: 10)
        XCTAssertEqual(pdf.outsidePage, ["Gone"])
    }

    func testARunLeftOfThePageIsRecorded() {
        let pdf = Document(width: 200, height: 100, margin: 10)
        pdf.textAt("Gone", x: 0, y: 50, size: 10, align: .right, boxWidth: 5)
        XCTAssertEqual(pdf.outsidePage, ["Gone"])
    }

    /// Flush to every edge by arithmetic is on the page.
    func testARunFlushToTheEdgesIsNotRecorded() {
        let pdf = Document(width: 200, height: 100, margin: 0)
        pdf.textAt("Edge", x: 0, y: 0, size: 10)
        pdf.textAt("Edge", x: 0, y: 92.9, size: 10)
        pdf.textAt("Edge", x: 0, y: 50, size: 10, align: .right, boxWidth: 200)
        XCTAssertTrue(pdf.outsidePage.isEmpty, "\(pdf.outsidePage)")
    }

    /// An embedded face is measured by its own metrics, not Helvetica's.
    func testAnEmbeddedRunPastTheEdgeIsRecorded() throws {
        let path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Arial Unicode is not installed")
        let face = try EmbeddedFont.load(URL(fileURLWithPath: path))
        let pdf = Document(width: 200, height: 100, margin: 10)
        pdf.textAt("Москва Санкт-Петербург Новосибирск", x: 10, y: 50, size: 12, face: face)
        XCTAssertEqual(pdf.outsidePage.count, 1)
    }

    /// A watermark is set on a diagonal across the page; its unrotated
    /// coordinates run past the edges and that is not lost text.
    func testARotatedWatermarkIsNotRecorded() {
        let pdf = Document()
        pdf.text("Body")
        pdf.watermark("CONFIDENTIAL DRAFT COPY")
        _ = pdf.render()
        XCTAssertTrue(pdf.outsidePage.isEmpty, "\(pdf.outsidePage)")
    }

    /// Flowing text wraps inside the margins and is never outside.
    func testWrappedTextIsNeverOutside() {
        let pdf = Document()
        pdf.text(String(repeating: "supercalifragilistic ", count: 200)
                 + "https://example.com/" + String(repeating: "x", count: 400))
        XCTAssertTrue(pdf.outsidePage.isEmpty)
        XCTAssertTrue(pdf.textWarnings.isEmpty)
    }

    // MARK: Question marks

    func testSubstitutionsAreAmongTheWarnings() {
        let pdf = Document()
        pdf.text("Привет")
        XCTAssertEqual(pdf.textWarnings.count, 1)
        XCTAssertTrue(pdf.textWarnings[0].contains("Привет"))
        XCTAssertTrue(pdf.textWarnings[0].contains("?"))
    }
}
