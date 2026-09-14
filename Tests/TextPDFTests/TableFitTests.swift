//
//  TableFitTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The claim is that a table never loses a character. It is asserted by
//  rendering the PDF and reading the text back out of it, rather than by
//  inspecting the layout arithmetic and hoping it reached the page.
//

import PDFKit
import XCTest
@testable import TextPDF

final class TableFitTests: XCTestCase {

    /// Everything a rendered document says, page by page.
    private func text(of data: Data) throws -> [String] {
        let document = try XCTUnwrap(PDFDocument(data: data), "the file did not parse")
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    /// PDF text extraction inserts its own spacing, so cells are compared with
    /// whitespace squeezed out.
    private func squeezed(_ text: String) -> String {
        text.replacing(/\s+/, with: "")
    }

    // MARK: - Wrapping

    func testWrappedCellsKeepEveryWord() throws {
        let sentence = "NIKKOR Z 24-70mm f/4 S at twenty four millimetres"
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["File", "Lens"])
            .widths([1, 1])
            .overflow(.wrap)
            .rows([["larsen-001.jpg", sentence]])
            .draw(pdf)

        let pages = try text(of: pdf.render())
        let all = squeezed(pages.joined())
        for word in sentence.split(separator: " ") {
            XCTAssertTrue(all.contains(squeezed(String(word))), "lost '\(word)'")
        }
    }

    /// A wrapped row is taller than a plain one, and the row below it has to
    /// start underneath — not on top of it.
    func testWrappingGrowsTheRowRatherThanOverlapping() {
        let tall = Document(size: .a4, margin: 48)
        Table(headers: ["A", "B"])
            .widths([1, 1])
            .overflow(.wrap)
            .rows([["x", String(repeating: "word ", count: 40)], ["y", "z"]])
            .draw(tall)

        let short = Document(size: .a4, margin: 48)
        Table(headers: ["A", "B"])
            .widths([1, 1])
            .overflow(.wrap)
            .rows([["x", "short"], ["y", "z"]])
            .draw(short)

        XCTAssertLessThan(tall.cursor(), short.cursor(), "the tall row did not take more space")
    }

    // MARK: - Fitting

