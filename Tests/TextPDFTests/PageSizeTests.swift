//
//  PageSizeTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A page that is not a sheet of paper.
//

import PDFKit
import XCTest
@testable import TextPDF

final class PageSizeTests: XCTestCase {

    /// A business card, in points: 85 × 55 mm.
    private let cardWidth = 85 * 72 / 25.4
    private let cardHeight = 55 * 72 / 25.4

    func testAPageCanBeMadeToAnExactSize() throws {
        let document = Document(width: cardWidth, height: cardHeight, margin: 14, fontSize: 9, leading: 12)

        XCTAssertEqual(document.width(), cardWidth, accuracy: 0.01)
        XCTAssertEqual(document.height(), cardHeight, accuracy: 0.01)
        XCTAssertEqual(document.contentWidth(), cardWidth - 28, accuracy: 0.01)
        XCTAssertEqual(document.cursor(), cardHeight - 14, accuracy: 0.01,
                       "the cursor starts under the top margin, as it does on paper")
    }

    func testTheFinishedPageIsThatSize() throws {
        let document = Document(width: cardWidth, height: cardHeight, margin: 14)
        document.textAt("Alex Moreau", x: 14, y: cardHeight - 30, size: 12)

        let page = try XCTUnwrap(PDFDocument(data: document.render())?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, cardWidth, accuracy: 0.5)
        XCTAssertEqual(box.height, cardHeight, accuracy: 0.5)
    }

    func testAWidePageReportsItselfAsLandscape() {
        XCTAssertEqual(Document(width: cardWidth, height: cardHeight).orientation, .landscape)
        XCTAssertEqual(Document(width: cardHeight, height: cardWidth).orientation, .portrait)
    }

    func testANamedSizeIsUnchanged() {
        // The existing initialiser keeps its behaviour exactly.
        let a4 = Document(size: .a4)
        XCTAssertEqual(a4.width(), 595.28, accuracy: 0.01)
        XCTAssertEqual(a4.height(), 841.89, accuracy: 0.01)

        let landscape = Document(size: .a4, orientation: .landscape)
        XCTAssertEqual(landscape.width(), 841.89, accuracy: 0.01)
        XCTAssertEqual(landscape.height(), 595.28, accuracy: 0.01)
    }
}
