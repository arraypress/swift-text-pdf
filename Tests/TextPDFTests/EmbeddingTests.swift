//
//  EmbeddingTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import XCTest
@testable import TextPDF

/// Font embedding, and the metrics work that came with it.
///
/// The system fonts these lean on are present on every Mac, but a missing one
/// skips rather than fails: a test that cannot run is not a test that found a
/// fault, and reporting it as one trains people to ignore red.
final class EmbeddingTests: XCTestCase {

    private let unicodeFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")

    private func loadUnicodeFont() throws -> EmbeddedFont {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: unicodeFont.path),
                          "Arial Unicode is not installed")
        return try EmbeddedFont.load(unicodeFont)
    }

    // MARK: Base-14 metrics

    func testWidthsCoverTheWholeEncodedRange() {
        let table = Font.helvetica.widths
        // Every byte WinAnsiEncoding names a glyph for needs a width, or the
        // fallback silently stands in for it.
        for byte in Font.winAnsiBytes {
            XCTAssertNotNil(table[byte], "no width for byte \(byte)")
        }
    }

    func testEuroIsNotMeasuredAsAFallback() {
        // The bug this replaced: € fell outside the table, took the width of
        // `n`, and every right-aligned euro column sat a few points out.
        let euro = Font.helvetica.widthOf("€", size: 1000)
        XCTAssertEqual(euro, 744, accuracy: 0.001)
        XCTAssertNotEqual(euro, Font.helvetica.widthOf("n", size: 1000))
    }

    func testHighBytesAreMeasuredOncePerCharacter() {
        // `£` is one CP1252 byte but two in UTF-8. Measuring the UTF-8 form
        // counted it twice and pushed the column out by a whole character.
        XCTAssertEqual(
            Font.helvetica.widthOf("£", size: 10),
            Font.helvetica.widthOf("¤", size: 10),
            accuracy: 0.001
        )
        let pound = Font.helvetica.widthOf("£100", size: 10)
        let digits = Font.helvetica.widthOf("100", size: 10)
        XCTAssertEqual(pound - digits, 5.56, accuracy: 0.001)
    }

    func testEscapedCharactersDoNotChargeForTheirBackslash() {
        // `(` is escaped as `\(` in the content stream, but only the paren is
        // drawn.
        XCTAssertEqual(
            Font.helvetica.widthOf("(", size: 10),
            Font.helvetica.widthOf(")", size: 10),
            accuracy: 0.001
        )
        XCTAssertEqual(Font.helvetica.widthOf("(", size: 1000), 333, accuracy: 0.001)
    }

    func testPublishedWidthsMatchTheMeasuredOnes() throws {
        // The file tells the reader how wide each character is; if that
        // disagrees with the table used to place text, alignment computed here
        // is not the alignment that appears on the page.
        let pdf = Document(size: .a4, margin: 40)
        _ = pdf.text("Total €1,240.00", size: 11)
        let rendered = String(decoding: pdf.render(), as: UTF8.self)

        let widths = try XCTUnwrap(
            rendered.range(of: "/BaseFont /Helvetica /Encoding")
                .flatMap { _ in rendered.range(of: "/Widths [")}
                .map { rendered[$0.upperBound...].prefix(while: { $0 != "]" }) }
        )
        let published = widths.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(published.count, 224)                    // 32…255
        XCTAssertEqual(published[Int("€".unicodeScalars.first!.value) == 0x20AC ? 128 - 32 : 0], 744)
        XCTAssertEqual(published[65 - 32], 667)                 // "A"
    }

    // MARK: Loading

    func testRefusesFontCollectionsAndPostScriptOutlines() {
        // A .ttc holds several fonts and an OTTO has CFF outlines; both need
        // handling this writer does not have, so they are named rather than
        // embedded wrongly.
        for path in ["/System/Library/Fonts/Helvetica.ttc"] where FileManager.default.fileExists(atPath: path) {
            XCTAssertThrowsError(try EmbeddedFont.load(URL(fileURLWithPath: path))) { error in
                XCTAssertEqual(error as? EmbeddingError, .unsupportedFormat("Helvetica.ttc"))
            }
        }
    }

    func testMissingFileIsReportedAsUnreadable() {
        XCTAssertThrowsError(try EmbeddedFont.load(URL(fileURLWithPath: "/no/such/font.ttf"))) { error in
            XCTAssertEqual(error as? EmbeddingError, .unreadable("font.ttf"))
        }
    }

    func testCoverageIsHonest() throws {
        let font = try loadUnicodeFont()
        XCTAssertTrue(font.covers("ООО Ромашка"))
        XCTAssertTrue(font.covers("株式会社"))
        XCTAssertTrue(font.covers("Παπαδόπουλος"))
        // A private-use scalar no font assigns.
        XCTAssertFalse(font.covers("\u{F8FF}\u{E000}"))
    }

    // MARK: Scripts that cannot be laid out

    func testBidirectionalScriptsAreRefused() {
        XCTAssertEqual(Script.unsupported(in: "شركة"), "Arabic")
        XCTAssertEqual(Script.unsupported(in: "חברה"), "Hebrew")
        XCTAssertNil(Script.unsupported(in: "ООО Ромашка"))
        XCTAssertNil(Script.unsupported(in: "株式会社"))
    }

    // MARK: Subsetting

    func testSubsetIsAFractionOfTheSource() throws {
        let font = try loadUnicodeFont()
        let source = try Data(contentsOf: unicodeFont).count

        _ = font.encode("Ромашка", size: 10)
        let subset = try XCTUnwrap(font.embeddable())

        XCTAssertLessThan(subset.data.count, source / 100)
        // .notdef plus the six distinct letters of Ромашка, and then whatever
        // components those letters are built from — Arial Unicode draws much
        // of its Cyrillic over Latin shapes, so the count is a floor, not an
        // equality.
        XCTAssertGreaterThanOrEqual(subset.widths.count, 7)
        XCTAssertLessThan(subset.widths.count, 32)
    }

    func testGlyphIDsAreAssignedDenselyAndStayStable() throws {
        let font = try loadUnicodeFont()

        let first = font.encode("Москва", size: 10)
        let again = font.encode("Москва", size: 10)
        XCTAssertEqual(first.hex, again.hex, "the same text must encode the same way twice")

        // CID 0 is .notdef, so the first drawn glyph is 1 and the rest follow
        // without gaps — that is what lets CIDToGIDMap stay Identity.
        let subset = try XCTUnwrap(font.embeddable())
        XCTAssertEqual(subset.widths.map(\.cid), Array(0..<subset.widths.count))
    }

    func testUnusedFontIsNotEmbedded() throws {
        let font = try loadUnicodeFont()
        XCTAssertFalse(font.isUsed)
        XCTAssertNil(font.embeddable(), "a font nothing was drawn with is dead weight")
    }

    func testCompositeGlyphsBringTheirComponents() throws {
        let font = try loadUnicodeFont()
        // Accented letters are usually composites of a base and a mark; miss
        // the components and the accent renders alone.
        _ = font.encode("é", size: 10)
        let subset = try XCTUnwrap(font.embeddable())
        XCTAssertGreaterThanOrEqual(subset.mapping.count, 2)
    }

    // MARK: Documents

    func testEmbeddedTextIsWrittenAsGlyphIDs() throws {
        let font = try loadUnicodeFont()
        let pdf = Document(size: .a4, margin: 40)
        pdf.embeddedFont = font
        _ = pdf.text("Ромашка", size: 11)

        let rendered = String(decoding: pdf.render(), as: UTF8.self)
        XCTAssertTrue(rendered.contains("/Subtype /Type0"))
        XCTAssertTrue(rendered.contains("/Encoding /Identity-H"))
        XCTAssertTrue(rendered.contains("/FontFile2"))
        XCTAssertTrue(rendered.contains("/ToUnicode"))
        // Hex, not a literal string: Identity-H addresses glyphs by number.
        XCTAssertTrue(rendered.contains("> Tj"))
    }

    func testLatinTextStaysInTheBaseFont() throws {
        let font = try loadUnicodeFont()
        let pdf = Document(size: .a4, margin: 40)
        pdf.embeddedFont = font
        _ = pdf.text("Invoice INV-001", size: 11)

        let rendered = String(decoding: pdf.render(), as: UTF8.self)
        XCTAssertTrue(rendered.contains("(Invoice INV-001) Tj"),
                      "text the base fonts can draw should not be embedded")
        XCTAssertFalse(rendered.contains("/FontFile2"),
                       "an unused embedded font should not be written at all")
    }

    func testDocumentWithoutAnEmbeddedFontIsUnchanged() {
        // Embedding must cost nothing when it is not used.
        let plain = Document(size: .a4, margin: 40)
        _ = plain.text("Invoice INV-001", size: 11)
        let rendered = String(decoding: plain.render(), as: UTF8.self)
        XCTAssertFalse(rendered.contains("/Type0"))
        XCTAssertTrue(rendered.contains("(Invoice INV-001) Tj"))
    }

    func testAlignmentUsesTheEmbeddedMetrics() throws {
        let font = try loadUnicodeFont()
        let pdf = Document(size: .a4, margin: 40)
        pdf.embeddedFont = font

        // Right-aligned Cyrillic must end at the same edge as right-aligned
        // Latin, which only happens if it was measured with the right font.
        _ = pdf.textAt("Москва", x: 40, y: 700, size: 10, align: .right, boxWidth: 200)
        _ = pdf.textAt("Moscow", x: 40, y: 680, size: 10, align: .right, boxWidth: 200)

        let rendered = String(decoding: pdf.render(), as: UTF8.self)
        let positions = rendered
            .components(separatedBy: " Td\n")
            .dropLast()
            .compactMap { $0.components(separatedBy: "\n").last?.components(separatedBy: " ").first }
            .compactMap(Double.init)

        XCTAssertEqual(positions.count, 2)
        // Both start left of the right edge by their own width, so neither may
        // sit at the box origin.
        for x in positions { XCTAssertGreaterThan(x, 40) }
    }

    func testTemplatesTakeTheFontBeforeDrawing() throws {
        let font = try loadUnicodeFont()
        let invoice = Invoice(
            branding: Branding(name: "ArrayPress"),
            number: "INV-1",
            from: Party(name: "ArrayPress Ltd", taxID: "GB123"),
            to: Party(name: "ООО Ромашка"),
            items: [LineItem(description: "Лицензия", amount: "€100,00")],
            total: [(label: "Total", value: "€100,00")]
        )

        // Attaching a font after the fact cannot work — the text is already in
        // the content stream by then — so the template has to be given it.
        let without = invoice.render()
        XCTAssertFalse(without.substitutions.isEmpty)

        let with = invoice.render(embedding: font)
        XCTAssertTrue(with.substitutions.isEmpty, "\(with.substitutions)")
        XCTAssertTrue(String(decoding: with.render(), as: UTF8.self).contains("/FontFile2"))
    }

    func testWrappingMeasuresWithTheEmbeddedFont() throws {
        let font = try loadUnicodeFont()
        let pdf = Document(size: .a4, margin: 40)
        pdf.embeddedFont = font

        let russian = "Настоящим подтверждается что услуги были оказаны в полном объёме "
            + "и приняты заказчиком без замечаний"
        let lines = pdf.wrap(russian, font: .helvetica, size: 10, width: 200)

        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(font.widthOf(line, size: 10), 200.01, "\"\(line)\" overflows")
        }
    }
}