    /// The headline claim: fifty columns in, fifty columns out.
    ///
    /// Values are checked whole. Headings are checked word by word, because at
    /// the size fifty columns forces, "Column 12" legitimately wraps onto two
    /// lines inside its cell — which is the layout working, not data lost.
    func testFiftyColumnsAreAllPresent() throws {
        let headers = (1...50).map { "Column \($0)" }
        let row = (1...50).map { "value\($0)" }

        let pdf = Document(size: .a4, margin: 48)
        Table(headers: headers)
            .overflow(.fit)
            .identifying(1)
            .rows([row, row])
            .draw(pdf)

        let rendered = try text(of: pdf.render())
        let all = squeezed(rendered.joined())

        for value in row {
            XCTAssertTrue(all.contains(value), "lost \(value)")
        }
        // Every column number appears as its own word somewhere.
        let words = Set(rendered.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init))
        for number in 1...50 {
            XCTAssertTrue(words.contains("\(number)") || all.contains("Column\(number)"),
                          "lost heading Column \(number)")
        }
        XCTAssertFalse(all.contains("..."), "something was truncated after all")
    }

    /// Fifty columns cannot fit on one A4 page at a readable size, so the
    /// table has to have split.
    func testTooManyColumnsSplitAcrossPages() throws {
        let headers = (1...50).map { "Column \($0)" }
        let row = (1...50).map { "value\($0)" }

        let pdf = Document(size: .a4, margin: 48)
        Table(headers: headers).overflow(.fit).identifying(2).rows([row]).draw(pdf)

        let pages = try text(of: pdf.render())
        XCTAssertGreaterThan(pages.count, 1, "fifty columns fitted on one page, which cannot be right")
    }

    /// Without the identifying columns, the second table is a block of values
    /// with nothing saying which row each belongs to.
    func testIdentifyingColumnsRepeatOnEveryTable() throws {
        let headers = ["Name", "Date"] + (1...40).map { "Field \($0)" }
        let row = ["larsen-001.jpg", "2026-06-27"] + (1...40).map { "v\($0)" }

        let pdf = Document(size: .a4, margin: 48)
        Table(headers: headers).overflow(.fit).identifying(2).rows([row]).draw(pdf)

        let pages = try text(of: pdf.render())
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages where !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XCTAssertTrue(squeezed(page).contains("larsen-001.jpg"), "a table with no identifying column")
        }
    }

    /// A table that fits should not be split, scaled or otherwise interfered
    /// with.
    func testASmallTableIsLeftAlone() throws {
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["Description", "Amount"])
            .overflow(.fit)
            .rows([["Consultancy, July", "£1,240.00"], ["Expenses", "£86.40"]])
            .draw(pdf)

        let pages = try text(of: pdf.render())
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(squeezed(pages[0]).contains("Consultancy,July"))
        XCTAssertTrue(squeezed(pages[0]).contains("Expenses"))
    }

    /// Truncation stays the default, so nothing that already draws a table
    /// changes shape under it.
    func testTruncationRemainsTheDefault() throws {
        let long = String(repeating: "abcdefghij", count: 12)
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["A", "B"]).widths([1, 1]).rows([[long, "x"]]).draw(pdf)

        let all = try text(of: pdf.render()).joined()
        XCTAssertTrue(all.contains("..."), "the default stopped truncating")
    }

    // MARK: - The arithmetic

    func testNarrowingTakesFromTheColumnWithMostSlack() {
        // A date column that wants 60pt and will accept 55, beside a path
        // column that wants 400 and will accept 40. The path gives up the room.
        let widths = TableLayout.squeeze(
            natural: [60, 400], minimum: [55, 40], to: 300
        )
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.5, "the table did not end up the right width")

        let dateLost = 60 - widths[0]
        let pathLost = 400 - widths[1]
        XCTAssertGreaterThan(pathLost, dateLost * 20, "the squeeze was not proportional to slack")
        XCTAssertGreaterThanOrEqual(widths[0], 55, "the date column went below its minimum")
        XCTAssertGreaterThanOrEqual(widths[1], 40)
    }

    func testGrowingKeepsProportions() {
        let widths = TableLayout.grow([100, 200], to: 600)
        XCTAssertEqual(widths, [200, 400])
    }

    func testTheSizeLadderStepsDownToSix() {
        let ladder = TableLayout.sizeLadder(from: 9)
        XCTAssertEqual(ladder.first, 9)
        XCTAssertEqual(ladder.last, 6)
        XCTAssertEqual(ladder.count, 7)
    }

    func testSplittingRepeatsTheKeysAndCoversEveryColumn() {
        // A narrow name and date in front of eight wide columns — the shape a
        // real listing has.
        let widths = [40.0, 40] + Array(repeating: 100.0, count: 8)
        let groups = TableLayout.split(minimum: widths, available: 300, repeated: 2)

        XCTAssertGreaterThan(groups.count, 1)
        for group in groups {
            XCTAssertEqual(Array(group.prefix(2)), [0, 1], "a table with no identifying columns")
        }
        let covered = Set(groups.flatMap { $0 })
        XCTAssertEqual(covered, Set(0..<10), "a column went missing in the split")
    }

    /// If the identifying columns alone would fill the page, repeating them
    /// leaves no room for anything else — and a run of key-only groups never
    /// terminates.
    func testKeysAreNotRepeatedWhenTheyWouldFillThePage() {
        let widths = [200.0, 200, 100, 100, 100]
        let groups = TableLayout.split(minimum: widths, available: 300, repeated: 2)

        // Not repeated — and therefore not dropped either. Losing the name
        // column entirely is a worse answer than not repeating it.
        let covered = Set(groups.flatMap { $0 })
        XCTAssertEqual(covered, Set(0..<5))
        XCTAssertLessThan(groups.count, 6, "the split did not terminate sensibly")
        XCTAssertTrue(groups[0].contains(0), "the first table lost the identifying column")
    }

    func testSplitIsUnnecessaryWhenEverythingFits() {
        let groups = TableLayout.split(minimum: [50, 50, 50], available: 500, repeated: 2)
        XCTAssertEqual(groups, [[0, 1, 2]])
    }
}
