//
//  ShapeAndImageTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Curves and pictures.
//

import PDFKit
import XCTest
@testable import TextPDF

final class ShapeAndImageTests: XCTestCase {

    private let jpeg = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-davidsherlock-Developer-Swift-Libraries/ff8e37d5-9238-42d7-88ba-bc4b95ec3dba/scratchpad/portrait.jpg")

    private func stream(of pdf: Data) -> String {
        String(data: pdf, encoding: .isoLatin1) ?? ""
    }

    /// How much ink a page carries, for checking a shape was drawn at all.
    private func ink(_ pdf: Data, threshold: UInt8 = 200) throws -> Int {
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        let page = try XCTUnwrap(document.page(at: 0))
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)

        let image = page.thumbnail(of: box.size, for: .mediaBox)
        let raster = try XCTUnwrap(image.cgImage(forProposedRect: &box, context: nil, hints: nil))

        var pixels = [UInt8](repeating: 0, count: raster.width * raster.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: raster.width, height: raster.height,
            bitsPerComponent: 8, bytesPerRow: raster.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        return pixels.count { $0 < threshold }
    }

    // MARK: Shapes

    func testACircleIsDrawnAndFilled() throws {
        let pdf = Document(size: .a5)
        pdf.circle(x: 200, y: 400, radius: 60, color: .grey(40))

        let rendered = pdf.render()
        XCTAssertTrue(stream(of: rendered).contains(" c\n"), "no curve operators")
        XCTAssertGreaterThan(try ink(rendered), 500, "nothing was drawn")
    }

    func testARingIsHollow() throws {
        let filled = Document(size: .a5)
        filled.circle(x: 200, y: 400, radius: 60, color: .grey(40))

        let hollow = Document(size: .a5)
        hollow.ring(x: 200, y: 400, radius: 60, thickness: 6, color: .grey(40))

        // A ring of the same radius must lay down far less ink than a disc.
        XCTAssertLessThan(try ink(hollow.render()), try ink(filled.render()) / 2)
        XCTAssertGreaterThan(try ink(hollow.render()), 100, "the ring is not there at all")
    }

    func testAnArcIsShorterThanItsRing() throws {
        let whole = Document(size: .a5)
        whole.ring(x: 200, y: 400, radius: 60, thickness: 6, color: .grey(40))

        let quarter = Document(size: .a5)
        quarter.arc(x: 200, y: 400, radius: 60, from: 0, to: 90, thickness: 6, color: .grey(40))

        let full = try ink(whole.render())
        let part = try ink(quarter.render())
        XCTAssertGreaterThan(part, 50, "the arc is missing")
        XCTAssertLessThan(part, full * 2 / 3, "a quarter arc should be well under a full ring")
    }

    func testAnEmptyArcDrawsNothing() {
        let pdf = Document(size: .a5)
        pdf.arc(x: 100, y: 100, radius: 30, from: 45, to: 45)
        XCTAssertFalse(stream(of: pdf.render()).contains(" S\n"), "a zero sweep should draw nothing")
    }

    func testARoundedRectangleStaysARectangle() throws {
        let pdf = Document(size: .a5)
        pdf.roundedRect(x: 60, y: 300, width: 200, height: 60, radius: 12, color: .grey(40))
        XCTAssertGreaterThan(try ink(pdf.render()), 800)
    }

    func testAnOversizedRadiusBecomesAPillRatherThanAKnot() throws {
        // Asking for a radius larger than the shape would turn the corners
        // inside out if it were not clamped.
        let pdf = Document(size: .a5)
        pdf.roundedRect(x: 60, y: 300, width: 200, height: 40, radius: 400, color: .grey(40))

        let drawn = try ink(pdf.render())
        XCTAssertGreaterThan(drawn, 400)
        // A pill is smaller than the rectangle that contains it.
        let square = Document(size: .a5)
        square.rect(x: 60, y: 300, width: 200, height: 40, color: .grey(40))
        XCTAssertLessThan(drawn, try ink(square.render()))
    }

    func testAMeterDrawsItsTrackEvenWhenEmpty() throws {
        let empty = Document(size: .a5)
        empty.meter(x: 60, y: 300, width: 200, height: 8, fraction: 0, color: .grey(40))
        XCTAssertGreaterThan(try ink(empty.render(), threshold: 250), 100, "the track is missing")

        let half = Document(size: .a5)
        half.meter(x: 60, y: 300, width: 200, height: 8, fraction: 0.5, color: .grey(20))

        let full = Document(size: .a5)
        full.meter(x: 60, y: 300, width: 200, height: 8, fraction: 1, color: .grey(20))

        XCTAssertLessThan(try ink(half.render()), try ink(full.render()))
    }

    func testAFractionOutsideZeroToOneIsClamped() throws {
        let over = Document(size: .a5)
        over.meter(x: 60, y: 300, width: 200, height: 8, fraction: 4, color: .grey(20))

        let full = Document(size: .a5)
        full.meter(x: 60, y: 300, width: 200, height: 8, fraction: 1, color: .grey(20))

        XCTAssertEqual(try ink(over.render()), try ink(full.render()), accuracy: 30)
    }

    // MARK: Images

