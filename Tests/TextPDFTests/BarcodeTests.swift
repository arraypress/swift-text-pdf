//
//  BarcodeTests.swift
//  TextPDFTests
//
//  Created by David Sherlock on 2026.
//
//  Linear barcodes: the arithmetic, the refusals, and whether the thing actually scans.
//
//  THE SCANNING TESTS ARE THE ONES THAT MATTER. A barcode that looks like a barcode and
//  refuses to read is the only failure that costs anything — it is discovered at a till, by
//  somebody else, after the labels are stuck on. Vision reads every family drawn here, so the
//  round trip is available and there is no excuse for asserting anything weaker.
//

import CoreGraphics
import Foundation
import Vision
import XCTest
@testable import TextPDF

final class BarcodeTests: XCTestCase {

    // MARK: Check digits

    /// Modulo 10, weighted 3 and 1 from the right. Pure arithmetic, so a wrong payload is
    /// catchable before anything is drawn.
    func testCheckDigits() {
        XCTAssertEqual(Barcode.checkDigit(for: "501234567890"), 0)
        XCTAssertEqual(Barcode.checkDigit(for: "400638133393"), 1)
        // A real product: Coca-Cola 330ml, 5449000000996.
        XCTAssertEqual(Barcode.checkDigit(for: "544900000099"), 6)
        // UPC-A payload is 11 digits, which is odd — the weighting is taken from the end for
        // exactly this reason.
        XCTAssertEqual(Barcode.checkDigit(for: "01234567890"), 5)
    }

    func testCheckDigitRefusesNonDigits() {
        XCTAssertNil(Barcode.checkDigit(for: "50123456789X"))
        XCTAssertNil(Barcode.checkDigit(for: ""))
        XCTAssertNil(Barcode.checkDigit(for: "5012 4567890"))
    }

    func testWithCheckDigitAppendsIt() {
        XCTAssertEqual(Barcode.withCheckDigit("501234567890"), "5012345678900")
        XCTAssertNil(Barcode.withCheckDigit("nope"))
    }

    // MARK: Normalising

    func testTwelveDigitsGetTheirCheckDigitComputed() {
        guard case .success(let payload) = Barcode.normalise("501234567890", symbology: .ean13)
        else { return XCTFail("should have completed the payload") }
        XCTAssertEqual(payload, "5012345678900")
    }

    func testThirteenDigitsAreValidated() {
        guard case .success(let payload) = Barcode.normalise("5012345678900", symbology: .ean13)
        else { return XCTFail("a correct payload should pass") }
        XCTAssertEqual(payload, "5012345678900")
    }

    /// CoreImage reports this to the console and returns nil, so the caller learns only that
    /// something failed. Carrying the expected digit makes it fixable.
    func testABadCheckDigitNamesTheExpectedOne() {
        guard case .failure(let failure) = Barcode.normalise("5012345678901", symbology: .ean13)
        else { return XCTFail("a wrong check digit must be refused") }
        XCTAssertEqual(failure, .badCheckDigit(expected: 0, got: 1))
    }

    /// UPC-A is an EAN-13 with a leading zero, which is what it is.
    func testUPCABecomesAnEAN13() {
        guard case .success(let payload) = Barcode.normalise("01234567890", symbology: .upcA)
        else { return XCTFail("11 UPC digits should complete") }
        XCTAssertEqual(payload, "0012345678905")
        XCTAssertTrue(payload.hasPrefix("0"))
    }

    func testWrongLengthAndNonDigitsAreNamed() {
        guard case .failure(let short) = Barcode.normalise("12345", symbology: .ean13)
        else { return XCTFail("too short") }
        XCTAssertEqual(short, .wrongLength(.ean13, expected: 13, got: 5))

        guard case .failure(let letters) = Barcode.normalise("ABCDEFGHIJKLM", symbology: .ean13)
        else { return XCTFail("letters") }
        XCTAssertEqual(letters, .notNumeric(.ean13))

        guard case .failure(let empty) = Barcode.normalise("   ", symbology: .code128)
        else { return XCTFail("empty") }
        XCTAssertEqual(empty, .empty)
    }

