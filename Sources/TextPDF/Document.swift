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

    /// Drawn on every page *before* its content.
    private var background: ((Document, Int, Int) -> Void)?

    /// Text that could not be drawn as written, with the reason.
    ///
    /// Unrepresentable characters become `?`, which leaves a name looking
    /// merely odd rather than obviously broken — so the substitutions are
    /// recorded here and callers are expected to say something about them.
    public private(set) var substitutions: [Substitution] = []

    /// A run of text the writer could not reproduce.
    public struct Substitution: Sendable, Equatable {

        /// The text as it was given.
        public let text: String

        /// `nil` when a font would fix it; a script name when nothing would.
        public let unsupportedScript: String?
    }

    /// A font carried in the file, used for text the base-14 set cannot draw.
    ///
    /// Applied per string rather than wholesale: an invoice with one Cyrillic
    /// name should embed the glyphs for that name and keep Helvetica for the
    /// other ninety-nine per cent, which keeps the file small and the
    /// typography consistent.
    public var embeddedFont: EmbeddedFont?

    /// The typeface the document is set in.
    ///
    /// Where ``embeddedFont`` is a fallback reached for only when Windows-1252
    /// cannot hold the text, a family is the document's type: it draws
    /// everything, and the base-14 fonts become the fallback instead.
    ///
    /// Layout code needs no changes to benefit — a template asking for
    /// `.helveticaBold` gets the family's bold weight.
    public var family: FontFamily?

    /// Embedded faces in first-use order. The index gives the resource name,
    /// so `/F4` is the first face actually drawn with.
    ///
    /// First-use order rather than the family's order, because only the faces
    /// that get used are written into the file — a family carrying nine
    /// weights of which a design uses three should cost three subsets.
    private var facesInUse: [EmbeddedFont] = []
    private var faceIndex: [ObjectIdentifier: Int] = [:]

    /// Images actually drawn, in first-use order.
    private var imagesInUse: [EmbeddedImage] = []
    private var imageIndex: [ObjectIdentifier: Int] = [:]

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

    /// The same, drawn *behind* the page's content rather than on top of it.
    ///
    /// A running foot is text, and text over text is merely ugly. A panel is
    /// a filled rectangle, and one of those drawn afterwards paints out
    /// everything it covers — so a tinted column or a letterhead has to go
    /// down first, and cannot until the page count is known.
    @discardableResult
    public func behindEachPage(_ callback: @escaping (Document, Int, Int) -> Void) -> Document {
        background = callback
        return self
    }

    public func pageCount() -> Int { pages.count + (current.isEmpty ? 0 : 1) }

    // MARK: Typeface

    /// The family's face at a weight, for passing to a drawing call.
    ///
    /// ```swift
    /// pdf.textAt(name, x: pdf.left(), y: top, size: 22, face: pdf.face(.semibold))
    /// ```
    ///
    /// Returns `nil` when no family is attached, which the drawing calls read
    /// as "use the base-14 font" — so a layout written for a family still
    /// renders, in Helvetica, when none is supplied.
    public func face(_ weight: FontFamily.Weight, italic: Bool = false) -> EmbeddedFont? {
        family?.face(weight, italic: italic)
    }

    /// Which face will actually draw this text, if any.
    ///
    /// Ordered by how specific the instruction was. An explicit face is the
    /// caller naming one and wins; a family is the document's type and covers
    /// everything it can; ``embeddedFont`` is the last resort and applies only
    /// where Windows-1252 falls short, which is the behaviour documents
    /// written before families existed depend on.
    ///
    /// Each candidate must actually cover the text. A family that has no
    /// Cyrillic still lets a Cyrillic name fall through to a fallback font
    /// that does, rather than drawing it in notdef boxes.
    private func resolveFace(font: Font, face: EmbeddedFont?, for text: String) -> EmbeddedFont? {
        if let face, face.covers(text) { return face }
        if let candidate = family?.face(for: font), candidate.covers(text) { return candidate }
        if PDFEncoding.needsEmbedding(text), let embeddedFont, embeddedFont.covers(text) {
            return embeddedFont
        }
        return nil
    }

    /// The PDF resource name for a face, registering it on first use.
    private func resourceName(for face: EmbeddedFont) -> String {
        let key = ObjectIdentifier(face)
        if let index = faceIndex[key] { return "F\(4 + index)" }

        let index = facesInUse.count
        faceIndex[key] = index
        facesInUse.append(face)
        return "F\(4 + index)"
    }

    /// The distance to the baseline for whichever face will draw the text.
    private func ascender(_ text: String, font: Font, size: Double, face: EmbeddedFont?) -> Double {
        resolveFace(font: font, face: face, for: text)?.ascender(size) ?? font.ascender(size)
    }

    // MARK: Text

    /// Flowing text, wrapped to the content width and broken across pages.
    @discardableResult
    public func text(
        _ text: String,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left,
        face: EmbeddedFont? = nil
    ) -> Document {
        let pointSize = size ?? fontSize

        for line in wrap(text, font: font, size: pointSize, width: contentWidth(), face: face) {
            breakIfNeeded(leading)
            // The cursor marks the TOP of the line box; PDF positions text by
            // its baseline. Drawing at the cursor puts ascenders above the
            // margin and through anything drawn above.
            textAt(
                line, x: margin, y: y - ascender(line, font: font, size: pointSize, face: face),
                size: pointSize, font: font, color: color,
                align: align, boxWidth: contentWidth(), face: face
            )
            y -= leading
        }
        return self
    }

    @discardableResult
    public func heading(
        _ text: String, size: Double? = nil, color: Color? = nil, face: EmbeddedFont? = nil
    ) -> Document {
        self.text(text, size: size ?? fontSize + 2, font: .helveticaBold, color: color, face: face)
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
        align: Align = .left,
        face: EmbeddedFont? = nil,
        tracking: Double = 0
    ) -> Document {
        let pointSize = size ?? fontSize
        return textAt(
            text, x: x, y: y - ascender(text, font: font, size: pointSize, face: face),
            size: pointSize, font: font, color: color, align: align, boxWidth: boxWidth,
            face: face, tracking: tracking
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
        align: Align = .left,
        face: EmbeddedFont? = nil
    ) -> Document {
        let pointSize = size ?? fontSize
        let resolved = resolveFace(font: font, face: face, for: text)
        let baseline = resolved?.bandBaseline(bandHeight: bandHeight, size: pointSize)
            ?? font.bandBaseline(bandHeight: bandHeight, size: pointSize)

        return textAt(
            text, x: x, y: y - baseline,
            size: pointSize, font: font, color: color, align: align, boxWidth: boxWidth, face: face
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
        boxWidth: Double = 0,
        face: EmbeddedFont? = nil,
        tracking: Double = 0
    ) -> Document {
        guard !text.isEmpty else { return self }

        // An embedded face draws the run when one applies — a named face, the
        // document's family, or the fallback for text Windows-1252 cannot
        // hold. Resolving per string keeps each subset to what it actually
        // needs.
        if let resolved = resolveFace(font: font, face: face, for: text) {
            return embeddedText(text, x: x, baseline: baseline, size: size,
                                color: color, align: align, boxWidth: boxWidth,
                                tracking: tracking, using: resolved)
        }
        if PDFEncoding.needsEmbedding(text) { record(text) }

        let escaped = PDFEncoding.escape(text)
        var originX = x

        // Alignment is computed from the measured width — the reason the font
        // metrics exist at all.
        if align != .left, boxWidth > 0 {
            let measured = font.widthOf(text, size: size) + Self.trackingWidth(text, tracking)
            originX += align == .right ? boxWidth - measured : (boxWidth - measured) / 2
        }

        let ink = color ?? .black()
        current += "q\n"
        if !ink.isBlack { current += ink.operands + " rg\n" }

        // Tc is text state, and text state is part of the graphics state, so
        // the enclosing q/Q keeps it from leaking into the next run.
        current += "BT\n"
        if tracking != 0 { current += String(format: "%.3F Tc\n", PDFEncoding.number(tracking)) }

        current += String(
            format: "/%@ %.2F Tf\n%.2F %.2F Td\n(%@) Tj\nET\nQ\n",
            font.resourceName,
            PDFEncoding.number(size),
            PDFEncoding.number(originX),
            PDFEncoding.number(baseline),
            escaped
        )
        return self
    }

    /// The width letter-spacing adds to a run.
    ///
    /// The gap follows every glyph, including the last, but that trailing one
    /// is empty space at the end of the line — counting it would leave
    /// right-aligned text sitting a gap short of the margin, visibly out
    /// against anything above or below it.
    static func trackingWidth(_ text: String, _ tracking: Double) -> Double {
        guard tracking != 0 else { return 0 }
        return tracking * Double(max(0, text.unicodeScalars.count - 1))
    }

    /// Notes text that will come out as question marks.
    private func record(_ text: String) {
        let script = Script.unsupported(in: text)
        guard !substitutions.contains(where: { $0.text == text }) else { return }
        substitutions.append(Substitution(text: text, unsupportedScript: script))
    }

    /// Draws text as glyph IDs under Identity-H.
    private func embeddedText(
        _ text: String, x: Double, baseline: Double, size: Double,
        color: Color?, align: Align, boxWidth: Double, tracking: Double,
        using embedded: EmbeddedFont
    ) -> Document {
        let (hex, width) = embedded.encode(text, size: size)
        guard !hex.isEmpty else { return self }

        let measured = width + Self.trackingWidth(text, tracking)
        var originX = x
        if align != .left, boxWidth > 0 {
            originX += align == .right ? boxWidth - measured : (boxWidth - measured) / 2
        }

        let ink = color ?? .black()
        current += "q\n"
        if !ink.isBlack { current += ink.operands + " rg\n" }

        current += "BT\n"
        if tracking != 0 { current += String(format: "%.3F Tc\n", PDFEncoding.number(tracking)) }

        current += String(
            format: "/%@ %.2F Tf\n%.2F %.2F Td\n<%@> Tj\nET\nQ\n",
            resourceName(for: embedded),
            PDFEncoding.number(size),
            PDFEncoding.number(originX),
            PDFEncoding.number(baseline),
            hex
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
        color: Color? = nil,
        face: EmbeddedFont? = nil
    ) -> Document {
        guard !cells.isEmpty else { return self }

        let pointSize = size ?? fontSize
        let fractions = widths.count == cells.count
            ? widths
            : Array(repeating: 1.0 / Double(cells.count), count: cells.count)

        breakIfNeeded(leading)

        // One baseline for the row, not one per cell: resolving per string
        // would sit a cell drawn in the family a hair above one that fell
        // back to Helvetica, and a row of figures would no longer line up.
        let rowAscender = ascender(cells.joined(), font: font, size: pointSize, face: face)

        var x = margin
        for (index, cell) in cells.enumerated() {
            let boxWidth = contentWidth() * fractions[index]
            textAt(
                cell, x: x, y: y - rowAscender,
                size: pointSize, font: font, color: color,
                align: aligns[index] ?? .left, boxWidth: boxWidth, face: face
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

    /// A rectangle with rounded corners.
    ///
    /// A radius of half the shorter side or more gives a pill, which is what a
    /// heading tab or a keyword chip wants.
    @discardableResult
    public func roundedRect(
        x: Double, y rectY: Double, width rectWidth: Double, height rectHeight: Double,
        radius: Double, color: Color? = nil
    ) -> Document {
        fill(Bezier.roundedRect(x: x, y: rectY, width: rectWidth, height: rectHeight, radius: radius),
             color: color ?? .grey(242))
    }

    /// A filled polygon.
    ///
    /// For the shapes a rectangle cannot make — a masthead panel with an
    /// angled lower edge, a corner flash, an arrow.
    @discardableResult
    public func polygon(_ points: [(x: Double, y: Double)], color: Color? = nil) -> Document {
        guard points.count >= 3 else { return self }

        var path = String(format: "%.3F %.3F m\n",
                          PDFEncoding.number(points[0].x), PDFEncoding.number(points[0].y))
        for point in points.dropFirst() {
            path += String(format: "%.3F %.3F l\n",
                           PDFEncoding.number(point.x), PDFEncoding.number(point.y))
        }
        path += "h\n"
        return fill(path, color: color ?? .grey(242))
    }

    /// A filled disc.
    @discardableResult
    public func circle(x: Double, y circleY: Double, radius: Double, color: Color? = nil) -> Document {
        fill(Bezier.circle(x: x, y: circleY, radius: radius), color: color ?? .grey(242))
    }

    /// An unfilled ring.
    ///
    /// Stroked rather than filled as an annulus: one path instead of two, and
    /// the thickness is then a line width the reader antialiases properly
    /// rather than a gap between two curves that can moiré at small sizes.
    @discardableResult
    public func ring(
        x: Double, y ringY: Double, radius: Double, thickness: Double = 2, color: Color? = nil
    ) -> Document {
        stroke(Bezier.circle(x: x, y: ringY, radius: radius),
               color: color ?? .grey(214), thickness: thickness)
    }

    /// Part of a ring, for a dial.
    ///
    /// Angles are in degrees clockwise from twelve o'clock, which is how
    /// somebody describes a dial out loud and not how trigonometry numbers it.
    @discardableResult
    public func arc(
        x: Double, y arcY: Double, radius: Double,
        from startDegrees: Double, to endDegrees: Double,
        thickness: Double = 2, color: Color? = nil, rounded: Bool = true
    ) -> Document {
        func radians(_ degrees: Double) -> Double { (90 - degrees) * .pi / 180 }

        let path = Bezier.arc(
            x: x, y: arcY, radius: radius,
            start: radians(startDegrees), end: radians(endDegrees)
        )
        guard !path.isEmpty else { return self }
        return stroke(path, color: color ?? .grey(120), thickness: thickness, roundCaps: rounded)
    }

    /// A horizontal bar with rounded ends, filled to `fraction`.
    ///
    /// The track is always drawn, because a bar at ten per cent and a bar that
    /// failed to render are otherwise the same picture.
    @discardableResult
    public func meter(
        x: Double, y meterY: Double, width meterWidth: Double, height meterHeight: Double,
        fraction: Double, color: Color? = nil, track: Color? = nil
    ) -> Document {
        let radius = meterHeight / 2
        roundedRect(x: x, y: meterY, width: meterWidth, height: meterHeight,
                    radius: radius, color: track ?? .grey(232))

        let filled = min(max(fraction, 0), 1) * meterWidth
        guard filled > 0.5 else { return self }

        return roundedRect(x: x, y: meterY, width: max(filled, meterHeight),
                           height: meterHeight, radius: radius, color: color ?? .grey(60))
    }

    // MARK: Images

    /// Draws an image into a box.
    ///
    /// The box is filled exactly as given; nothing is scaled to fit, because a
    /// photograph squashed to a square that was meant to be a rectangle is a
    /// worse outcome than one that overhangs where somebody can see it.
    /// ``EmbeddedImage/aspectRatio`` is there to size the box first.
    @discardableResult
    public func image(
        _ picture: EmbeddedImage,
        x: Double, y imageY: Double,
        width imageWidth: Double, height imageHeight: Double
    ) -> Document {
        guard imageWidth > 0, imageHeight > 0 else { return self }
        current += "q\n" + placement(imageWidth, imageHeight, x, imageY)
            + "/\(resourceName(for: picture)) Do\nQ\n"
        return self
    }

    /// The same, clipped to a circle — how a portrait appears on almost every
    /// document that carries one.
    @discardableResult
    public func circularImage(
        _ picture: EmbeddedImage, x: Double, y imageY: Double, diameter: Double
    ) -> Document {
        guard diameter > 0 else { return self }

        let radius = diameter / 2
        // The image is drawn to cover the circle rather than fit inside it, so
        // a portrait that is not square is cropped rather than letterboxed
        // into a circle with slivers of nothing at the edges.
        let ratio = picture.aspectRatio
        let drawnWidth = ratio >= 1 ? diameter * ratio : diameter
        let drawnHeight = ratio >= 1 ? diameter : diameter / ratio

        current += "q\n"
        current += Bezier.circle(x: x + radius, y: imageY + radius, radius: radius)
        current += "W n\n"
        current += placement(
            drawnWidth, drawnHeight,
            x - (drawnWidth - diameter) / 2,
            imageY - (drawnHeight - diameter) / 2
        )
        current += "/\(resourceName(for: picture)) Do\nQ\n"
        return self
    }

    /// The matrix that maps the unit square an image is drawn in onto a box.
    private func placement(_ width: Double, _ height: Double, _ x: Double, _ y: Double) -> String {
        String(format: "%.3F 0 0 %.3F %.3F %.3F cm\n",
               PDFEncoding.number(width), PDFEncoding.number(height),
               PDFEncoding.number(x), PDFEncoding.number(y))
    }

    private func resourceName(for picture: EmbeddedImage) -> String {
        let key = ObjectIdentifier(picture)
        if let index = imageIndex[key] { return "Im\(index + 1)" }

        let index = imagesInUse.count
        imageIndex[key] = index
        imagesInUse.append(picture)
        return "Im\(index + 1)"
    }

    // MARK: Painting

    /// Fills a path built elsewhere.
    @discardableResult
    func fill(_ path: String, color: Color) -> Document {
        guard !path.isEmpty else { return self }
        current += "q\n\(color.operands) rg\n\(path)f\nQ\n"
        return self
    }

    /// Strokes a path built elsewhere.
    @discardableResult
    func stroke(_ path: String, color: Color, thickness: Double, roundCaps: Bool = false) -> Document {
        guard !path.isEmpty else { return self }
        current += "q\n\(color.operands) RG\n"
        current += String(format: "%.2F w\n", PDFEncoding.number(thickness))
        if roundCaps { current += "1 J\n" }
        current += "\(path)S\nQ\n"
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
        svgHeight: Double = 100,
        strokeWidth: Double? = nil
    ) -> Document {
        let operators = SVGPath.toPDF(pathData, scale: scale, svgHeight: svgHeight)
        guard !operators.isEmpty else { return self }

        let ink = color ?? .black()
        let placement = String(format: "1 0 0 1 %.2F %.2F cm\n",
                               PDFEncoding.number(x), PDFEncoding.number(pathY))

        // Stroked when a width is given. Icon sets come in both kinds and a
        // stroke-only path filled instead comes out as a blob — the outline
        // was never meant to enclose anything.
        guard let strokeWidth else {
            current += "q\n\(ink.operands) rg\n\(placement)\(operators)f\nQ\n"
            return self
        }

        current += "q\n\(ink.operands) RG\n"
        current += String(format: "%.2F w\n1 J\n1 j\n", PDFEncoding.number(strokeWidth))
        current += "\(placement)\(operators)S\nQ\n"
        return self
    }

    // MARK: Output

    /// The finished PDF bytes.
    public func render(metadata: [String: String] = [:], creationDate: Date = Date()) -> Data {
        var finished = pages
        if !current.isEmpty || finished.isEmpty { finished.append(current) }

        // Footers draw, and drawing can register a face that nothing in the
        // body used — a page number set in the family is the obvious case. So
        // the streams are stamped first and the face list read afterwards.
        let stamped = applyFooters(to: finished)

        return Writer.write(
            pages: stamped,
            width: pageWidth,
            height: pageHeight,
            metadata: metadata,
            creationDate: creationDate,
            embedded: embeddedFaces,
            images: embeddedImages
        )
    }

    /// The embedded faces actually drawn with, each under the resource name
    /// the content streams already refer to.
    ///
    /// The names are assigned here rather than recomputed by the writer.
    /// Deriving them twice invites the two from drifting, and the failure is
    /// silent: `/F5` in a stream resolving to a different font's object
    /// produces a document that renders in the wrong typeface rather than one
    /// that fails to open.
    private var embeddedFaces: [(name: String, font: EmbeddedFont)] {
        facesInUse.enumerated().map { (name: "F\(4 + $0.offset)", font: $0.element) }
    }

    /// The images actually drawn, under the names the streams refer to.
    private var embeddedImages: [(name: String, image: EmbeddedImage)] {
        imagesInUse.enumerated().map { (name: "Im\($0.offset + 1)", image: $0.element) }
    }

    /// Writes the PDF to a file, returning the byte count.
    @discardableResult
    public func save(to url: URL, metadata: [String: String] = [:]) throws -> Int {
        let data = render(metadata: metadata)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    /// Runs the per-page callbacks, now that the total is known.
    private func applyFooters(to streams: [String]) -> [String] {
        guard footer != nil || background != nil else { return streams }

        let total = streams.count
        let savedStream = current
        let savedY = y

        var stamped: [String] = []
        for (index, stream) in streams.enumerated() {
            current = ""
            y = pageHeight - margin
            background?(self, index + 1, total)
            let beneath = current

            current = ""
            y = pageHeight - margin
            footer?(self, index + 1, total)

            stamped.append(beneath + stream + current)
        }

        current = savedStream
        y = savedY
        return stamped
    }

    // MARK: Wrapping

    /// Splits text into lines that fit `width`, honouring existing newlines.
    /// Draws wrapped text in a box of a given width, advancing the cursor.
    ///
    /// The difference from `cell` is that this one cannot silently lose the end
    /// of a sentence: `cell` draws a single line and anything past the box edge
    /// is simply not there, which is fine for a table cell that was truncated
    /// on purpose and wrong for a note somebody wrote.
    @discardableResult
    public func block(
        _ text: String,
        x: Double,
        width: Double,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left,
        leading lineHeight: Double? = nil,
        face: EmbeddedFont? = nil
    ) -> Double {
        let pointSize = size ?? fontSize
        let step = lineHeight ?? pointSize * 1.35
        let top = y
        var baseline = y

        // Explicit newlines are respected; each paragraph then wraps in turn.
        for paragraph in text.components(separatedBy: "\n") {
            let lines = paragraph.isEmpty
                ? [""]
                : wrap(paragraph, font: font, size: pointSize, width: width, face: face)

            for line in lines {
                if !line.isEmpty {
                    textAt(line, x: x, y: baseline - ascender(line, font: font, size: pointSize, face: face),
                           size: pointSize, font: font, color: color,
                           align: align, boxWidth: width, face: face)
                }
                baseline -= step
            }
        }
        move(to: baseline)
        return top - baseline
    }

    /// The height `block` would take, without drawing anything.
    ///
    /// For sizing a panel before its contents go in it.
    public func blockHeight(
        _ text: String, font: Font = .helvetica, size: Double? = nil,
        width: Double, leading lineHeight: Double? = nil, face: EmbeddedFont? = nil
    ) -> Double {
        let pointSize = size ?? fontSize
        let step = lineHeight ?? pointSize * 1.35
        let count = text.components(separatedBy: "\n").reduce(0) { total, paragraph in
            total + (paragraph.isEmpty
                ? 1
                : wrap(paragraph, font: font, size: pointSize, width: width, face: face).count)
        }
        return Double(count) * step
    }

    // MARK: Measuring

    /// The width of text as *this* document would draw it.
    ///
    /// Public because a layout cannot be written without it. `Font.widthOf`
    /// answers for a base-14 font, which is the wrong answer as soon as a
    /// family is attached — and a caller sizing a panel from it would be
    /// measuring a typeface the page is not set in.
    public func width(
        of text: String,
        size: Double,
        font: Font = .helvetica,
        face: EmbeddedFont? = nil,
        tracking: Double = 0
    ) -> Double {
        measured(text, font: font, size: size, face: face) + Self.trackingWidth(text, tracking)
    }

    /// `text` shortened with an ellipsis to fit `width`.
    public func fit(
        _ text: String,
        into width: Double,
        size: Double,
        font: Font = .helvetica,
        face: EmbeddedFont? = nil
    ) -> String {
        truncate(text, font: font, size: size, width: width, face: face)
    }

    /// `text` broken into lines that fit `width`.
    ///
    /// For deciding how much room a block will need before committing to
    /// where it goes — the two-column designs use it to work out which column
    /// runs longer.
    public func lines(
        of text: String,
        width: Double,
        size: Double,
        font: Font = .helvetica,
        face: EmbeddedFont? = nil
    ) -> [String] {
        wrap(text, font: font, size: size, width: width, face: face)
    }

    /// `text` shortened to fit `width`, measured as it will be drawn.
    func truncate(_ text: String, font: Font, size: Double, width: Double, face: EmbeddedFont? = nil) -> String {
        guard measured(text, font: font, size: size, face: face) > width else { return text }

        let ellipsis = measured("...", font: font, size: size, face: face)
        var trimmed = text
        while !trimmed.isEmpty, measured(trimmed, font: font, size: size, face: face) + ellipsis > width {
            trimmed.removeLast()
        }
        return trimmed + "..."
    }

    /// The width of text as it will actually be drawn.
    func measured(_ text: String, font: Font, size: Double, face: EmbeddedFont? = nil) -> Double {
        if let resolved = resolveFace(font: font, face: face, for: text) {
            return resolved.widthOf(text, size: size)
        }
        return font.widthOf(text, size: size)
    }

    func wrap(_ text: String, font: Font, size: Double, width: Double, face: EmbeddedFont? = nil) -> [String] {
        var lines: [String] = []

        for paragraph in text.components(separatedBy: "\n") {
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            var line = ""

            for word in words {
                let candidate = line.isEmpty ? word : line + " " + word
                if measured(candidate, font: font, size: size, face: face) <= width {
                    line = candidate
                    continue
                }
                if !line.isEmpty { lines.append(line) }

                // A single word wider than the column would otherwise loop
                // forever; break it rather than overflow the margin.
                var remainder = word
                while remainder.count > 1,
                      measured(remainder, font: font, size: size, face: face) > width {
                    var head = remainder
                    while head.count > 1,
                          measured(head, font: font, size: size, face: face) > width {
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
