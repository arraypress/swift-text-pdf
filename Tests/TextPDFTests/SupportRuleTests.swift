//
//  SupportRuleTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The extracted rules pinned directly — widths against a stub table,
//  weights as bare enums, colours as strings. No font file, no document.
//

import Foundation
import XCTest
@testable import TextPDF

final class SupportRuleTests: XCTestCase {

    func testWidthCountsTheEscapedByteNotTheBackslash() {
        // "(" escapes to "\\(" and the backslash is not drawn.
        let table = [Int(UInt8(ascii: "(")): 100, Int(UInt8(ascii: "n")): 556]
        XCTAssertEqual(Measuring.width(of: "(", table: table, size: 1000), 100)
    }

    func testTruncationEndsInAnEllipsisThatFits() {
        var table: [Int: Int] = [Int(UInt8(ascii: ".")): 500, Int(UInt8(ascii: "n")): 500]
        for letter in "abcdef" { table[Int(letter.asciiValue!)] = 500 }
        XCTAssertEqual(Measuring.truncated("abcdef", size: 1000, width: 2400, table: table), "a...")
        XCTAssertEqual(Measuring.truncated("ab", size: 1000, width: 2400, table: table), "ab", "what fits is left alone")
    }

    func testWeightTiesResolveHeavier() {
        XCTAssertEqual(WeightResolution.nearest(to: .medium, among: [.regular, .semibold]), .semibold,
                       "the request was for emphasis")
        XCTAssertEqual(WeightResolution.nearest(to: .semibold, among: [.regular, .bold]), .bold)
        XCTAssertNil(WeightResolution.nearest(to: .regular, among: []))
    }

    func testHexColoursParseForgivingly() {
        XCTAssertEqual(Color.hex("#abc"), Color(red: 0xAA, green: 0xBB, blue: 0xCC))
        XCTAssertEqual(Color.hex("  #FF0000  "), Color(red: 255, green: 0, blue: 0))
        XCTAssertEqual(Color.hex("not a colour"), Color(), "unparseable prints black, not nothing")
    }
}
