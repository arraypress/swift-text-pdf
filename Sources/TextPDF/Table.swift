//
//  Table.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A table of text, laid out on measured column widths.
public final class Table {

    private let headers: [String]
    private var tableRows: [[String]] = []
    private var fractions: [Double] = []
    private var alignments: [Int: Align] = [:]
    private var striped = false
    private var height: Double = 18
    private var totalRow: [String]?
    private var overflow: Overflow = .wrap
    private var repeatedColumns = 1
    private var ruled = false

    /// What a table does when its content is wider than the page.
    public enum Overflow: Sendable {

        /// Shorten cells with an ellipsis, at the widths given.
        ///
        /// The cheapest answer, and the one most exporters give. It is also
        /// invisible: a truncated column looks exactly like a column of short
        /// values, so nothing in the document says anything was lost. Only
        /// ever on request, and every cell it cuts is recorded in
        /// ``Document/shortened`` and reported by ``Document/textWarnings``.
        case truncate

        /// Wrap cells onto more lines at the widths given, growing the row.
        ///
        /// The default. Columns are the widths set — equal shares when none
        /// are — so a table whose cells fit is drawn exactly as a truncating
        /// one would be, and one whose cells do not grows rather than loses
        /// the end of them.
        case wrap

        /// Never lose a character.
        ///
        /// Columns are measured against their content and narrowed towards it,
        /// the type steps down half a point at a time, and only when both are
        /// exhausted does the table split into sequential tables — each
        /// repeating the columns that identify a row, so no value is ever
        /// orphaned from the thing it describes.
        case fit
    }

    /// Starts a table. Headers repeat when the body spills onto a new page.
    public init(headers: [String] = []) {
        self.headers = headers
    }

    /// Relative column widths. Normalised, so `[2, 1, 1]` works as readily
    /// as `[0.5, 0.25, 0.25]`.
    @discardableResult
    public func widths(_ values: [Double]) -> Table { fractions = values; return self }

    @discardableResult
    public func align(_ values: [Int: Align]) -> Table { alignments = values; return self }

    @discardableResult
    public func row(_ cells: [String]) -> Table { tableRows.append(cells); return self }

    @discardableResult
    public func rows(_ values: [[String]]) -> Table { tableRows += values; return self }

    /// A summing row, set apart from the body.
    ///
    /// Part of the table rather than a block beneath it, because the figures
    /// have to line up with the columns they total — a separate block drifts
    /// out of alignment the first time a column width changes.
    @discardableResult
    public func total(_ cells: [String]) -> Table { totalRow = cells; return self }

    @discardableResult
    public func striped(_ enabled: Bool = true) -> Table { striped = enabled; return self }

    /// A hairline under every body row.
    ///
    /// The alternative to striping for a table read across rather than down —
    /// and the one that survives being photocopied, where a pale band does
    /// not.
    @discardableResult
    public func ruled(_ enabled: Bool = true) -> Table { ruled = enabled; return self }

    /// What to do when the content is wider than the page.
    @discardableResult
    public func overflow(_ mode: Overflow) -> Table { overflow = mode; return self }

    /// How many leading columns identify a row.
    ///
    /// Repeated at the front of every table when ``Overflow/fit`` has to
    /// split. Two is usually right — a name and a date — and zero turns the
    /// repetition off.
    @discardableResult
    public func identifying(_ count: Int) -> Table { repeatedColumns = max(0, count); return self }

    @discardableResult
    public func rowHeight(_ points: Double) -> Table { height = points; return self }

    /// How many body rows have been added.
    public var count: Int { tableRows.count }

    /// Draws the table at the document's cursor.
    @discardableResult
    public func draw(_ pdf: Document, size: Double? = nil, headerFill: Color? = nil) -> Document {
        let pointSize = size ?? pdf.fontSize

        if overflow != .truncate {
            return drawMeasured(pdf, size: pointSize, headerFill: headerFill)
        }

        let columnWidths = resolveWidths(available: pdf.contentWidth())

        drawHeader(pdf, widths: columnWidths, size: pointSize, fill: headerFill)

        for (index, cells) in tableRows.enumerated() {
            // Repeat the header whenever the table spills onto a new page, or
            // everything past page one is a column of unlabelled numbers.
            if pdf.remaining() < height * 2 {
                pdf.pageBreak()
                drawHeader(pdf, widths: columnWidths, size: pointSize, fill: headerFill)
            }

            if striped, index % 2 == 1 {
                pdf.rect(
                    x: pdf.left(), y: pdf.cursor() - height,
                    width: pdf.contentWidth(), height: height,
                    color: .grey(248)
                )
            }
            drawRow(pdf, cells: cells, widths: columnWidths, size: pointSize, font: .helvetica, color: nil)
            if ruled {
                pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                         color: .grey(210), thickness: 0.25)
            }
        }

