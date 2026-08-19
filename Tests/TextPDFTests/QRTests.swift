//
//  QRTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import CoreImage
import PDFKit
import XCTest
@testable import TextPDF

final class QRTests: XCTestCase {

    /// The EPC payload a European bank app expects from an invoice.
    private let payload = """
        BCD
        002
        1
        SCT

        Meridian Studio Ltd
        GB29NWBK60161331926819
        GBP898.80


        INV-2026-0042
        """

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    /// Reads the page back the way a phone would.
    private func scan(_ data: Data, resolution: Double = 1200) throws -> String? {
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        var box = CGRect(x: 0, y: 0, width: resolution, height: resolution * 1.414)
        let image = try XCTUnwrap(
            page.thumbnail(of: box.size, for: .mediaBox)
                .cgImage(forProposedRect: &box, context: nil, hints: nil)
        )

        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) as? [CIQRCodeFeature]
        return features?.first?.messageString
    }

    // MARK: It scans

    func testACodeReadsBackExactly() throws {
        // The only test that matters: put it on a page, photograph the page,
        // get the string back. Everything else is an implementation detail.
        let pdf = Document()
        XCTAssertTrue(pdf.qr(payload, x: 60, y: 560, size: 150))

        XCTAssertEqual(try scan(pdf.render()), payload)
    }

    func testItSurvivesBeingSmall() throws {
        // 70 points is about the floor for a printed page read at arm's
        // length, and the reason the documentation says so.
        let pdf = Document()
        pdf.qr("https://arraypress.com/pay/INV-2026-0042", x: 60, y: 600, size: 70)

        XCTAssertEqual(try scan(pdf.render()), "https://arraypress.com/pay/INV-2026-0042")
    }

    func testEveryCorrectionLevelStillScans() throws {
        for correction in Document.QRCorrection.allCases {
            let pdf = Document()
            pdf.qr("INV-2026-0042", x: 60, y: 600, size: 140, correction: correction)
            XCTAssertEqual(try scan(pdf.render()), "INV-2026-0042", correction.rawValue)
        }
    }

    func testACodeInAColourStillScans() throws {
        let pdf = Document()
        pdf.qr(payload, x: 60, y: 560, size: 150, color: .hex("#1F3A5F"))
        XCTAssertEqual(try scan(pdf.render()), payload)
    }

    func testTwoCodesOnOnePageBothSurvive() throws {
        let pdf = Document()
        pdf.qr("first", x: 60, y: 600, size: 120)
        pdf.qr("second", x: 320, y: 600, size: 120)

        // The detector finds whichever it likes first; both must be there.
        let found = try XCTUnwrap(scan(pdf.render()))
        XCTAssertTrue(["first", "second"].contains(found), found)
        XCTAssertTrue(try raw(pdf.render()).contains(" re\n"))
    }

    // MARK: It is vector

    func testItIsDrawnRatherThanEmbedded() throws {
        // The point of drawing it: a bitmap at the wrong scale arrives
        // soft-edged and a scanner has to work for it.
        let pdf = Document()
        pdf.qr(payload, x: 60, y: 560, size: 150)

        let rendered = try raw(pdf.render())
        XCTAssertFalse(rendered.contains("/Subtype /Image"), "the code was embedded as a picture")
        XCTAssertGreaterThan(rendered.components(separatedBy: " re\n").count - 1, 100,
                             "a code is hundreds of squares; this is not one")
    }

    func testTheWholeCodeIsOneFill() throws {
        // A few hundred squares filled one at a time would be a few hundred
        // graphics state changes for a shape that is one colour throughout.
        let pdf = Document()
        pdf.qr(payload, x: 60, y: 560, size: 150)

        let lines = try raw(pdf.render()).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0 == "f" }.count, 1)
    }

    func testItStaysInsideTheSquareItWasGiven() throws {
        let pdf = Document()
        pdf.qr(payload, x: 100, y: 200, size: 150)

        let rectangles = try raw(pdf.render())
            .split(separator: "\n")
            .filter { $0.hasSuffix(" re") }
            .map { $0.split(separator: " ").compactMap { Double($0) } }

        XCTAssertFalse(rectangles.isEmpty)
        for rect in rectangles where rect.count == 4 {
            XCTAssertGreaterThanOrEqual(rect[0], 100)
            XCTAssertGreaterThanOrEqual(rect[1], 200)
            XCTAssertLessThanOrEqual(rect[0] + rect[2], 250.01, "a module ran past the right edge")
            XCTAssertLessThanOrEqual(rect[1] + rect[3], 350.01, "a module ran past the top edge")
        }
    }

    // MARK: The quiet zone

    func testTheQuietZoneIsInsideTheSquare() throws {
        // So `size` is the space the code occupies on the page, margin and
        // all — otherwise a layout that allows exactly 150 points overflows.
        let wide = Document()
        wide.qr("INV-2026-0042", x: 0, y: 0, size: 150, quiet: 4)

        let tight = Document()
        tight.qr("INV-2026-0042", x: 0, y: 0, size: 150, quiet: 0)

        func firstModule(_ document: Document) throws -> Double {
            let rects = try raw(document.render()).split(separator: "\n")
                .filter { $0.hasSuffix(" re") }
                .compactMap { Double($0.split(separator: " ")[0]) }
            return try XCTUnwrap(rects.min())
        }

        XCTAssertGreaterThan(try firstModule(wide), try firstModule(tight),
                             "the quiet zone did not push the modules in")
        XCTAssertEqual(try firstModule(tight), 0, accuracy: 0.01)
    }

    func testACodeWithNoQuietZoneStillScansWhenTheresRoom() throws {
        // Scanners want the margin, but the page around it can supply it.
        let pdf = Document()
        pdf.qr("INV-2026-0042", x: 200, y: 400, size: 120, quiet: 0)
        XCTAssertEqual(try scan(pdf.render()), "INV-2026-0042")
    }

    // MARK: Refusing

    func testNothingIsDrawnForEmptyText() throws {
        let pdf = Document()
        XCTAssertFalse(pdf.qr("   ", x: 60, y: 600, size: 150))
        XCTAssertFalse(try raw(pdf.render()).contains(" re\n"))
    }

    func testTooMuchTextIsRefusedRatherThanSmudged() throws {
        // A code that cannot hold the string is not a code, and drawing one
        // anyway means somebody discovers it at a till.
        let pdf = Document()
        let novel = String(repeating: "A", count: 8_000)

        XCTAssertFalse(pdf.qr(novel, x: 60, y: 600, size: 150, correction: .high))
        XCTAssertFalse(try raw(pdf.render()).contains(" re\n"))
    }

    func testAReturnValueThatSaysItWorked() throws {
        let pdf = Document()
        XCTAssertTrue(pdf.qr("INV-1", x: 60, y: 600, size: 150))
    }
}
