//
//  JustifyTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import PDFKit
import XCTest
@testable import TextPDF

final class JustifyTests: XCTestCase {

    private let prose = """
        Infrastructure engineer with eleven years on payment and ledger systems, \
        most of it on the reliability side of teams that could not afford an outage, \
        and happiest reducing a system nobody wants to touch into something three \
        people can change safely between them.
        """

    private func arial() throws -> FontFamily {
        let path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Arial is not installed")
        var family = FontFamily(name: "Arial")
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: path)), weight: .regular)
        return family
    }

    /// The x of every `Td` in the stream, in order.
    private func origins(_ pdf: Data) -> [Double] {
        let text = String(data: pdf, encoding: .isoLatin1) ?? ""
        return text.components(separatedBy: "\n").compactMap { line in
            guard line.hasSuffix(" Td") else { return nil }
            return Double(line.split(separator: " ").first ?? "")
        }
    }

    func testJustifiedTextReachesBothEdges() throws {
        let pdf = Document(margin: 50)
        pdf.block(prose, x: 50, width: 300, size: 10, align: .justified)

        let data = pdf.render()
        let text = String(data: data, encoding: .isoLatin1) ?? ""

        // Each justified line is drawn a word at a time, so there are far more
        // placements than there are lines.
        XCTAssertGreaterThan(origins(data).count, 10, "the line was not broken into words")
        XCTAssertTrue(text.contains("Infrastructure"))
    }

    func testTheLastLineIsNotStretched() throws {
        let pdf = Document(margin: 50)
        pdf.block("one two three four five six seven eight nine ten eleven twelve",
                  x: 50, width: 120, size: 10, align: .justified)

        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("twelve"))
    }

    func testASingleWordLineIsLeftAlone() {
        let pdf = Document(margin: 50)
        pdf.block("Infrastructure", x: 50, width: 300, size: 10, align: .justified)

        // One placement, at the left edge — not stretched across the measure.
        XCTAssertEqual(origins(pdf.render()), [50])
    }

    func testJustifiedTextStillExtractsAsWords() throws {
        // Words placed individually must still copy as a sentence.
        let pdf = Document(margin: 50)
        pdf.block(prose, x: 50, width: 300, size: 10, align: .justified)

        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let read = try XCTUnwrap(document.string)
        XCTAssertTrue(read.contains("eleven years"), read)
        XCTAssertTrue(read.contains("change safely"), read)
    }

    func testItWorksWithAnEmbeddedFamily() throws {
        // The case Tw cannot do: under Identity-H byte 32 is half a character
        // code, so word spacing has to be placement rather than an operator.
        let pdf = Document(margin: 50)
        pdf.family = try arial()
        pdf.block(prose, x: 50, width: 300, size: 10, align: .justified)

        let data = pdf.render()
        XCTAssertGreaterThan(origins(data).count, 10)

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("eleven years"))
    }

    func testAnOverlongLineIsNotRunBackwards() {
        // A negative gap would draw the words over one another, right to left.
        let pdf = Document(margin: 50)
        pdf.block("supercalifragilisticexpialidocious", x: 50, width: 20, size: 10, align: .justified)

        let placements = origins(pdf.render())
        XCTAssertEqual(placements, placements.sorted(), "words were placed backwards")
    }

    func testLeftAlignmentIsUnchanged() {
        let justified = Document(margin: 50)
        justified.block(prose, x: 50, width: 300, size: 10, align: .justified)

        let ragged = Document(margin: 50)
        ragged.block(prose, x: 50, width: 300, size: 10, align: .left)

        // Ragged-right draws one placement per line; justified draws one per word.
        XCTAssertLessThan(origins(ragged.render()).count, origins(justified.render()).count)
    }
}
