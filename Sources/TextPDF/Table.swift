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

    @discardableResult
    public func striped(_ enabled: Bool = true) -> Table { striped = enabled; return self }

    @discardableResult
    public func rowHeight(_ points: Double) -> Table { height = points; return self }

    public var count: Int { tableRows.count }

    /// Draws the table at the document's cursor.
    @discardableResult
    public func draw(_ pdf: Document, size: Double? = nil, headerFill: Color? = nil) -> Document {
        let pointSize = size ?? pdf.fontSize
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
        }
        return pdf
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
        return fractions.map { ($0 / total) * available }
    }
}