    private func loadImage() throws -> EmbeddedImage {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: jpeg.path), "no test JPEG")
        return try EmbeddedImage.load(jpeg)
    }

    func testJPEGDimensionsAreRead() throws {
        let picture = try loadImage()
        XCTAssertEqual(picture.width, 400)
        XCTAssertEqual(picture.height, 211)
        XCTAssertEqual(picture.components, 3)
        XCTAssertEqual(picture.aspectRatio, 400.0 / 211.0, accuracy: 0.001)
    }

    func testAnImageIsEmbeddedAndReadBack() throws {
        let picture = try loadImage()
        let pdf = Document(size: .a5)
        pdf.image(picture, x: 60, y: 300, width: 200, height: 105)

        let data = pdf.render()
        let rendered = stream(of: data)
        XCTAssertTrue(rendered.contains("/DCTDecode"))
        XCTAssertTrue(rendered.contains("/XObject"))
        XCTAssertTrue(rendered.contains("/Im1 Do"))

        // And a reader can actually rasterise it.
        XCTAssertGreaterThan(try ink(data), 1000, "the image did not draw")
    }

    func testTheImageBytesArePassedThroughUntouched() throws {
        let picture = try loadImage()
        let original = try Data(contentsOf: jpeg)

        let pdf = Document(size: .a5)
        pdf.image(picture, x: 0, y: 0, width: 100, height: 50)

        // The whole compressed file should appear verbatim — that is the point
        // of DCTDecode, and any re-encoding would be a bug.
        XCTAssertTrue(pdf.render().range(of: original) != nil, "the JPEG was not passed through")
    }

    func testTheSameImageIsEmbeddedOnlyOnce() throws {
        let picture = try loadImage()
        let pdf = Document(size: .a5)
        pdf.image(picture, x: 20, y: 400, width: 100, height: 53)
        pdf.image(picture, x: 20, y: 200, width: 100, height: 53)

        let rendered = stream(of: pdf.render())
        XCTAssertEqual(rendered.components(separatedBy: "/DCTDecode").count - 1, 1)
        XCTAssertEqual(rendered.components(separatedBy: "/Im1 Do").count - 1, 2)
    }

    func testACircularImageIsClipped() throws {
        let picture = try loadImage()

        let square = Document(size: .a5)
        square.image(picture, x: 60, y: 300, width: 120, height: 120)

        let round = Document(size: .a5)
        round.circularImage(picture, x: 60, y: 300, diameter: 120)

        XCTAssertTrue(stream(of: round.render()).contains("W n"), "no clipping path")
        // A disc covers about π/4 of its bounding square.
        XCTAssertLessThan(try ink(round.render()), try ink(square.render()))
    }

    func testImagesAndFontsCoexist() throws {
        // Both claim page resources; a dictionary that names only one of them
        // loses the other silently.
        let picture = try loadImage()
        let arial = "/System/Library/Fonts/Supplemental/Arial.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arial), "Arial is not installed")

        let pdf = Document(size: .a5)
        var family = FontFamily(name: "Arial")
        family.add(try EmbeddedFont.load(URL(fileURLWithPath: arial)), weight: .regular)
        pdf.family = family

        pdf.image(picture, x: 40, y: 400, width: 100, height: 53)
        pdf.move(to: 350)
        pdf.text("Alex Moreau")

        let data = pdf.render()
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Alex Moreau"))
        XCTAssertTrue(stream(of: data).contains("/DCTDecode"))
        XCTAssertTrue(stream(of: data).contains("/FontFile2"))
    }

    // MARK: Refusals

    func testANonJPEGIsRefused() {
        XCTAssertThrowsError(try EmbeddedImage.decode(Data([0x89, 0x50, 0x4E, 0x47]), named: "x.png")) { error in
            XCTAssertEqual(error as? ImageError, .notJPEG("x.png"))
        }
    }

    func testAMissingFileIsRefused() {
        XCTAssertThrowsError(try EmbeddedImage.load(URL(fileURLWithPath: "/no/such/photo.jpg"))) { error in
            XCTAssertEqual(error as? ImageError, .unreadable("photo.jpg"))
        }
    }

    func testAProgressiveJPEGIsRefused() throws {
        // Built by hand: SOI, then a progressive frame header.
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += [0xFF, 0xC2, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0x64, 0x03]
        bytes += [UInt8](repeating: 0, count: 8)

        XCTAssertThrowsError(try EmbeddedImage.decode(Data(bytes), named: "p.jpg")) { error in
            XCTAssertEqual(error as? ImageError, .progressive("p.jpg"))
        }
    }

    func testACMYKJPEGIsRefused() throws {
        var bytes: [UInt8] = [0xFF, 0xD8]
        // Baseline SOF0 declaring four components.
        bytes += [0xFF, 0xC0, 0x00, 0x14, 0x08, 0x00, 0x64, 0x00, 0x64, 0x04]
        bytes += [UInt8](repeating: 0, count: 12)

        XCTAssertThrowsError(try EmbeddedImage.decode(Data(bytes), named: "c.jpg")) { error in
            XCTAssertEqual(error as? ImageError, .unsupportedColour("c.jpg", 4))
        }
    }
}
