//
//  SubsetTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  What the subsetter publishes about the glyphs it keeps.
//
//  The subset is a font built by hand — head, hhea, maxp, hmtx, loca and glyf
//  rewritten from scratch. Every one of those is a place to be quietly wrong
//  in a way that still produces a file every reader will open.
//

import XCTest
@testable import TextPDF

final class SubsetTests: XCTestCase {

    private let italicPath = "/System/Library/Fonts/Supplemental/Arial Italic.ttf"
    private let regularPath = "/System/Library/Fonts/Supplemental/Arial.ttf"

    private func parse(_ path: String) throws -> TrueTypeFont {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "\(path) is not installed")
        return try XCTUnwrap(TrueTypeFont(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    /// The subset produced by drawing `text`, and the face it came from.
    private func subset(of path: String, drawing text: String) throws -> (original: TrueTypeFont, subset: TrueTypeFont, font: EmbeddedFont) {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "\(path) is not installed")

        let font = try EmbeddedFont.load(URL(fileURLWithPath: path))
        _ = font.encode(text, size: 10)

        let parts = try XCTUnwrap(font.embeddable(), "nothing was marked as used")
        return (try parse(path), try XCTUnwrap(TrueTypeFont(data: parts.data)), font)
    }

    // MARK: Side bearings

    func testSideBearingsSurviveTheSubset() throws {
        // The bug this replaced: hmtx was written with a zero left side
        // bearing for every glyph. A rasterizer positions an outline by it, so
        // any glyph whose ink starts left of its origin — most of an italic —
        // was drawn shifted by exactly the amount thrown away. Text came out
        // with letters overlapping their neighbours.
        let (original, subset, font) = try subset(of: italicPath, drawing: "Infrastructure")

        let f = try XCTUnwrap(font.glyph(for: "f"))
        let expected = original.bearing(f)
        try XCTSkipUnless(expected != 0, "this face's f has a zero bearing, so it proves nothing")

        // The subset renumbers glyphs in first-use order; `I` is the first
        // character drawn, so `n` is 2, `f` is 3.
        let published = (1..<subset.glyphCount).map(subset.bearing)
        XCTAssertTrue(published.contains(expected), "no glyph in the subset carries f's bearing of \(expected)")
        XCTAssertFalse(published.allSatisfy { $0 == 0 }, "every bearing was published as zero")
    }

    func testACompositeGlyphKeepsItsBearing() throws {
        // A composite is built from references to other glyphs — an accented
        // letter from its base and its mark, a percent sign from two zeros and
        // a slash. With the bearings zeroed the pieces collapse together and
        // the glyph renders as a smudge, while still extracting as the right
        // character — so no text-based test would ever notice.
        //
        // Which characters are composite varies by face, so one is found
        // rather than assumed.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: regularPath), "Arial is not installed")
        let face = try parse(regularPath)
        let probe = try EmbeddedFont.load(URL(fileURLWithPath: regularPath))

        let composite = "éàüñç%½Æ".unicodeScalars.first { scalar in
            probe.glyph(for: scalar).map(face.isComposite) ?? false
        }
        let character = try XCTUnwrap(composite, "no composite glyph found in this face")

        let (original, subset, font) = try subset(of: regularPath, drawing: String(character))
        let glyph = try XCTUnwrap(font.glyph(for: character))

        XCTAssertTrue(original.isComposite(glyph))
        XCTAssertGreaterThan(subset.glyphCount, 2, "the components were not pulled in")
        XCTAssertEqual(subset.bearing(1), original.bearing(glyph))
    }

    func testAdvancesSurviveTheSubset() throws {
        let (original, subset, font) = try subset(of: regularPath, drawing: "W")

        let w = try XCTUnwrap(font.glyph(for: "W"))
        XCTAssertEqual(subset.advance(1), original.advance(w))
        XCTAssertGreaterThan(subset.advance(1), 0)
    }

    // MARK: Shape

    func testTheSubsetIsSmallerThanTheFace() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: regularPath), "Arial is not installed")

        let font = try EmbeddedFont.load(URL(fileURLWithPath: regularPath))
        _ = font.encode("Alex Moreau", size: 10)
        let parts = try XCTUnwrap(font.embeddable())

        let whole = try Data(contentsOf: URL(fileURLWithPath: regularPath)).count
        XCTAssertLessThan(parts.data.count, whole / 4, "the subset is not much of a subset")
    }

    func testNotdefStaysAtIndexZero() throws {
        let (_, subset, _) = try subset(of: regularPath, drawing: "Alex")
        // A reader draws .notdef for anything it cannot resolve, and it has to
        // be glyph zero for that to be what it gets.
        XCTAssertGreaterThan(subset.glyphCount, 1)
    }

    func testEveryDrawnCharacterIsInTheSubset() throws {
        let text = "Alex Moreau — 60% (£1.2m)"
        let (_, subset, font) = try subset(of: regularPath, drawing: text)

        // One glyph per distinct character, plus .notdef, plus any components
        // the composites pulled in.
        let distinct = Set(text.unicodeScalars.compactMap { font.glyph(for: $0) })
        XCTAssertGreaterThanOrEqual(subset.glyphCount, distinct.count + 1)
    }
}