    func testCode128TakesArbitraryTextUntouched() {
        guard case .success(let payload) = Barcode.normalise(" ASSET-014 ", symbology: .code128)
        else { return XCTFail("should pass") }
        XCTAssertEqual(payload, "ASSET-014", "trimmed, but otherwise as given")
    }

    // MARK: Modules

    /// EAN-13 is 95 modules: 3 guard, 42 digits, 5 centre guard, 42 digits, 3 guard. If this
    /// is not 95, the quiet-zone trim has eaten a guard bar and nothing will scan.
    func testEAN13IsNinetyFiveModules() throws {
        let modules = try XCTUnwrap(Barcode.modules("5012345678900", symbology: .ean13))
        XCTAssertEqual(modules.count, 95)
        XCTAssertEqual(Array(modules.prefix(3)), [true, false, true], "start guard is 101")
        XCTAssertEqual(Array(modules.suffix(3)), [true, false, true], "end guard is 101")
        XCTAssertEqual(Array(modules[45 ..< 50]), [false, true, false, true, false],
                       "centre guard is 01010")
    }

    func testTheQuietZoneIsTrimmed() {
        XCTAssertEqual(Barcode.trimmingQuietZone([false, false, true, false, true, false]),
                       [true, false, true])
        XCTAssertTrue(Barcode.trimmingQuietZone([false, false]).isEmpty)
        XCTAssertTrue(Barcode.trimmingQuietZone([]).isEmpty)
    }

    func testEverySymbologyProducesModules() throws {
        for (symbology, payload) in [(Barcode.Symbology.ean13, "5012345678900"),
                                     (.code128, "ASSET-014"),
                                     (.code39, "SHELF12"),
                                     (.itf, "1234567890")] {
            let modules = Barcode.modules(payload, symbology: symbology)
            XCTAssertNotNil(modules, symbology.displayName)
            XCTAssertGreaterThan(modules?.count ?? 0, 20, symbology.displayName)
        }
    }

    // MARK: Drawing

    func testDrawingReportsItsRefusals() {
        let pdf = Document(size: .a4)
        XCTAssertEqual(pdf.barcode("", symbology: .code128, x: 0, y: 0, width: 100, height: 40),
                       .empty)
        XCTAssertEqual(pdf.barcode("5012345678901", symbology: .ean13, x: 0, y: 0,
                                   width: 100, height: 40), .badCheckDigit(expected: 0, got: 1))
        XCTAssertEqual(pdf.barcode("X", symbology: .code128, x: 0, y: 0, width: 2, height: 2),
                       .tooSmall)
    }

    func testASuccessfulDrawReturnsNothingAndEmitsPath() throws {
        let pdf = Document(size: .a4)
        XCTAssertNil(pdf.barcode("5012345678900", symbology: .ean13,
                                 x: 40, y: 700, width: 200, height: 50))
        XCTAssertGreaterThan(try pdf.render().count, 800)
    }

    /// The digits are not decoration: on an EAN-13 the first sits outside the bars, then six
    /// under each half. That is what the standard specifies and what people read.
    func testTheCaptionIsDrawnAndSplitForEAN13() throws {
        let pdf = Document(size: .a4)
        _ = pdf.barcode("5012345678900", symbology: .ean13, x: 60, y: 700,
                        width: 200, height: 50, caption: true)
        XCTAssertTrue(pdf.drawnText.contains("5"), "the lead digit sits outside the bars")
        XCTAssertTrue(pdf.drawnText.contains("012345"), "six under the left half")
        XCTAssertTrue(pdf.drawnText.contains("678900"), "six under the right half")
    }

    func testTheCaptionCanBeTurnedOff() throws {
        let pdf = Document(size: .a4)
        _ = pdf.barcode("5012345678900", symbology: .ean13, x: 60, y: 700,
                        width: 200, height: 50, caption: false)
        XCTAssertTrue(pdf.drawnText.isEmpty)
    }

