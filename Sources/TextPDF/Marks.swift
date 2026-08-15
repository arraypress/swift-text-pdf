//
//  Marks.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Transparency, rotation, watermarks and bookmarks.
//
//  All four are the same kind of thing: a document that is *about* something
//  else. A watermark says this copy is not the record; a bookmark says where
//  the record's parts are. Neither belongs in the content, and both were
//  impossible here — a diagonal DRAFT across a page needs a rotation and a
//  constant alpha, and this writer had neither.
//

import Foundation

extension Document {

    // MARK: Transparency

    /// Draws everything in `body` at a constant alpha.
    ///
    /// Alpha lives in a graphics state dictionary rather than in the content
    /// stream, so each distinct value is named once in the page's resources
    /// and the stream refers to it. Nesting is allowed; the inner value wins
    /// for what it encloses, which is what `q`/`Q` mean.
    @discardableResult
    public func transparent(_ alpha: Double, _ body: () -> Void) -> Document {
        let clamped = min(max(alpha, 0), 1)
        guard clamped < 1 else {
            body()
            return self
        }

        current += "q\n/GS\(stateIndex(for: clamped)) gs\n"
        body()
        current += "Q\n"
        return self
    }

    /// Draws everything in `body` rotated about a point.
    ///
    /// The point is where the page is pinned: text drawn at that spot stays
    /// there and turns about it, which is what you want for a watermark and
    /// for a rotated column heading alike.
    @discardableResult
    public func rotated(
        by degrees: Double, around x: Double, _ y: Double, _ body: () -> Void
    ) -> Document {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)

        // Translate to the pin, rotate, translate back — one matrix.
        current += String(
            format: "q\n%.5F %.5F %.5F %.5F %.2F %.2F cm\n",
            PDFEncoding.number(cosine), PDFEncoding.number(sine),
            PDFEncoding.number(-sine), PDFEncoding.number(cosine),
            PDFEncoding.number(x - x * cosine + y * sine),
            PDFEncoding.number(y - x * sine - y * cosine)
        )
        body()
        current += "Q\n"
        return self
    }

    // MARK: Watermarks

    /// Stamps a word across every page.
    ///
    /// `DRAFT`, `PAID`, `COPY`, `SPECIMEN` — the four that account for almost
    /// every use, and all of them saying the same thing: what you are holding
    /// is not the record. Drawn behind the text by default, because a
    /// watermark that obscures a total is a watermark that costs a phone call.
    ///
    /// - Parameters:
    ///   - angle: Degrees anticlockwise. 45 is the convention.
    ///   - opacity: 0.06–0.12 reads on screen and survives a photocopier.
    ///   - over: Draw on top of the content instead of behind it. Reach for
    ///     this only for `VOID`, where obscuring the document is the point.
    @discardableResult
    public func watermark(
        _ text: String,
        angle: Double = 45,
        size: Double = 96,
        opacity: Double = 0.08,
        color: Color? = nil,
        font: Font = .helveticaBold,
        face: EmbeddedFont? = nil,
        over: Bool = false
    ) -> Document {
        let stamped = text.trimmingCharacters(in: .whitespaces)
        guard !stamped.isEmpty else { return self }

        let ink = color ?? .grey(0)
        let draw: (Document, Int, Int) -> Void = { document, _, _ in
            let width = document.width(of: stamped, size: size, font: font, face: face)
            let centreX = document.width() / 2
            let centreY = document.height() / 2

            document.transparent(opacity) {
                document.rotated(by: angle, around: centreX, centreY) {
                    document.textAt(stamped, x: centreX - width / 2, y: centreY - size * 0.36,
                                    size: size, font: font, color: ink, face: face)
                }
            }
        }

        return over ? onEachPage(draw) : behindEachPage(draw)
    }

    // MARK: Bookmarks

    /// Names this point in the document, for the reader's sidebar.
    ///
    /// Worth having the moment a document is longer than a scroll: a statement
    /// of account over twelve pages, an academic CV, a consignment with four
    /// hundred lines. Flat rather than nested, because a filing system inside
    /// a document is a thing nobody asked for.
    @discardableResult
    public func bookmark(_ title: String) -> Document {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }

        bookmarks.append((title: trimmed, page: writingPage, y: cursor()))
        return self
    }
}
