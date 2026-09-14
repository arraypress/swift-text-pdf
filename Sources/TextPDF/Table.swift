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
    private var overflow: Overflow = .truncate
    private var repeatedColumns = 1
    private var ruled = false

    /// What a table does when its content is wider than the page.
    public enum Overflow: Sendable {

        /// Shorten cells with an ellipsis, at the widths given.
        ///
        /// The cheapest answer, and the one most exporters give. It is also
        /// invisible: a truncated column looks exactly like a column of short
        /// values, so nothing in the document says anything was lost.
        case truncate

        /// Wrap cells onto more lines at the widths given, growing the row.
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

    /// Draws a table that measures itself against its content.
    private func drawMeasured(_ pdf: Document, size: Double, headerFill: Color?) -> Document {
        let available = pdf.contentWidth()
        let columnCount = max(headers.count, tableRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return pdf }

        // Explicit fractions are an instruction, not a suggestion: a caller
        // who set them gets them, and wrapping does the rest.
        if overflow == .wrap, !fractions.isEmpty {
            let widths = resolveWidths(available: available)
            drawGroup(pdf, columns: Array(0..<columnCount), widths: widths,
                      size: size, headerFill: headerFill, drawTotal: true)
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
                headerFill: headerFill, drawTotal: index == plan.groups.count - 1
            )
        }
        return pdf
    }

    /// Draws one table over a subset of the columns.
    private func drawGroup(
        _ pdf: Document, columns: [Int], widths: [Double],
        size: Double, headerFill: Color?, drawTotal: Bool
    ) {
        let lineHeight = max(height, size * 1.35)

        func header() {
            guard !headers.isEmpty else { return }
            let cells = columns.map { $0 < headers.count ? headers[$0] : "" }
            let rows = heightOf(cells, widths: widths, pdf: pdf, size: size, lineHeight: lineHeight)
            if let headerFill {
                pdf.rect(x: pdf.left(), y: pdf.cursor() - rows, width: pdf.contentWidth(),
                         height: rows, color: headerFill)
            }
            let top = pdf.cursor()
            drawWrapped(pdf, cells: cells, columns: columns, widths: widths, size: size,
                        rowHeight: rows, lineHeight: lineHeight,
                        font: .helveticaBold, color: .grey(30))
            pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: .grey(60), thickness: 0.75)
            pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                     color: .grey(60), thickness: 0.75)
        }

        header()

        for (index, row) in tableRows.enumerated() {
            let cells = columns.map { $0 < row.count ? row[$0] : "" }
            let rows = heightOf(cells, widths: widths, pdf: pdf, size: size, lineHeight: lineHeight)

            // A row is kept whole: breaking one across a page leaves an
            // orphaned line under a heading it does not belong to.
            if pdf.remaining() < rows + lineHeight {
                pdf.pageBreak()
                header()
            }
            if striped, index % 2 == 1 {
                pdf.rect(x: pdf.left(), y: pdf.cursor() - rows, width: pdf.contentWidth(),
                         height: rows, color: .grey(248))
            }
            drawWrapped(pdf, cells: cells, columns: columns, widths: widths, size: size,
                        rowHeight: rows, lineHeight: lineHeight, font: .helvetica, color: nil)
            if ruled {
                pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                         color: .grey(210), thickness: 0.25)
            }
        }

        guard drawTotal, let totalRow else { return }
        let cells = columns.map { $0 < totalRow.count ? totalRow[$0] : "" }
        let rows = heightOf(cells, widths: widths, pdf: pdf, size: size, lineHeight: lineHeight)
        if pdf.remaining() < rows + lineHeight {
            pdf.pageBreak()
            header()
        }
        let top = pdf.cursor()
        pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: .grey(60), thickness: 0.75)
        drawWrapped(pdf, cells: cells, columns: columns, widths: widths, size: size,
                    rowHeight: rows, lineHeight: lineHeight,
                    font: .helveticaBold, color: .grey(20))
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                 color: .grey(60), thickness: 0.75)
    }

    /// How tall a row has to be for its tallest cell.
    private func heightOf(
        _ cells: [String], widths: [Double], pdf: Document,
        size: Double, lineHeight: Double
    ) -> Double {
        var lines = 1
        for (index, cell) in cells.enumerated() where index < widths.count {
            let inner = widths[index] - Self.gutter
            guard inner > 0 else { continue }
            lines = max(lines, pdf.lines(of: cell, width: inner, size: size).count)
        }
        return Double(lines) * lineHeight
    }

    /// Draws one row, wrapping each cell inside its column.
    private func drawWrapped(
        _ pdf: Document, cells: [String], columns: [Int], widths: [Double],
        size: Double, rowHeight: Double, lineHeight: Double, font: Font, color: Color?
    ) {
        var x = pdf.left()
        let top = pdf.cursor()

        for (index, cell) in cells.enumerated() where index < widths.count {
            let width = widths[index]
            guard width > 0 else { continue }

            let leading = index == 0 ? 0 : Self.gutter / 2
            let trailing = index == cells.count - 1 ? 0 : Self.gutter / 2
            let inner = width - leading - trailing
            guard inner > 0 else { x += width; continue }

            let lines = pdf.lines(of: cell, width: inner, size: size)
            for (line, text) in lines.enumerated() {
                pdf.textAt(
                    text,
                    x: x + leading,
                    y: top - Double(line) * lineHeight - font.bandBaseline(bandHeight: lineHeight, size: size),
                    size: size,
                    font: font,
                    color: color,
                    align: alignments[columns[index]] ?? .left,
                    boxWidth: inner
                )
            }
            x += width
        }
        pdf.gap(rowHeight)
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
        let columns = max(headers.count, tableRows.first?.count ?? 0)
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
