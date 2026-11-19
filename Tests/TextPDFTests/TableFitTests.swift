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

    /// Wrapping is the default: a cell too long for its column grows the row
    /// rather than losing its end. Truncation used to be, and a cut value
    /// looks exactly like a short one, so nothing on the page said so.
    func testTheDefaultKeepsEveryCharacter() throws {
        let long = String(repeating: "abcdefghij", count: 12)
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["A", "B"]).widths([1, 1]).rows([[long, "x"]]).draw(pdf)

        let all = squeezed(try text(of: pdf.render()).joined())
        XCTAssertTrue(all.contains(long), "the default lost the end of a cell")
        XCTAssertFalse(all.contains("..."), "the default still truncates")
        XCTAssertTrue(pdf.textWarnings.isEmpty, "nothing was lost, so nothing to warn about")
    }

    /// The switch to wrapping must not move anything that already fitted:
    /// the same padding, baselines and page breaks as a truncating table, so
    /// every document drawn before reads the same after.
    func testATableThatFitsIsDrawnAsTruncationDrewIt() {
        func drawn(_ mode: Table.Overflow?) -> Data {
            let pdf = Document(size: .a4, margin: 48)
            let table = Table(headers: ["Date", "Description", "Amount"])
                .widths([1, 3, 1]).align([2: .right]).striped().ruled()
                .rows((1...60).map { ["2026-11-\($0 % 28 + 1)", "Line \($0)", "£\($0).00"] })
                .total(["", "Total", "£1,830.00"])
            if let mode { table.overflow(mode) }
            table.draw(pdf, headerFill: .grey(240))
            return pdf.render(creationDate: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(drawn(nil), drawn(.truncate))
    }

    /// Asked for, truncation still cuts — and says what it cut.
    func testTruncationOnRequestIsRecorded() throws {
        let long = String(repeating: "abcdefghij", count: 12)
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["A", "B"]).widths([1, 1]).overflow(.truncate).rows([[long, "x"]]).draw(pdf)

        XCTAssertTrue(try text(of: pdf.render()).joined().contains("..."))
        XCTAssertEqual(pdf.shortened.map(\.text), [long])
        XCTAssertTrue(pdf.shortened[0].shown.hasSuffix("..."))
        XCTAssertEqual(pdf.textWarnings.count, 1)
        XCTAssertTrue(pdf.textWarnings[0].contains(long))
    }

    /// A row with more cells than the header — or than the first row — used
    /// to give the extras a width of zero, and a zero-width cell was skipped.
    func testCellsBeyondTheFirstRowAreDrawn() throws {
        for mode in [Table.Overflow.wrap, .truncate, .fit] {
            let pdf = Document(size: .a4, margin: 48)
            Table(headers: ["A", "B"]).overflow(mode)
                .rows([["a1", "b1"], ["a2", "b2", "extra-cell"]])
                .draw(pdf)
            let all = squeezed(try text(of: pdf.render()).joined())
            XCTAssertTrue(all.contains("extra-cell"), "\(mode) dropped a cell past the header")
        }
    }

    /// A row taller than a page cannot be kept whole. It flows on under the
    /// repeated header instead of running off the foot of the first page —
    /// where the reader clips it and the end of the cell is simply gone.
    func testARowTallerThanAPageFlowsOntoTheNext() throws {
        let words = (1...900).map { "word\($0)" }
        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["Date", "Description"]).widths([1, 3])
            .rows([["2026-11-01", "short"], ["2026-11-02", words.joined(separator: " ")],
                   ["2026-11-03", "after"]])
            .draw(pdf)

        let pages = try text(of: pdf.render())
        XCTAssertGreaterThan(pages.count, 1)
        // The repeated header is the only thing between one page's part of
        // the cell and the next's.
        let all = squeezed(pages.joined()).replacing("DateDescription", with: "")
        XCTAssertTrue(all.contains(words.joined()), "a word of the tall cell was lost")
        XCTAssertTrue(all.contains("2026-11-03after"))
        XCTAssertEqual(pdf.outsidePage, [], "a line ran off the page")
        XCTAssertTrue(squeezed(pages[1]).hasPrefix("DateDescription"), "the header repeats")
    }

    /// Wrapped lines sit at the type's spacing, not a row apart.
    func testWrappedLinesAreSetCloserThanRows() {
        let pdf = Document(size: .a4, margin: 48)
        let top = pdf.cursor()
        Table().widths([1, 1]).rowHeight(18)
            .rows([["one two three four five six seven eight nine ten eleven twelve "
                    + "thirteen fourteen fifteen sixteen seventeen eighteen", "x"]])
            .draw(pdf, size: 8.5)
        let lines = pdf.drawnText.count - 1
        XCTAssertGreaterThan(lines, 1)
        XCTAssertEqual(top - pdf.cursor(), 18 + Double(lines - 1) * 8.5 * 1.3, accuracy: 0.01)
    }

    /// A bold header is measured in bold. Measured in the regular weight, a
    /// heading that just fits wraps one word short and overprints the rule.
    func testAHeaderIsMeasuredInItsOwnWeight() {
        let pdf = Document(size: .a4, margin: 48)
        // Each column is 1/8 of the content width; find a heading that fits
        // in regular weight but not in bold.
        let inner = pdf.contentWidth() / 8 - 12
        // r is a sixth wider in bold; W is not wider at all.
        var heading = "r"
        while pdf.width(of: heading + "r", size: 10, font: .helvetica) <= inner { heading += "r" }
        XCTAssertGreaterThan(pdf.width(of: heading, size: 10, font: .helveticaBold), inner,
                             "the probe needs a heading only bold overflows")

        let probe = Document(size: .a4, margin: 48)
        Table(headers: ["a", heading, "c", "d", "e", "f", "g", "h"]).rows([["1", "2"]]).draw(probe)
        let flat = Document(size: .a4, margin: 48)
        Table(headers: ["a", "b", "c", "d", "e", "f", "g", "h"]).rows([["1", "2"]]).draw(flat)
        XCTAssertLessThan(probe.cursor(), flat.cursor(), "the bold heading did not get a second line")
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
    // MARK: - Rules

    /// A style option that changes nothing is worse than no option: it reads
    /// as working. `.ruled()` has to put ink on the page.
    func testRuledDrawsMoreThanUnruled() throws {
        func bytes(ruled: Bool) -> Int {
            let pdf = Document(size: .a4, margin: 48)
            let table = Table(headers: ["A", "B"])
                .widths([1, 1])
                .overflow(.wrap)
                .rows((0..<20).map { [String($0), "value"] })
            if ruled { table.ruled() }
            table.draw(pdf)
            return pdf.render().count
        }

        XCTAssertGreaterThan(bytes(ruled: true), bytes(ruled: false), "ruled drew nothing extra")
    }

    /// And it has to work the same way in the fixed-height path, or the option
    /// means one thing with .wrap and another without it.
    func testRulesAlsoDrawUnderTruncatedRows() throws {
        func bytes(ruled: Bool) -> Int {
            let pdf = Document(size: .a4, margin: 48)
            let table = Table(headers: ["A", "B"])
                .widths([1, 1])
                .rows((0..<20).map { [String($0), "value"] })
            if ruled { table.ruled() }
            table.draw(pdf)
            return pdf.render().count
        }

        XCTAssertGreaterThan(bytes(ruled: true), bytes(ruled: false))
    }

    // MARK: - Decomposed text

    /// macOS stores file names DECOMPOSED. `Jönsson` on disk is `o` plus a
    /// combining diaeresis, and Windows-1252 has no combining marks — so
    /// without composing first, every accented name in a listing renders with
    /// a question mark in the middle of it. Found on real signed contracts.
    func testDecomposedAccentsSurviveEncoding() throws {
        let decomposed = "Joakim Jo\u{0308}nsson"
        let composed = "Joakim Jönsson"
        XCTAssertEqual(decomposed, composed, "Swift compares these as equal — the difference is in the scalars")
        XCTAssertGreaterThan(
            decomposed.unicodeScalars.count, composed.unicodeScalars.count,
            "the fixture must really be decomposed"
        )

        let pdf = Document(size: .a4, margin: 48)
        Table(headers: ["Name"]).overflow(.fit).rows([[decomposed]]).draw(pdf)

        let document = try XCTUnwrap(PDFDocument(data: pdf.render()))
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains("?"), "an accent became a question mark: \(text)")
        XCTAssertTrue(
            text.replacing(/\s+/, with: "").contains("Jönsson"),
            "the composed name is missing: \(text)"
        )
    }

    /// And the widths have to agree, or a composed name measures as one
    /// character wider than it draws.
    func testDecomposedTextMeasuresAsItDraws() {
        let pdf = Document(size: .a4, margin: 48)
        let decomposed = "Jo\u{0308}nsson"
        let composed = "Jönsson"
        XCTAssertEqual(
            pdf.width(of: decomposed, size: 10),
            pdf.width(of: composed, size: 10),
            accuracy: 0.01
        )
    }

}