    func testCaptionHeightIsReportedSoCallersCanReserveRoom() {
        XCTAssertGreaterThan(Barcode.captionHeight(for: 200), 0)
        XCTAssertGreaterThanOrEqual(Barcode.captionHeight(for: 40), 8, "there is a floor")
        XCTAssertLessThanOrEqual(Barcode.captionHeight(for: 400), 12, "and a ceiling")
    }

    // MARK: It has to scan

    /// Render the page, composite it onto WHITE, and read it back with Vision.
    ///
    /// The white matters and cost an hour to notice: a PDF page has no background, so its
    /// raster is transparent with black marks on it. Anything that ignores alpha reads
    /// transparent as black, turns the barcode into a solid block, and reports that nothing
    /// scanned — which looks exactly like a broken renderer.
    private func scan(_ pdf: Document, scale: CGFloat = 4) throws -> [String: String] {
        let data = try pdf.render()
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)

        let width = Int(box.width * scale), height = Int(box.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)

        let image = try XCTUnwrap(context.makeImage())
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])

        var found: [String: String] = [:]
        for result in request.results ?? [] {
            guard let payload = result.payloadStringValue else { continue }
            found[result.symbology.rawValue
                .replacingOccurrences(of: "VNBarcodeSymbology", with: "")] = payload
        }
        return found
    }

    func testAnEAN13ScansBackAsItself() throws {
        let pdf = Document(size: .a4)
        _ = pdf.barcode("5012345678900", symbology: .ean13, x: 80, y: 600,
                        width: 220, height: 70)
        XCTAssertEqual(try scan(pdf)["EAN13"], "5012345678900")
    }

    /// The check digit the library computed has to be the one the scanner reads.
    func testAComputedCheckDigitSurvivesToTheScanner() throws {
        let pdf = Document(size: .a4)
        _ = pdf.barcode("501234567890", symbology: .ean13, x: 80, y: 600,
                        width: 220, height: 70)
        XCTAssertEqual(try scan(pdf)["EAN13"], "5012345678900")
    }

    func testUPCAScansWithItsLeadingZero() throws {
        let pdf = Document(size: .a4)
        _ = pdf.barcode("01234567890", symbology: .upcA, x: 80, y: 600,
                        width: 220, height: 70)
        XCTAssertEqual(try scan(pdf)["EAN13"], "0012345678905")
    }

    func testCode128AndCode39AndITFAllScan() throws {
        for (symbology, payload, expected) in [
            (Barcode.Symbology.code128, "ASSET-014", "Code128"),
            (.code39, "SHELF12", "Code39"),
            (.itf, "1234567890", "I2of5"),
        ] {
            let pdf = Document(size: .a4)
            _ = pdf.barcode(payload, symbology: symbology, x: 80, y: 600,
                            width: 240, height: 70)
            XCTAssertEqual(try scan(pdf)[expected], payload, symbology.displayName)
        }
    }

    /// Several on one page, which is what a sheet of labels is.
    func testSeveralOnOnePageAllScan() throws {
        let pdf = Document(size: .a4)
        var y = 700.0
        for payload in ["5012345678900", "5449000000996", "4006381333931"] {
            _ = pdf.barcode(payload, symbology: .ean13, x: 80, y: y, width: 200, height: 60)
            y -= 150
        }
        let found = try scan(pdf)
        XCTAssertNotNil(found["EAN13"], "at least one should read")
    }

    /// The whole argument for vector bars: a code stays readable at the size a label is.
    func testASmallBarcodeStillScans() throws {
        let pdf = Document(size: .a4)
        // 90 points across — about 32 mm, which fits a 63.5 mm address label.
        _ = pdf.barcode("5012345678900", symbology: .ean13, x: 80, y: 600,
                        width: 90, height: 30)
        XCTAssertEqual(try scan(pdf, scale: 8)["EAN13"], "5012345678900")
    }
}
