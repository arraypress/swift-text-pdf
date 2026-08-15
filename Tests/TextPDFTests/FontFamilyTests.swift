//
//  FontFamilyTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Embedding a family, rather than a single fallback face.
//
//  The distinction these guard: ``Document/embeddedFont`` is reached for only
//  when Windows-1252 cannot hold the text, where a ``FontFamily`` sets the
//  whole document. Getting that backwards produces either a document in the
//  wrong typeface or one carrying a font subset it never uses.
//

import XCTest
@testable import TextPDF

final class FontFamilyTests: XCTestCase {

    private let regularPath = "/System/Library/Fonts/Supplemental/Arial.ttf"
    private let boldPath = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    private let italicPath = "/System/Library/Fonts/Supplemental/Arial Italic.ttf"

    /// Arial in three files, or a skip. A test that cannot run has not found a
    /// fault, and reporting it as one trains people to ignore red.
    private func loadFamily() throws -> FontFamily {
        let manager = FileManager.default
        try XCTSkipUnless(
            [regularPath, boldPath, italicPath].allSatisfy(manager.fileExists(atPath:)),
            "Arial is not installed in three separate files"
        )
        var family = FontFamily(name: "Arial")
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: regularPath)), weight: .regular)
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: boldPath)), weight: .bold)
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: italicPath)), weight: .regular, italic: true)
        return family
    }

    private func text(of pdf: Data) -> String {
        String(data: pdf, encoding: .isoLatin1) ?? ""
    }

    // MARK: Metrics

    func testMetricsAreReadFromTheFontNotAssumed() throws {
        let family = try loadFamily()
        let regular = try XCTUnwrap(family.face(.regular))

        // The base-14 code assumes 0.78 and 0.717 of the point size. Arial
        // declares its own, and they are not those — which is the whole point
        // of reading them. A document set in a face positions every baseline
        // from this number.
        XCTAssertNotEqual(regular.ascender(100), Font.helvetica.ascender(100), accuracy: 0.001)
        XCTAssertGreaterThan(regular.capHeight(100), 60)
        XCTAssertLessThan(regular.capHeight(100), 80)

        // A descender read unsigned becomes 65316 rather than -220, and every
        // line acquires a 65-em gap.
        XCTAssertGreaterThan(regular.descender(100), 0)
        XCTAssertLessThan(regular.descender(100), 40)
    }

    func testTheBoldFaceDeclaresItselfBold() throws {
        let family = try loadFamily()
        XCTAssertTrue(try XCTUnwrap(family.face(.bold)).isBold)
        XCTAssertFalse(try XCTUnwrap(family.face(.regular)).isBold)
        XCTAssertTrue(try XCTUnwrap(family.face(.regular, italic: true)).isItalic)
    }

    // MARK: What a family draws

    func testAFamilySetsPlainLatinTextToo() throws {
        // The behaviour that separates a family from a fallback. `embeddedFont`
        // would leave this in Helvetica and embed nothing.
        let pdf = Document()
        pdf.family = try loadFamily()
        pdf.text("Senior Engineer")

        let rendered = text(of: pdf.render())
        XCTAssertTrue(rendered.contains("/FontFile2"), "the family should have been embedded")
        XCTAssertTrue(rendered.contains("/F4"), "text should be drawn with the embedded face")
    }

    func testAFallbackFontStillOnlyDrawsWhatWindowsCannot() throws {
        // Backward compatibility: documents written before families existed
        // must keep their Helvetica typography.
        let manager = FileManager.default
        try XCTSkipUnless(manager.fileExists(atPath: regularPath), "Arial is not installed")

        let pdf = Document()
        pdf.embeddedFont = try EmbeddedFont.load(URL(fileURLWithPath: regularPath))
        pdf.text("Senior Engineer")

        let rendered = text(of: pdf.render())
        XCTAssertFalse(rendered.contains("/FontFile2"), "Latin text should not have triggered embedding")
    }

    // MARK: Resources

    func testEachWeightGetsItsOwnResourceAndObject() throws {
        let pdf = Document()
        pdf.family = try loadFamily()
        pdf.text("Alex Morgan", font: .helveticaBold)
        pdf.text("Senior Engineer", font: .helvetica)

        let rendered = text(of: pdf.render())

        // Two faces drawn, so two subsets and two descendant fonts.
        XCTAssertEqual(rendered.components(separatedBy: "/FontFile2").count - 1, 2)
        XCTAssertEqual(rendered.components(separatedBy: "/CIDFontType2").count - 1, 2)
        XCTAssertTrue(rendered.contains("/F4"))
        XCTAssertTrue(rendered.contains("/F5"))
    }

    func testEveryFaceDrawnWithIsDeclaredInTheResources() throws {
        // The invariant that matters most. A `/F5` in a content stream that
        // the resource dictionary does not name resolves to nothing, and the
        // failure is silent — the text simply does not appear.
        let pdf = Document()
        pdf.family = try loadFamily()
        pdf.text("Alex Morgan", font: .helveticaBold)
        pdf.text("Senior Engineer", font: .helvetica)
        pdf.text("Formerly Stripe", face: pdf.face(.regular, italic: true))

        let rendered = text(of: pdf.render())

        let declared = try XCTUnwrap(
            rendered.range(of: "/Resources <</Font <<").map { range -> Set<String> in
                let tail = rendered[range.upperBound...]
                let dictionary = String(tail[tail.startIndex..<(tail.range(of: ">>")?.lowerBound ?? tail.endIndex)])
                return Set(names(in: dictionary))
            }
        )

        // Every /Fn appearing before a Tf operator must be in that dictionary.
        var used: Set<String> = []
        for line in rendered.components(separatedBy: "\n") where line.hasSuffix(" Tf") {
            used.formUnion(names(in: line))
        }

        XCTAssertFalse(used.isEmpty, "no text was drawn")
        XCTAssertTrue(used.isSubset(of: declared), "undeclared font resources: \(used.subtracting(declared))")
        XCTAssertTrue(used.contains("F6"), "the third face should have its own resource")
    }

    /// The `/Fn` tokens in a fragment of PDF syntax.
    private func names(in fragment: String) -> [String] {
        fragment
            .components(separatedBy: "/")
            .dropFirst()
            .compactMap { part in
                let name = part.prefix { !$0.isWhitespace }
                guard name.first == "F", name.dropFirst().allSatisfy(\.isNumber), name.count > 1 else {
                    return nil
                }
                return String(name)
            }
    }

    func testOnlyTheFacesActuallyDrawnAreEmbedded() throws {
        // A family carrying three weights of which a design uses one should
        // cost one subset, not three.
        let pdf = Document()
        pdf.family = try loadFamily()
        pdf.text("Senior Engineer", font: .helvetica)

        let rendered = text(of: pdf.render())
        XCTAssertEqual(rendered.components(separatedBy: "/FontFile2").count - 1, 1)
        XCTAssertFalse(rendered.contains("/F5"))
    }

    func testAFaceUsedOnlyByTheFooterIsStillEmbedded() throws {
        // Footers draw after the body is finished, so a face first used there
        // has to be registered before the face list is read.
        let pdf = Document()
        pdf.family = try loadFamily()
        pdf.text("Senior Engineer", font: .helvetica)
        pdf.onEachPage { doc, page, total in
            doc.textAt("Page \(page) of \(total)", x: 48, y: 40, size: 8, font: .helveticaBold)
        }

        let rendered = text(of: pdf.render())
        XCTAssertEqual(rendered.components(separatedBy: "/FontFile2").count - 1, 2)
    }

    // MARK: Resolution

    func testNearestWeightStandsInForAMissingOne() throws {
        let family = try loadFamily()

        // Semibold was never loaded; bold is nearer to it than regular.
        let semibold = try XCTUnwrap(family.face(.semibold))
        XCTAssertTrue(semibold.isBold)

        // Light is nearer to regular than to bold.
        XCTAssertFalse(try XCTUnwrap(family.face(.light)).isBold)
    }

    func testItalicFallsBackToUprightRatherThanDrawingNothing() throws {
        let manager = FileManager.default
        try XCTSkipUnless(manager.fileExists(atPath: regularPath), "Arial is not installed")

        var family = FontFamily(name: "Arial")
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: regularPath)), weight: .regular)

        let face = try XCTUnwrap(family.face(.regular, italic: true))
        XCTAssertFalse(face.isItalic, "there is no italic to find")
    }

    func testAnExplicitFaceOutranksTheFamily() throws {
        let family = try loadFamily()
        let pdf = Document()
        pdf.family = family

        // Asked for the regular role, but handed the italic explicitly.
        pdf.text("Formerly Stripe", font: .helvetica, face: family.face(.regular, italic: true))

        let rendered = text(of: pdf.render())
        XCTAssertTrue(rendered.contains("Italic"), "the named face should have been used")
    }

    // MARK: Measuring

    func testTextIsMeasuredWithTheFaceThatDrawsIt() throws {
        let family = try loadFamily()
        let pdf = Document()
        pdf.family = family

        let regular = try XCTUnwrap(family.face(.regular))
        let bold = try XCTUnwrap(family.face(.bold))

        // Bold Arial is wider than regular; if measurement ignored the family
        // both would come back as Helvetica and right-aligned columns would
        // sit out by the difference.
        XCTAssertEqual(pdf.measured("Alex Morgan", font: .helvetica, size: 10),
                       regular.widthOf("Alex Morgan", size: 10), accuracy: 0.001)
        XCTAssertEqual(pdf.measured("Alex Morgan", font: .helveticaBold, size: 10),
                       bold.widthOf("Alex Morgan", size: 10), accuracy: 0.001)
        XCTAssertGreaterThan(bold.widthOf("Alex Morgan", size: 10),
                             regular.widthOf("Alex Morgan", size: 10))
    }

    func testWrappingUsesTheFamilyMetrics() throws {
        let family = try loadFamily()
        let pdf = Document()
        pdf.family = family

        let sentence = String(repeating: "Engineering leadership ", count: 12)
        let wrapped = pdf.wrap(sentence, font: .helvetica, size: 10, width: 200)

        let face = try XCTUnwrap(family.face(.regular))
        for line in wrapped {
            XCTAssertLessThanOrEqual(face.widthOf(line, size: 10), 200.5, "\"\(line)\" overflows")
        }
    }
}
