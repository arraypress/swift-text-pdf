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
    /// The page being written.
    ///
    /// Internal rather than private so the drawing extensions in this module
    /// can wrap what they draw in `q`/`Q` — a rotation and an alpha are both
    /// "everything until I say otherwise", which cannot be expressed through
    /// a per-call parameter.
    var current = ""

    /// Vertical position, in points from the page bottom.
    private var y: Double

    /// Drawn on every page once the total is known, in registration order.
    private var footers: [(Document, Int, Int) -> Void] = []

    /// Drawn on every page *before* its content, in registration order.
    private var backgrounds: [(Document, Int, Int) -> Void] = []

    /// Every run of text drawn, in the order it was drawn.
    ///
    /// Kept so a template's own checks can ask what actually reached the page
    /// rather than what was in the data. Those are different questions, and on
    /// a document whose validity depends on specific wording appearing, only
    /// the second one is worth answering.
    public private(set) var drawnText: [String] = []

    /// Text a family was attached for and did not draw.
    ///
    /// Not a failure — the run falls back to a base-14 font and appears
    /// correctly — but a visible inconsistency: one glyph in Helvetica in the
    /// middle of a document set in something else. On an invoice that is
    /// usually the currency symbol, because a brand face drawn for a logo
    /// often has no £ or €, and a total is the one figure nobody should have
    /// to look at twice.
    public private(set) var fallbacks: [String] = []

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

    /// Link areas, by page index.
    private var annotations: [Int: [Link]] = [:]

    /// The document's language, as a BCP 47 tag — "en-GB", "de".
    ///
    /// Read by screen readers to choose a pronunciation, and by the reflow
    /// that assistive software applies to a page. Omitted when empty rather
    /// than guessed at: a document declared as English and written in German
    /// is read aloud worse than one that declines to say.
    public var language: String = ""

    /// Distinct alpha values used, in the order first asked for. Each becomes
    /// one graphics state dictionary in the page resources.
    var alphas: [Double] = []

    /// Named points, for the reader's sidebar.
    var bookmarks: [(title: String, page: Int, y: Double)] = []

    /// Extra XMP, for a standard this writer does not know by name.
    ///
    /// Each entry is a complete `rdf:Description` element, appended verbatim
    /// to the metadata packet when one is written — which is only under a
    /// ``Standard`` other than `.none`. Factur-X is the case in mind: its
    /// `fx:` conformance schema lives in the XMP, and a validator fails the
    /// file without it, but this writer has no business knowing invoice
    /// vocabularies.
    public var metadataExtras: [String] = []

    /// Files carried inside the document.
    var attachments: [Attachment] = []

    /// A clickable area, and where it goes.
    struct Link {
        let rect: (Double, Double, Double, Double)
        let url: String
    }

    /// Whether anything was drawn in a font the reader has to supply.
    ///
    /// Tracked because it is the one thing that makes a document unable to
    /// claim PDF/A: the base-14 faces are not embedded and cannot be.
    private(set) var usesBaseFonts = false

    /// Notes that a run went out in one of the reader's own fonts.
    func noteBaseFont() { usesBaseFonts = true }

    /// Which page the per-page callbacks are drawing, while they run.
    ///
    /// A footer registering a link would otherwise attach it to whatever page
    /// happened to be last, because by then the document is finished and the
    /// "current" page is not a meaningful idea.
    private var stampingPage: Int?

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
    ///
    /// Callbacks accumulate rather than replace, drawn in the order they were
    /// registered. Replacing was the old behaviour, and it made a watermark
    /// and a page number mutually exclusive — whichever was asked for second
    /// silently deleted the first.
    @discardableResult
    public func onEachPage(_ callback: @escaping (Document, Int, Int) -> Void) -> Document {
        footers.append(callback)
        return self
    }

    /// The same, drawn *behind* the page's content rather than on top of it.
    ///
    /// A running foot is text, and text over text is merely ugly. A panel is
    /// a filled rectangle, and one of those drawn afterwards paints out
    /// everything it covers — so a tinted column or a letterhead has to go
    /// down first, and cannot until the page count is known.
    ///
    /// Accumulates like ``onEachPage(_:)``: a letterhead panel and a
    /// watermark both draw, in registration order.
    @discardableResult
    public func behindEachPage(_ callback: @escaping (Document, Int, Int) -> Void) -> Document {
        backgrounds.append(callback)
        return self
    }

    public func pageCount() -> Int { pages.count + (current.isEmpty ? 0 : 1) }

    /// The page being written, counting from one.
    ///
    /// Not ``pageCount()``, which counts pages that have something on them: a
    /// bookmark set at the top of a fresh page belongs to that page, and
    /// counting drawn pages would file it under the one before.
    var writingPage: Int { pages.count + 1 }

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

    /// The graphics state index for an alpha, registering it on first use.
    func stateIndex(for alpha: Double) -> Int {
        if let existing = alphas.firstIndex(where: { abs($0 - alpha) < 0.001 }) { return existing }
        alphas.append(alpha)
        return alphas.count - 1
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
    /// - Parameter leading: How far the cursor drops per line. Defaults to the
    ///   document's, which is set for body text — so text asked for at a size
    ///   larger than that would otherwise be overlapped by whatever came next.
    ///   A heading is the usual case, and `nil` is wrong for it.
    public func text(
        _ text: String,
        size: Double? = nil,
        font: Font = .helvetica,
        color: Color? = nil,
        align: Align = .left,
        face: EmbeddedFont? = nil,
        leading lineHeight: Double? = nil
    ) -> Document {
        let pointSize = size ?? fontSize
        let leading = lineHeight ?? max(self.leading, pointSize * 1.25)

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
        tracking: Double = 0,
        wordSpacing: Double = 0
    ) -> Document {
        guard !text.isEmpty else { return self }
        drawnText.append(text)

        // An embedded face draws the run when one applies — a named face, the
        // document's family, or the fallback for text Windows-1252 cannot
        // hold. Resolving per string keeps each subset to what it actually
        // needs.
        if let resolved = resolveFace(font: font, face: face, for: text) {
            return embeddedText(text, x: x, baseline: baseline, size: size,
                                color: color, align: align, boxWidth: boxWidth,
                                tracking: tracking, wordSpacing: wordSpacing, using: resolved)
        }
        if PDFEncoding.needsEmbedding(text) { record(text) }
        if family != nil { recordFallback(text) }

        // Drawn in one of the reader's own fonts, which is what stops a
        // document being able to claim PDF/A.
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { noteBaseFont() }

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
        if wordSpacing != 0 { current += String(format: "%.3F Tw\n", PDFEncoding.number(wordSpacing)) }

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

    /// Notes a run the attached family could not draw.
    private func recordFallback(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !fallbacks.contains(trimmed) else { return }
        fallbacks.append(trimmed)
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
        wordSpacing: Double = 0, using embedded: EmbeddedFont
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

        // Tw applies to byte 32, which under Identity-H is half of a
        // two-byte code and not a space at all. Justifying embedded text
        // therefore means spacing the words by hand, which `block` does.
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
    /// - Parameter dash: On and off lengths, in points. `[3, 2]` is a dotted
    ///   rule; `[]` is solid. A signature line, a cut-here, and the leader in
    ///   a table of contents are all this.
    public func line(
        from x1: Double, _ y1: Double,
        to x2: Double, _ y2: Double,
        color: Color? = nil,
        thickness: Double = 0.5,
        dash: [Double] = []
    ) -> Document {
        let ink = color ?? .grey(190)
        let pattern = dash.isEmpty
            ? ""
            : "[\(dash.map { String(format: "%.2F", PDFEncoding.number($0)) }.joined(separator: " "))] 0 d\n"
        current += String(
            format: "q\n%@ RG\n%.2F w\n\(pattern)%.2F %.2F m\n%.2F %.2F l\nS\nQ\n",
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

    // MARK: Links

    /// Makes a rectangle of the page a link.
    ///
    /// A URL printed on a document is read from a screen far more often than
    /// from paper, and one that cannot be clicked is a string somebody has to
    /// retype. The annotation is invisible — the visible part is whatever text
    /// was drawn there — so a link never changes how the page looks.
    ///
    /// No border, because a reader that draws one draws it in a colour nobody
    /// chose, and a blue box around an email address is the mark of a document
    /// somebody assembled rather than set.
    @discardableResult
    public func link(
        _ url: String,
        x: Double, y linkY: Double,
        width linkWidth: Double, height linkHeight: Double
    ) -> Document {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, linkWidth > 0, linkHeight > 0 else { return self }

        // Kept as the rectangle and the address rather than as a finished
        // dictionary: an encrypted document encrypts its strings, and a URL
        // already baked into a string of PDF syntax cannot be encrypted
        // without parsing that syntax back apart.
        let page = stampingPage ?? pages.count
        annotations[page, default: []].append(
            Link(rect: (x, linkY, x + linkWidth, linkY + linkHeight), url: trimmed)
        )
        return self
    }

    /// Draws text and makes it a link, sized to the text.
    @discardableResult
    public func linked(
        _ text: String,
        url: String,
        x: Double,
        y baseline: Double,
        size: Double,
        font: Font = .helvetica,
        color: Color? = nil,
        face: EmbeddedFont? = nil,
        tracking: Double = 0
    ) -> Document {
        textAt(text, x: x, y: baseline, size: size, font: font,
               color: color, face: face, tracking: tracking)

        let measured = width(of: text, size: size, font: font, face: face, tracking: tracking)
        // The face that will actually draw, not just the one named — with a
        // family attached the named face is usually nil, and the base-14
        // guess put the hot area a shade off the family's true descent.
        let resolved = resolveFace(font: font, face: face, for: text)
        let descent = (resolved?.descender(size) ?? size * 0.22)
        return link(url, x: x, y: baseline - descent, width: measured, height: size)
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
    /// - Parameters:
    ///   - svgHeight: The height of the art's own viewBox, which its y
    ///     coordinates are measured down from. Icon sets are usually 24;
    ///     leaving this at 100 for 24-unit art places it far above the
    ///     anchor, off the page, silently.
    ///   - evenOdd: Fill by the even-odd rule, so a subpath inside another
    ///     cuts a hole rather than filling solid.
    public func svgPath(
        _ pathData: String,
        x: Double,
        y pathY: Double,
        scale: Double = 1,
        color: Color? = nil,
        svgHeight: Double = 100,
        strokeWidth: Double? = nil,
        evenOdd: Bool = false
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
            // Filled. `evenOdd` is what a mark with a hole in it needs: two
            // subpaths wound the same way fill solid under the nonzero rule,
            // so a ring comes out a disc and an icon set drawn that way loses
            // every counter it has.
            current += "q\n\(ink.operands) rg\n\(placement)\(operators)\(evenOdd ? "f*" : "f")\nQ\n"
            return self
        }

        current += "q\n\(ink.operands) RG\n"
        current += String(format: "%.2F w\n1 J\n1 j\n", PDFEncoding.number(strokeWidth))
        current += "\(placement)\(operators)S\nQ\n"
        return self
    }

    // MARK: Output

    /// The finished PDF bytes.
    /// - Parameter password: Locks the document. Every stream and every
    ///   string is encrypted with AES-256, so it cannot be opened — or read
    ///   by anything — without it.
    ///
    ///   It is exactly as strong as the password, and the common use of this
    ///   feature is a payslip keyed to a date of birth, which is guessed
    ///   offline in seconds. That satisfies a policy; it is not secrecy.
    ///
    ///   Cannot be combined with `standard`: PDF/A forbids encryption
    ///   outright, an archive being a thing that must still open in fifty
    ///   years. Asking for both is a programming error and traps.
    /// - Parameter standard: Which standard the file claims. `.pdfA3b` also
    ///   writes the metadata packet, the sRGB output intent and the file
    ///   identifier that conformance requires — see
    ///   ``conformanceIssues(for:)`` for what it cannot fix on your behalf.
    public func render(
        metadata: [String: String] = [:],
        creationDate: Date = Date(),
        standard: Standard = .none,
        password: String = ""
    ) -> Data {
        precondition(
            Encryption.problem(with: password) == nil,
            Encryption.problem(with: password) ?? ""
        )

        let locked = Encryption(password: password)
        precondition(
            locked == nil || standard == .none,
            "A PDF/A file cannot be encrypted — the standard forbids it, because an archive "
                + "is a thing that has to still open when nobody remembers the password."
        )

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
            images: embeddedImages,
            annotations: annotations,
            language: language,
            alphas: alphas,
            outline: bookmarks,
            attachments: attachments,
            standard: standard,
            metadataExtras: metadataExtras,
            encryption: locked
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
        guard !footers.isEmpty || !backgrounds.isEmpty else { return streams }

        let total = streams.count
        let savedStream = current
        let savedY = y

        var stamped: [String] = []
        for (index, stream) in streams.enumerated() {
            stampingPage = index

            current = ""
            y = pageHeight - margin
            for background in backgrounds { background(self, index + 1, total) }
            let beneath = current

            current = ""
            y = pageHeight - margin
            for footer in footers { footer(self, index + 1, total) }

            stamped.append(beneath + stream + current)
        }

        stampingPage = nil
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

            for (index, line) in lines.enumerated() {
                if !line.isEmpty {
                    let drop = ascender(line, font: font, size: pointSize, face: face)

                    // The last line of a paragraph is set flush left however
                    // the rest is set. Stretching four words across a full
                    // measure is the thing that makes justified text look like
                    // a ransom note.
                    if align == .justified, index < lines.count - 1 {
                        justify(line, x: x, y: baseline - drop, width: width,
                                size: pointSize, font: font, color: color, face: face)
                    } else {
                        textAt(line, x: x, y: baseline - drop,
                               size: pointSize, font: font, color: color,
                               align: align == .justified ? .left : align,
                               boxWidth: width, face: face)
                    }
                }
                baseline -= step
            }
        }
        move(to: baseline)
        return top - baseline
    }

    /// Draws one line with its words spread to both edges.
    ///
    /// The words are placed individually rather than set with the `Tw`
    /// operator. Tw adds its space to byte 32, and under Identity-H — which is
    /// how every embedded font here is encoded — byte 32 is half of a two-byte
    /// character code and not a space at all. A document set in an embedded
    /// family would come out with gaps in the middle of words.
    private func justify(
        _ line: String, x: Double, y baseline: Double, width: Double,
        size: Double, font: Font, color: Color?, face: EmbeddedFont?
    ) {
        let words = line.split(separator: " ").map(String.init)
        guard words.count > 1 else {
            textAt(line, x: x, y: baseline, size: size, font: font,
                   color: color, face: face)
            return
        }

        let ink = words.reduce(0.0) { $0 + measured($1, font: font, size: size, face: face) }
        let gap = (width - ink) / Double(words.count - 1)

        // A line that is already too long for its measure is left alone: a
        // negative gap would run the words backwards over one another.
        guard gap > 0 else {
            textAt(line, x: x, y: baseline, size: size, font: font, color: color, face: face)
            return
        }

        var cursorX = x
        for word in words {
            textAt(word, x: cursorX, y: baseline, size: size, font: font, color: color, face: face)
            cursorX += measured(word, font: font, size: size, face: face) + gap
        }
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
