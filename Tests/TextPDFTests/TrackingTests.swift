//
//  TrackingTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Letter-spacing, and the measuring that has to agree with it.
//

import PDFKit
import XCTest
@testable import TextPDF

final class TrackingTests: XCTestCase {

    private func stream(of pdf: Data) -> String {
        String(data: pdf, encoding: .isoLatin1) ?? ""
    }

    func testTrackingIsEmittedOnlyWhenAsked() {
        let plain = Document()
        plain.textAt("EXPERIENCE", x: 50, y: 700, size: 8)
        XCTAssertFalse(stream(of: plain.render()).contains(" Tc"), "an unspaced run should set no Tc")

        let spaced = Document()
        spaced.textAt("EXPERIENCE", x: 50, y: 700, size: 8, tracking: 0.6)
        XCTAssertTrue(stream(of: spaced.render()).contains("0.600 Tc"))
    }

    func testTrackingWidensTheMeasurement() {
        let pdf = Document()
        let plain = pdf.width(of: "EXPERIENCE", size: 8)
        let spaced = pdf.width(of: "EXPERIENCE", size: 8, tracking: 0.6)

        // Nine gaps between ten letters, not ten: the trailing gap is empty
        // space past the last glyph.
        XCTAssertEqual(spaced - plain, 0.6 * 9, accuracy: 0.001)
    }

    func testASingleCharacterGainsNothing() {
        let pdf = Document()
        XCTAssertEqual(
            pdf.width(of: "E", size: 8, tracking: 2),
            pdf.width(of: "E", size: 8),
            accuracy: 0.001
        )
    }

    func testRightAlignedTrackedTextStaysInsideItsBox() throws {
        // The bug this guards: aligning from an untracked measurement pushes
        // the run past the right margin by the whole accumulated spacing,
        // which on a date column is visibly out against the rule above it.
        let pdf = Document()
        let box = 200.0
        let size = 9.0
        let tracking = 0.8
        let label = "2022 – Present"

        pdf.textAt(label, x: 100, y: 700, size: size,
                   align: .right, boxWidth: box, tracking: tracking)

        let measured = pdf.width(of: label, size: size, tracking: tracking)
        let expectedOrigin = 100 + box - measured

        let rendered = stream(of: pdf.render())
        XCTAssertTrue(
            rendered.contains(String(format: "%.2F 700.00 Td", expectedOrigin)),
            "text was not placed at the tracked right edge"
        )
        XCTAssertLessThan(expectedOrigin + measured, 100 + box + 0.01)
    }

    func testTrackingDoesNotLeakIntoTheNextRun() throws {
        // Tc is text state, and text state is part of the graphics state. If
        // the q/Q pair did not contain it, every run after a tracked heading
        // would inherit the spacing.
        let pdf = Document()
        pdf.textAt("EXPERIENCE", x: 50, y: 700, size: 8, tracking: 1.5)
        pdf.textAt("Stripe", x: 50, y: 680, size: 10)

        let rendered = stream(of: pdf.render())
        let blocks = rendered.components(separatedBy: "BT\n")
        XCTAssertEqual(blocks.filter { $0.contains(" Tc") }.count, 1, "Tc appeared in more than one run")

        // And the reader agrees the text is still readable.
        let opened = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let read = try XCTUnwrap(opened.string)
        XCTAssertTrue(read.contains("Stripe"))
    }

    func testTrackedTextIsStillExtractedAsWords() throws {
        // Letter-spacing is a rendering instruction, not gaps in the string.
        // If it were drawn as padded characters the text would extract as
        // "E X P E R I E N C E" and no keyword search would find it.
        let pdf = Document()
        pdf.textAt("EXPERIENCE", x: 50, y: 700, size: 8, tracking: 1.2)

        let opened = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let read = try XCTUnwrap(opened.string).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(read, "EXPERIENCE")
    }
}
