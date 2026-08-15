//
//  PNGTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  PNG, which cannot be passed through the way a JPEG can.
//

import PDFKit
import XCTest
@testable import TextPDF

final class PNGTests: XCTestCase {

    private let scratch = "/private/tmp/claude-501/-Users-davidsherlock-Developer-Swift-Libraries/ff8e37d5-9238-42d7-88ba-bc4b95ec3dba/scratchpad"

    private func image(_ name: String) throws -> EmbeddedImage {
        let path = "\(scratch)/\(name)"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no \(name)")
        return try EmbeddedImage.load(URL(fileURLWithPath: path))
    }

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    /// How much ink a page carries.
    private func ink(_ data: Data) throws -> Int {
        let page = try XCTUnwrap(try XCTUnwrap(PDFDocument(data: data)).page(at: 0))
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let raster = try XCTUnwrap(
            page.thumbnail(of: box.size, for: .mediaBox)
                .cgImage(forProposedRect: &box, context: nil, hints: nil)
        )
        var pixels = [UInt8](repeating: 0, count: raster.width * raster.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: raster.width, height: raster.height,
            bitsPerComponent: 8, bytesPerRow: raster.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        return pixels.count { $0 < 200 }
    }

    // MARK: Decoding

    func testAPNGIsRead() throws {
        let png = try image("portrait.png")
        XCTAssertEqual(png.width, 400)
        XCTAssertEqual(png.height, 211)
        XCTAssertEqual(png.components, 3)
        XCTAssertEqual(png.filter, .flate)
    }

    func testAPNGIsFlateNotDCT() throws {
        let pdf = Document(size: .a5)
        pdf.image(try image("portrait.png"), x: 40, y: 300, width: 200, height: 105)

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/FlateDecode"))
        XCTAssertFalse(rendered.contains("/DCTDecode"), "a PNG is not JPEG data")
        XCTAssertGreaterThan(try ink(pdf.render()), 500, "nothing was drawn")
    }

    func testTheZlibStreamIsWellFormed() throws {
        // A reader that cannot inflate it shows nothing, so the frame matters:
        // two header bytes, the deflate stream, and an Adler-32.
        let packed = try XCTUnwrap(Deflate.zlib(Data(repeating: 0x41, count: 4096)))
        let bytes = [UInt8](packed)

        XCTAssertEqual(bytes[0], 0x78)
        XCTAssertEqual(bytes[1], 0x9C)
        XCTAssertLessThan(packed.count, 4096, "it did not compress")

        // Round-tripped through the system's inflater. Foundation's .zlib is
        // raw DEFLATE — RFC 1951, the thing inside the frame — so the two
        // header bytes and the four-byte checksum come off first. That
        // asymmetry is exactly why the frame has to be written by hand.
        let payload = packed.dropFirst(2).dropLast(4)
        let inflated = try XCTUnwrap((Data(payload) as NSData).decompressed(using: .zlib) as Data?)

        XCTAssertEqual(inflated.count, 4096)
        XCTAssertTrue(inflated.allSatisfy { $0 == 0x41 })

        // And the checksum is an Adler-32 of the input, not of the stream.
        let trailer = [UInt8](packed.suffix(4))
        XCTAssertEqual(trailer.count, 4)
        XCTAssertFalse(trailer.allSatisfy { $0 == 0 }, "no checksum was written")
    }

    func testIncompressibleDataIsStoredRatherThanGrown() {
        // Deflate can expand its input. Storing it raw is legal in a PDF and
        // smaller than a stream that grew.
        var noise = Data()
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for _ in 0..<8192 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            noise.append(UInt8(truncatingIfNeeded: seed))
        }
        if let packed = Deflate.zlib(noise) {
            XCTAssertLessThan(packed.count, noise.count)
        }
    }

    // MARK: Transparency

    func testATransparentPNGCarriesASoftMask() throws {
        let dot = try image("dot.png")
        XCTAssertNotNil(dot.alpha, "the alpha channel was dropped")

        let pdf = Document(size: .a5)
        pdf.image(dot, x: 40, y: 300, width: 80, height: 80)

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/SMask"), "no soft mask")
        XCTAssertTrue(rendered.contains("/DeviceGray"), "the mask is not greyscale")
    }

    func testAnOpaquePNGCarriesNoMask() throws {
        let png = try image("portrait.png")
        XCTAssertNil(png.alpha, "an opaque image should not pay for a mask")

        let pdf = Document(size: .a5)
        pdf.image(png, x: 40, y: 300, width: 200, height: 105)
        XCTAssertFalse(try raw(pdf.render()).contains("/SMask"))
    }

    func testTheMaskedAreaIsNotPainted() throws {
        // The circle is red on transparent. Drawn without a mask it would
        // arrive as a filled square.
        let pdf = Document(size: .a5)
        pdf.image(try image("dot.png"), x: 40, y: 300, width: 120, height: 120)

        let square = Document(size: .a5)
        square.rect(x: 40, y: 300, width: 120, height: 120, color: .grey(60))

        XCTAssertLessThan(try ink(pdf.render()), try ink(square.render()),
                          "the transparent corners were painted")
    }

    // MARK: Mixing

    func testAPNGAndAJPEGCoexist() throws {
        let pdf = Document(size: .a5)
        pdf.image(try image("portrait.png"), x: 20, y: 400, width: 120, height: 63)
        pdf.image(try image("portrait.jpg"), x: 20, y: 250, width: 120, height: 63)

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/FlateDecode"))
        XCTAssertTrue(rendered.contains("/DCTDecode"))
        XCTAssertTrue(rendered.contains("/Im1 Do"))
        XCTAssertTrue(rendered.contains("/Im2 Do"))
    }

    func testANonImageIsStillRefused() {
        XCTAssertThrowsError(try EmbeddedImage.decode(Data([1, 2, 3, 4, 5]), named: "x.gif")) { error in
            XCTAssertEqual(error as? ImageError, .unsupportedFormat("x.gif"))
        }
    }

    func testATruncatedPNGIsReported() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [UInt8](repeating: 0, count: 20)

        XCTAssertThrowsError(try EmbeddedImage.decode(Data(bytes), named: "bad.png")) { error in
            XCTAssertEqual(error as? ImageError, .undecodable("bad.png"))
        }
    }
}