        if let totalRow {
            // Kept with the last body row: a totals line alone at the top of a
            // page reads as the first row of a table that never arrives.
            if pdf.remaining() < height * 2 {
                pdf.pageBreak()
                drawHeader(pdf, widths: columnWidths, size: pointSize, fill: headerFill)
            }
            let top = pdf.cursor()
            pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: .grey(60), thickness: 0.75)
            drawRow(pdf, cells: totalRow, widths: columnWidths, size: pointSize,
                    font: .helveticaBold, color: .grey(20))
            pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                     color: .grey(60), thickness: 0.75)
        }
        return pdf
    }

    // MARK: Measured layout

    /// Space between one column and the next.
    private static let gutter = 6.0

    /// Space either side of a column boundary at widths the caller set —
    /// what a truncating table has always kept, so switching to wrapping
    /// moves nothing that already fitted.
    private static let cellPadding = 6.0

    /// Every column any row asks for. A row longer than the header used to
    /// lose its extra cells to a zero width.
    private var columnCount: Int {
        max(headers.count, tableRows.map(\.count).max() ?? 0, totalRow?.count ?? 0)
    }

    /// Draws a table that measures itself against its content.
    private func drawMeasured(_ pdf: Document, size: Double, headerFill: Color?) -> Document {
        let available = pdf.contentWidth()
        let columnCount = self.columnCount
        guard columnCount > 0 else { return pdf }

        // Explicit fractions are an instruction, not a suggestion: a caller
        // who set them gets them, and wrapping does the rest. Without them
        // the columns take equal shares, as a truncating table's did — so a
        // table that fits looks the same either way.
        if overflow == .wrap {
            let widths = resolveWidths(available: available)
            drawGroup(pdf, columns: Array(0..<columnCount), widths: widths,
                      size: size, headerFill: headerFill, drawTotal: true,
                      padding: Self.cellPadding)
            return pdf
        }

        let plan = TableLayout.plan(
            natural: naturalWidths(pdf, size: size, columns: columnCount),
            minimum: minimumWidths(pdf, size: size, columns: columnCount),
            available: available,
            size: size,
            repeated: repeatedColumns,
            measure: { candidate in
                (naturalWidths(pdf, size: candidate, columns: columnCount),
                 minimumWidths(pdf, size: candidate, columns: columnCount))
            }
        )

        for (index, group) in plan.groups.enumerated() {
            if index > 0 {
                // A continuation starts on its own page. Threading the second
                // half of a row set under the first reads as one table with a
                // sudden change of columns.
                pdf.pageBreak()
            }
            let widths = TableLayout.grow(group.map { plan.widths[$0] }, to: available)
            drawGroup(
                pdf, columns: group, widths: widths, size: plan.size,
                headerFill: headerFill, drawTotal: index == plan.groups.count - 1,
                padding: Self.gutter / 2
            )
        }
        return pdf
    }

    /// Draws one table over a subset of the columns.
    private func drawGroup(
        _ pdf: Document, columns: [Int], widths: [Double],
        size: Double, headerFill: Color?, drawTotal: Bool, padding: Double
    ) {
        let rowing = Rowing(
            pdf: pdf, columns: columns, widths: widths, size: size, padding: padding,
            lineHeight: max(height, size * 1.35),
            // Wrapped lines sit at the type's own spacing, not the row's: a row
            // height of 18 is a band for one line, and three lines 18 apart
            // read as three rows.
            step: min(max(height, size * 1.35), size * 1.3),
            alignments: alignments
        )

        let headerCells = columns.map { $0 < headers.count ? headers[$0] : "" }
        let headerHeight = headers.isEmpty
            ? 0 : rowing.height(of: rowing.wrap(headerCells, font: .helveticaBold))

        func header() {
            guard !headers.isEmpty else { return }
            if let headerFill {
                pdf.rect(x: pdf.left(), y: pdf.cursor() - headerHeight, width: pdf.contentWidth(),
                         height: headerHeight, color: headerFill)
            }
            let top = pdf.cursor()
            rowing.draw(rowing.wrap(headerCells, font: .helveticaBold), lines: 0 ..< Int.max,
                        font: .helveticaBold, color: .grey(30))
            pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: .grey(60), thickness: 0.75)
            pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                     color: .grey(60), thickness: 0.75)
        }

        /// One row, kept whole on a page — unless it is taller than a page,
        /// when it flows on under the repeated header rather than running off
        /// the foot of the first one.
        func row(_ cells: [String], font: Font, color: Color?, fill: Color?) {
            let wrapped = rowing.wrap(cells, font: font)
            let depth = rowing.depth(of: wrapped)
            let whole = rowing.height(of: wrapped)
            let roomOnAFreshPage = pdf.height() - pdf.margin * 2 - headerHeight

            // A row is kept whole: breaking one across a page leaves an
            // orphaned line under a heading it does not belong to.
            if pdf.remaining() < whole + rowing.lineHeight,
               whole + rowing.lineHeight <= roomOnAFreshPage
                || pdf.remaining() < rowing.lineHeight * 2 {
                pdf.pageBreak()
                header()
            }

            var first = 0
            while first < depth {
                let room = Int(((pdf.remaining() - rowing.lineHeight) / rowing.step).rounded(.down)) + 1
                let count = min(depth - first, max(1, room))
                let segment = rowing.lineHeight + Double(count - 1) * rowing.step
                if let fill {
                    pdf.rect(x: pdf.left(), y: pdf.cursor() - segment, width: pdf.contentWidth(),
                             height: segment, color: fill)
                }
                rowing.draw(wrapped, lines: first ..< first + count, font: font, color: color)
                first += count
                if first < depth {
                    pdf.pageBreak()
                    header()
                }
            }
        }

        header()

        for (index, cells) in tableRows.enumerated() {
            let cells = columns.map { $0 < cells.count ? cells[$0] : "" }
            row(cells, font: .helvetica, color: nil,
                fill: striped && index % 2 == 1 ? .grey(248) : nil)
            if ruled {
                pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                         color: .grey(210), thickness: 0.25)
            }
        }

        guard drawTotal, let totalRow else { return }
        let cells = columns.map { $0 < totalRow.count ? totalRow[$0] : "" }
        let whole = rowing.height(of: rowing.wrap(cells, font: .helveticaBold))
        if pdf.remaining() < whole + rowing.lineHeight {
            pdf.pageBreak()
            header()
        }
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                 color: .grey(60), thickness: 0.75)
        row(cells, font: .helveticaBold, color: .grey(20), fill: nil)
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                 color: .grey(60), thickness: 0.75)
    }

    /// The width a cell's text gets inside its column.
    ///
    /// Padding sits between columns, not outside them, so the first column
    /// meets the left margin and the last the right. Never less than a
    /// point: a column squeezed to nothing still has to draw its text, one
    /// character a line if it comes to that, rather than skip the cell.
    static func inner(_ width: Double, index: Int, count: Int, padding: Double) -> Double {
        let leading = index == 0 ? 0 : padding
        let trailing = index == count - 1 ? 0 : padding
        return max(width - leading - trailing, 1)
    }

    /// Wrapping and setting the rows of one table.
    private struct Rowing {
        let pdf: Document
        let columns: [Int]
        let widths: [Double]
        let size: Double
        let padding: Double

        /// The band one line of a row sits in.
        let lineHeight: Double

        /// From one wrapped line to the next.
        let step: Double

        let alignments: [Int: Align]

        /// Each cell broken into the lines it needs.
        func wrap(_ cells: [String], font: Font) -> [[String]] {
            cells.enumerated().map { index, cell in
                guard index < widths.count else { return [] }
                let inner = Table.inner(widths[index], index: index, count: cells.count,
                                        padding: padding)
                return pdf.lines(of: cell, width: inner, size: size, font: font)
            }
        }

        func depth(of wrapped: [[String]]) -> Int { max(1, wrapped.map(\.count).max() ?? 1) }

        /// How tall a row has to be for its tallest cell.
        func height(of wrapped: [[String]]) -> Double {
            lineHeight + Double(depth(of: wrapped) - 1) * step
        }

        /// Sets `lines` of a wrapped row at the cursor, and moves past them.
        func draw(_ wrapped: [[String]], lines: Range<Int>, font: Font, color: Color?) {
            let top = pdf.cursor()
            let first = lines.lowerBound
            let last = min(lines.upperBound, depth(of: wrapped))
            let band = font.bandBaseline(bandHeight: lineHeight, size: size)
            var x = pdf.left()

            for (index, cellLines) in wrapped.enumerated() where index < widths.count {
                let leading = index == 0 ? 0 : padding
                let inner = Table.inner(widths[index], index: index, count: wrapped.count,
                                        padding: padding)
                for line in first ..< max(first, min(last, cellLines.count)) {
                    pdf.textAt(
                        cellLines[line],
                        x: x + leading,
                        y: top - band - Double(line - first) * step,
                        size: size,
                        font: font,
                        color: color,
                        align: alignments[columns[index]] ?? .left,
                        boxWidth: inner
                    )
                }
                x += widths[index]
            }
            pdf.gap(lineHeight + Double(max(last - first, 1) - 1) * step)
        }
    }

    /// What each column would like to be: its widest cell, plus the gutter.
    private func naturalWidths(_ pdf: Document, size: Double, columns: Int) -> [Double] {
        (0..<columns).map { index in
            var widest = index < headers.count
                ? pdf.width(of: headers[index], size: size, font: .helveticaBold)
                : 0
            for row in tableRows where index < row.count {
                widest = max(widest, pdf.width(of: row[index], size: size))
            }
            return widest + Self.gutter
        }
    }

    /// What each column will not go below: its longest single word.
    ///
    /// Wrapping can break a line between words but not inside one without
    /// hyphenating, so a column narrower than its longest word either
    /// overflows its neighbour or has the word chopped. The longest word is
    /// therefore the floor, tempered by a minimum that keeps a heading legible.
    private func minimumWidths(_ pdf: Document, size: Double, columns: Int) -> [Double] {
        let floor = TableLayout.floorWidth(size: size)
        return (0..<columns).map { index in
            var widest = 0.0
            if index < headers.count {
                widest = longestWord(headers[index], pdf: pdf, size: size, font: .helveticaBold)
            }
            for row in tableRows where index < row.count {
                widest = max(widest, longestWord(row[index], pdf: pdf, size: size, font: .helvetica))
            }
            return max(min(widest, pdf.contentWidth()), floor) + Self.gutter
        }
    }

    /// The width of the longest unbreakable run in a cell.
    private func longestWord(_ text: String, pdf: Document, size: Double, font: Font) -> Double {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .reduce(0.0) { max($0, pdf.width(of: String($1), size: size, font: font)) }
    }

    // MARK: Internals

    private func drawHeader(_ pdf: Document, widths: [Double], size: Double, fill: Color?) {
        guard !headers.isEmpty else { return }

        if let fill {
            pdf.rect(
                x: pdf.left(), y: pdf.cursor() - height,
                width: pdf.contentWidth(), height: height, color: fill
            )
        }

        let top = pdf.cursor()
        drawRow(pdf, cells: headers, widths: widths, size: size, font: .helveticaBold, color: .grey(30))

        // Rules above and below read as a header without needing a filled
        // band, and survive being printed in mono.
        pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: .grey(60), thickness: 0.75)
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(), color: .grey(60), thickness: 0.75)
    }

    private func drawRow(
        _ pdf: Document, cells: [String], widths: [Double],
        size: Double, font: Font, color: Color?
    ) {
        var x = pdf.left()
        let y = pdf.cursor()
        let padding = 6.0

        let last = cells.count - 1

        for (index, cell) in cells.enumerated() {
            let width = index < widths.count ? widths[index] : 0
            guard width > 0 else { continue }

            // Padding sits *between* columns, not outside them. Indenting the
            // first column pushes it off the left margin, so a section label
            // above the table no longer lines up with its first heading — and
            // the last column stops meeting the right margin that every other
            // right-aligned figure on the page uses.
            let leading = index == 0 ? 0 : padding
            let trailing = index == last ? 0 : padding
            let inner = width - leading - trailing

            pdf.textAt(
                pdf.truncate(cell, font: font, size: size, width: inner),
                x: x + leading,
                y: y - font.bandBaseline(bandHeight: height, size: size),
                size: size,
                font: font,
                color: color,
                align: alignments[index] ?? .left,
                boxWidth: inner
            )
            x += width
        }
        pdf.gap(height)
    }

    /// Turns relative fractions into point widths.
    private func resolveWidths(available: Double) -> [Double] {
        let columns = columnCount
        guard columns > 0 else { return [] }

        let total = fractions.reduce(0, +)
        guard !fractions.isEmpty, total > 0 else {
            return Array(repeating: available / Double(columns), count: columns)
        }

        // Fewer fractions than columns used to leave the extra columns at
        // width zero, and a zero-width cell is simply not drawn — a table
        // losing its last column because `widths` was one short. The missing
        // entries take the average of the given ones instead, which keeps
        // the stated proportions and keeps every column on the page.
        var padded = fractions
        if padded.count < columns {
            let average = total / Double(padded.count)
            padded += Array(repeating: average, count: columns - padded.count)
        }
        let sum = padded.reduce(0, +)
        return padded.map { ($0 / sum) * available }
    }
}
