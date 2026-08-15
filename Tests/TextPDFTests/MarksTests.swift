//
//  MarksTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import PDFKit
import XCTest
@testable import TextPDF

final class MarksTests: XCTestCase {

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    // MARK: Transparency

    func testAlphaBecomesAGraphicsState() throws {
        let pdf = Document()
        pdf.transparent(0.2) { pdf.text("Faint") }

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/ExtGState"), "no graphics state was written")
        XCTAssertTrue(rendered.contains("/ca 0.200"), "the fill alpha is not there")
        XCTAssertTrue(rendered.contains("/CA 0.200"), "the stroke alpha is not there")
        XCTAssertTrue(rendered.contains("/GS0 gs"), "the stream never selects it")
    }

    func testTheSameAlphaIsNamedOnce() throws {
        let pdf = Document()
        for _ in 0..<5 { pdf.transparent(0.3) { pdf.text("x") } }

        let rendered = try raw(pdf.render())
        XCTAssertEqual(rendered.components(separatedBy: "/ca 0.300").count - 1, 1,
                       "the same alpha was written five times")
    }

    func testFullyOpaqueCostsNothing() throws {
        let pdf = Document()
        pdf.transparent(1) { pdf.text("Solid") }

        // No state, no q/Q: asking for opacity 1 is asking for nothing.
        XCTAssertFalse(try raw(pdf.render()).contains("/ExtGState"))
    }

    func testAlphaIsClamped() throws {
        let pdf = Document()
        pdf.transparent(-2) { pdf.text("x") }
        pdf.transparent(9) { pdf.text("y") }

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/ca 0.000"))
        XCTAssertFalse(rendered.contains("/ca 9"), "an alpha above 1 reached the file")
    }

    // MARK: Rotation

    func testRotationWritesAMatrixAndClosesIt() throws {
        let pdf = Document()
        pdf.rotated(by: 90, around: 100, 100) { pdf.textAt("Sideways", x: 100, y: 100, size: 12) }

        let rendered = try raw(pdf.render())
        // cos 90 = 0, sin 90 = 1.
        XCTAssertTrue(rendered.contains("0.00000 1.00000 -1.00000 0.00000"), rendered)
        // Counted as whole lines: "q" and "Q" also occur inside hex strings
        // and font names, and a substring search finds those too.
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.filter { $0 == "q" }.count, lines.filter { $0 == "Q" }.count,
                       "the graphics state was not balanced")
        XCTAssertGreaterThan(lines.filter { $0 == "q" }.count, 0)
    }

    func testRotatingByNothingStillDraws() throws {
        let pdf = Document()
        pdf.rotated(by: 0, around: 0, 0) { pdf.text("Straight") }
        XCTAssertNotNil(PDFDocument(data: pdf.render()))
        XCTAssertTrue(try raw(pdf.render()).contains("(Straight) Tj"))
    }

    // MARK: Watermarks

    func testAWatermarkAppearsOnEveryPage() throws {
        let pdf = Document()
        pdf.watermark("DRAFT")
        pdf.text("One")
        pdf.pageBreak()
        pdf.text("Two")

        let rendered = try raw(pdf.render())
        XCTAssertEqual(rendered.components(separatedBy: "(DRAFT) Tj").count - 1, 2,
                       "the watermark did not reach both pages")
    }

    func testAWatermarkIsBehindTheTextByDefault() throws {
        // A watermark over a total is a watermark that costs a phone call.
        let pdf = Document()
        pdf.watermark("PAID")
        pdf.text("Total due £898.80")

        let rendered = try raw(pdf.render())
        let mark = try XCTUnwrap(rendered.range(of: "(PAID) Tj"))
        let total = try XCTUnwrap(rendered.range(of: "Total due"))
        XCTAssertLessThan(mark.lowerBound, total.lowerBound, "the mark was drawn over the content")
    }

    func testAWatermarkCanBeAskedToGoOverTheTop() throws {
        let pdf = Document()
        pdf.watermark("VOID", over: true)
        pdf.text("Total due £898.80")

        let rendered = try raw(pdf.render())
        let mark = try XCTUnwrap(rendered.range(of: "(VOID) Tj"))
        let total = try XCTUnwrap(rendered.range(of: "Total due"))
        XCTAssertGreaterThan(mark.lowerBound, total.lowerBound)
    }

    func testAnEmptyWatermarkDrawsNothing() throws {
        let pdf = Document()
        pdf.watermark("   ")
        pdf.text("Body")
        XCTAssertFalse(try raw(pdf.render()).contains("/ExtGState"))
    }

    func testTheDocumentStillReadsUnderAWatermark() throws {
        let pdf = Document()
        pdf.watermark("DRAFT")
        pdf.text("Total due £898.80")

        let text = try XCTUnwrap(PDFDocument(data: pdf.render())?.string)
        XCTAssertTrue(text.contains("Total due"), "the content stopped extracting")
        XCTAssertTrue(text.contains("DRAFT"), "the mark should be selectable text, not a picture")
    }

    // MARK: Dashes

    func testADashedLineCarriesItsPattern() throws {
        let pdf = Document()
        pdf.line(from: 40, 700, to: 300, 700, dash: [3, 2])

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("[3.00 2.00] 0 d"), rendered)
    }

    func testASolidLineSetsNoPattern() throws {
        let pdf = Document()
        pdf.line(from: 40, 700, to: 300, 700)
        XCTAssertFalse(try raw(pdf.render()).contains(" d\n"))
    }

    // MARK: Bookmarks

    func testBookmarksBecomeAnOutline() throws {
        let pdf = Document()
        pdf.bookmark("Summary")
        pdf.text("One")
        pdf.pageBreak()
        pdf.bookmark("Detail")
        pdf.text("Two")

        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let root = try XCTUnwrap(document.outlineRoot, "no outline was written")

        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 0)?.label, "Summary")
        XCTAssertEqual(root.child(at: 1)?.label, "Detail")
    }

    func testABookmarkPointsAtItsOwnPage() throws {
        let pdf = Document()
        pdf.text("One")
        pdf.pageBreak()
        pdf.bookmark("Second page")
        pdf.text("Two")

        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let child = try XCTUnwrap(document.outlineRoot?.child(at: 0))
        let destination = try XCTUnwrap(child.destination)

        XCTAssertEqual(document.index(for: try XCTUnwrap(destination.page)), 1,
                       "the bookmark points at the wrong page")
    }

    func testAnEmptyBookmarkIsIgnored() throws {
        let pdf = Document()
        pdf.bookmark("  ")
        pdf.text("Body")
        XCTAssertNil(PDFDocument(data: pdf.render())?.outlineRoot)
    }

    func testADocumentWithoutBookmarksHasNoOutline() throws {
        let pdf = Document()
        pdf.text("Body")

        let rendered = try raw(pdf.render())
        XCTAssertFalse(rendered.contains("/Outlines"), "an empty outline tree was written")
        XCTAssertFalse(rendered.contains("/PageMode"))
    }

    // MARK: Together

    func testAllOfItAtOnce() throws {
        let pdf = Document()
        pdf.watermark("DRAFT")
        pdf.bookmark("Statement")
        pdf.text("Statement of account", size: 18)
        pdf.line(from: 48, pdf.cursor(), to: 300, pdf.cursor(), dash: [2, 2])

        let data = pdf.render()
        let document = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1)
        XCTAssertTrue(try raw(data).contains("/ExtGState"))
        XCTAssertTrue(try raw(data).contains("] 0 d"))
    }
}
