//
//  Document.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Builds invoices, statements and reports — text, tables, rules, boxes and
//  vector logos — with no dependencies and no embedded fonts.
//
//  What it cannot do: WinAnsi encoding covers Latin-1, so Cyrillic, Greek,
//  Hebrew, Arabic and CJK will not render. Those need an embedded font, and
//  embedding fonts is where this stops and a real PDF library starts.
//

import Foundation

/// A PDF being written, top to bottom.
public final class Document {

    // MARK: Configuration

    public let size: PageSize
    public let orientation: Orientation
    public let margin: Double
    public let fontSize: Double
    public let leading: Double

    private let pageWidth: Double
    private let pageHeight: Double

    /// Completed page content streams.
    private var pages: [String] = []

    /// The stream currently being written.
    private var current = ""

    /// Vertical position, in points from the page bottom.
    private var y: Double

    /// Drawn on every page once the total is known.
    private var footer: ((Document, Int, Int) -> Void)?

    public init(
        size: PageSize = .a4,
        orientation: Orientation = .portrait,
        margin: Double = 56,
        fontSize: Double = 10,
        leading: Double = 14
    ) {
        self.size = size
        self.orientation = orientation
        self.margin = margin
        self.fontSize = fontSize
        self.leading = leading

        let (width, height) = size.dimensions
        self.pageWidth = orientation == .landscape ? height : width
        self.pageHeight = orientation == .landscape ? width : height
        self.y = self.pageHeight - margin
    }

    // MARK: Geometry

    public func contentWidth() -> Double { pageWidth - (margin * 2) }
    public func left() -> Double { margin }
    public func right() -> Double { pageWidth - margin }
    public func height() -> Double { pageHeight }
    public func width() -> Double { pageWidth }
    public func cursor() -> Double { y }

    /// Vertical space left before the bottom margin.
    public func remaining() -> Double { y - margin }

    // MARK: Flow

    @discardableResult
    public func gap(_ points: Double) -> Document { y -= points; return self }

    @discardableResult
    public func move(to position: Double) -> Document { y = position; return self }

    @discardableResult
    public func pageBreak() -> Document {
        pages.append(current)
        current = ""
        y = pageHeight - margin
        return self
    }

    /// Breaks only when `needed` points will not fit.
    @discardableResult
    public func breakIfNeeded(_ needed: Double) -> Bool {
        guard remaining() < needed else { return false }
        pageBreak()
        return true
    }

    /// Registers a callback drawn on every page once the total is known.
    @discardableResult
    public func onEachPage(_ callback: @escaping (Document, Int, Int) -> Void) -> Document {
        footer = callback
        return self
    }

    public func pageCount() -> Int { pages.count + (current.isEmpty ? 0 : 1) }

    // MARK: Text

    /// Flowing text, wrapped to the content width and broken across pages.
    @discardableResult
    public func text(
        _ text: String,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left
    ) -> Document {
        let pointSize = size ?? fontSize

        for line in wrap(text, font: font, size: pointSize, width: contentWidth()) {
            breakIfNeeded(leading)
            // The cursor marks the TOP of the line box; PDF positions text by
            // its baseline. Drawing at the cursor puts ascenders above the
            // margin and through anything drawn above.
            textAt(
                line, x: margin, y: y - font.ascender(pointSize),
                size: pointSize, font: font, color: color,
                align: align, boxWidth: contentWidth()
            )
            y -= leading
        }
        return self
    }

    @discardableResult
    public func heading(_ text: String, size: Double? = nil, color: Color? = nil) -> Document {
        self.text(text, size: size ?? fontSize + 2, font: .helveticaBold, color: color)
    }

    /// Aligned inside a box, advancing nothing.
    @discardableResult
    public func cell(
        _ text: String,
        x: Double,
        boxWidth: Double,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left
    ) -> Document {
        let pointSize = size ?? fontSize
        return textAt(
            text, x: x, y: y - font.ascender(pointSize),
            size: pointSize, font: font, color: color, align: align, boxWidth: boxWidth
        )
    }

    /// The same, vertically centred in a band — how a totals row lines up
    /// with its background.
    @discardableResult
    public func banded(
        _ text: String,
        x: Double,
        boxWidth: Double,
        bandHeight: Double,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left
    ) -> Document {
        let pointSize = size ?? fontSize
        return textAt(
            text, x: x, y: y - font.bandBaseline(bandHeight: bandHeight, size: pointSize),
            size: pointSize, font: font, color: color, align: align, boxWidth: boxWidth
        )
    }

    /// Absolute placement, leaving the cursor alone.
    @discardableResult
    public func textAt(
        _ text: String,
        x: Double,
        y baseline: Double,
        size: Double,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left,
        boxWidth: Double = 0
    ) -> Document {
        guard !text.isEmpty else { return self }

        let escaped = PDFEncoding.escape(text)
        var originX = x

        // Alignment is computed from the measured width — the reason the font
        // metrics exist at all.
        if align != .left, boxWidth > 0 {
            let measured = font.widthOf(escaped, size: size)
            originX += align == .right ? boxWidth - measured : (boxWidth - measured) / 2
        }

        let ink = color ?? .black()
        current += "q\n"
        if !ink.isBlack { current += ink.operands + " rg\n" }

        current += String(
            format: "BT\n/%@ %.2F Tf\n%.2F %.2F Td\n(%@) Tj\nET\nQ\n",
            font.resourceName,
            PDFEncoding.number(size),
            PDFEncoding.number(originX),
            PDFEncoding.number(baseline),
            escaped
        )
        return self
    }

    /// A row of columns across the content width.
    @discardableResult
    public func columns(
        _ cells: [String],
        widths: [Double] = [],
        aligns: [Int: Align] = [:],
        font: Font = .helvetica,
        size: Double? = nil,
        color: Color? = nil
    ) -> Document {
        guard !cells.isEmpty else { return self }

        let pointSize = size ?? fontSize
        let fractions = widths.count == cells.count
            ? widths
            : Array(repeating: 1.0 / Double(cells.count), count: cells.count)

        breakIfNeeded(leading)

        var x = margin
        for (index, cell) in cells.enumerated() {
            let boxWidth = contentWidth() * fractions[index]
            textAt(
                cell, x: x, y: y - font.ascender(pointSize),
                size: pointSize, font: font, color: color,
                align: aligns[index] ?? .left, boxWidth: boxWidth
            )
            x += boxWidth
        }
        y -= leading
        return self
    }

    // MARK: Shapes

    @discardableResult
    public func rule(color: Color? = nil, thickness: Double = 0.5, spacing: Double = 6) -> Document {
        y -= spacing
        line(from: margin, y, to: right(), y, color: color, thickness: thickness)
        y -= spacing
        return self
    }

    @discardableResult
    public func line(
        from x1: Double, _ y1: Double,
        to x2: Double, _ y2: Double,
        color: Color? = nil,
        thickness: Double = 0.5
    ) -> Document {
        let ink = color ?? .grey(190)
        current += String(
            format: "q\n%@ RG\n%.2F w\n%.2F %.2F m\n%.2F %.2F l\nS\nQ\n",
            ink.operands,
            PDFEncoding.number(thickness),
            PDFEncoding.number(x1), PDFEncoding.number(y1),
            PDFEncoding.number(x2), PDFEncoding.number(y2)
        )
        return self
    }

    @discardableResult
    public func rect(
        x: Double, y rectY: Double, width rectWidth: Double, height rectHeight: Double,
        color: Color? = nil
    ) -> Document {
        let ink = color ?? .grey(242)
        current += String(
            format: "q\n%@ rg\n%.2F %.2F %.2F %.2F re\nf\nQ\n",
            ink.operands,
            PDFEncoding.number(x), PDFEncoding.number(rectY),
            PDFEncoding.number(rectWidth), PDFEncoding.number(rectHeight)
        )
        return self
    }

    /// Draws an SVG `path` d-attribute as PDF path operators.
    @discardableResult
    public func svgPath(
        _ pathData: String,
        x: Double,
        y pathY: Double,
        scale: Double = 1,
        color: Color? = nil,
        svgHeight: Double = 100
    ) -> Document {
        let operators = SVGPath.toPDF(pathData, scale: scale, svgHeight: svgHeight)
        guard !operators.isEmpty else { return self }

        let ink = color ?? .black()
        current += String(
            format: "q\n%@ rg\n1 0 0 1 %.2F %.2F cm\n%@f\nQ\n",
            ink.operands,
            PDFEncoding.number(x), PDFEncoding.number(pathY),
            operators
        )
        return self
    }

    // MARK: Output

    /// The finished PDF bytes.
    public func render(metadata: [String: String] = [:], creationDate: Date = Date()) -> Data {
        var finished = pages
        if !current.isEmpty || finished.isEmpty { finished.append(current) }

        return Writer.write(
            pages: applyFooters(to: finished),
            width: pageWidth,
            height: pageHeight,
            metadata: metadata,
            creationDate: creationDate
        )
    }

    /// Writes the PDF to a file, returning the byte count.
    @discardableResult
    public func save(to url: URL, metadata: [String: String] = [:]) throws -> Int {
        let data = render(metadata: metadata)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    /// Runs the footer callback once per page, now that the total is known.
    private func applyFooters(to streams: [String]) -> [String] {
        guard let footer else { return streams }

        let total = streams.count
        let savedStream = current
        let savedY = y

        var stamped: [String] = []
        for (index, stream) in streams.enumerated() {
            current = ""
            footer(self, index + 1, total)
            stamped.append(stream + current)
        }

        current = savedStream
        y = savedY
        return stamped
    }

    // MARK: Wrapping

    /// Splits text into lines that fit `width`, honouring existing newlines.
    func wrap(_ text: String, font: Font, size: Double, width: Double) -> [String] {
        var lines: [String] = []

        for paragraph in text.components(separatedBy: "\n") {
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var line = ""

            for word in words {
                let candidate = line.isEmpty ? word : line + " " + word
                if font.widthOf(PDFEncoding.escape(candidate), size: size) <= width {
                    line = candidate
                    continue
                }
                if !line.isEmpty { lines.append(line) }

                // A single word wider than the column would otherwise loop
                // forever; break it rather than overflow the margin.
                var remainder = word
                while remainder.count > 1,
                      font.widthOf(PDFEncoding.escape(remainder), size: size) > width {
                    var head = remainder
                    while head.count > 1,
                          font.widthOf(PDFEncoding.escape(head), size: size) > width {
                        head.removeLast()
                    }
                    lines.append(head)
                    remainder = String(remainder.dropFirst(head.count))
                }
                line = remainder
            }
            lines.append(line)
        }
        return lines
    }
}
