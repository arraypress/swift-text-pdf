//
//  Layout.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The furniture every document in this file shares: the masthead, the party
//  block, the totals, the page foot.
//
//  Kept in one place because these are the parts a reader uses to orient
//  themselves. A statement whose title sits two points higher than an invoice's
//  looks like it came from somewhere else, and six copies of the same code
//  drift apart one fix at a time.
//

import Foundation

/// Shared furniture for the document templates.
enum Layout {

    /// The band across the top: mark, name, title, reference.
    ///
    /// Returns the y the body should start at.
    @discardableResult
    static func masthead(
        _ pdf: Document,
        branding: Branding,
        title: String,
        reference: String,
        titleSize: Double = 24,
        extraDrop: Double = 0
    ) -> Double {
        let top = pdf.height() - 48
        var x = pdf.left()

        if let logoPath = branding.logoPath, !logoPath.isEmpty {
            pdf.svgPath(logoPath, x: x, y: top - 34, scale: 34 / branding.logoBox,
                        color: branding.accentColor, svgHeight: branding.logoBox)
            x += 46
        }

        pdf.textAt(branding.name.uppercased(), x: x, y: top - 14, size: 15,
                   font: .helveticaBold, color: branding.accentColor)
        if !branding.tagline.isEmpty {
            pdf.textAt(branding.tagline, x: x, y: top - 27, size: 8, font: .helvetica, color: branding.muted)
        }

        pdf.textAt(title, x: pdf.left(), y: top - 20, size: titleSize,
                   font: .helveticaBold, color: branding.ink, align: .right, boxWidth: pdf.contentWidth())
        if !reference.isEmpty {
            pdf.textAt(reference, x: pdf.left(), y: top - 36, size: 9.5,
                       font: .helvetica, color: branding.muted, align: .right, boxWidth: pdf.contentWidth())
        }

        pdf.move(to: top - 66 - extraDrop)
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                 color: branding.ink, thickness: 0.75)
        pdf.move(to: pdf.cursor() - 26)
        return pdf.cursor()
    }

    /// A labelled block of party details on the left, with an optional column
    /// of label/value rows on the right.
    ///
    /// The two columns are drawn from the same top and the cursor is left below
    /// whichever ran longer, so a long address never runs into the table.
    static func partyColumns(
        _ pdf: Document,
        branding: Branding,
        leftHeading: String,
        party: Party,
        extraLines: [String] = [],
        rightHeading: String = "",
        rows: [(label: String, value: String)] = []
    ) {
        let top = pdf.cursor()

        pdf.textAt(leftHeading, x: pdf.left(), y: top, size: 7, font: .helveticaBold, color: branding.muted)
        pdf.textAt(party.name, x: pdf.left(), y: top - 15, size: 11, font: .helveticaBold, color: branding.ink)

        var y = top - 28
        for line in party.lines() + extraLines {
            pdf.textAt(line, x: pdf.left(), y: y, size: 8.5, font: .helvetica, color: branding.muted)
            y -= 11
        }

        if !rows.isEmpty {
            let column = pdf.contentWidth() / 2
            let x = pdf.left() + column + 20

            if !rightHeading.isEmpty {
                pdf.textAt(rightHeading, x: x, y: top, size: 7, font: .helveticaBold, color: branding.muted)
            }

            var rightY = top - 15
            for row in rows {
                pdf.textAt(row.label, x: x, y: rightY, size: 8.5, font: .helvetica, color: branding.muted)
                pdf.textAt(row.value, x: x, y: rightY, size: 8.5, font: .helveticaBold,
                           color: branding.ink, align: .right, boxWidth: column - 20)
                rightY -= 12
            }
            y = min(y, rightY)
        }
        pdf.move(to: y - 16)
    }

    /// Label and figure pairs under a rule, right-hand side.
    ///
    /// The last pair is the headline, so it is set larger and given a rule of
    /// its own — a reader looking for one number should not have to read the
    /// column to find which.
    static func totals(
        _ pdf: Document,
        branding: Branding,
        rows: [(label: String, value: String)],
        width factor: Double = 0.45
    ) {
        guard !rows.isEmpty else { return }

        let width = pdf.contentWidth() * factor
        let x = pdf.right() - width

        pdf.gap(10)
        pdf.breakIfNeeded(70)
        pdf.line(from: x, pdf.cursor(), to: pdf.right(), pdf.cursor(), color: branding.ink, thickness: 1)
        pdf.gap(20)

        for row in rows {
            let baseline = pdf.cursor()
            pdf.textAt(row.label, x: x, y: baseline, size: 10.5, font: .helveticaBold, color: branding.ink)
            pdf.textAt(row.value, x: x, y: baseline, size: 13, font: .helveticaBold,
                       color: branding.ink, align: .right, boxWidth: width)
            pdf.gap(12)
            pdf.line(from: x, pdf.cursor(), to: pdf.right(), pdf.cursor(),
                     color: branding.hairline, thickness: 0.5)
            pdf.gap(14)
        }
    }

    /// A row of figures across the full width, under a heading.
    ///
    /// Used where the columns are meant to be compared with one another —
    /// ageing buckets, a period's totals — rather than read in sequence.
    static func band(
        _ pdf: Document,
        branding: Branding,
        heading: String,
        cells: [(label: String, value: String)]
    ) {
        guard !cells.isEmpty else { return }

        pdf.gap(14)
        pdf.breakIfNeeded(60)

        if !heading.isEmpty {
            pdf.cell(heading, x: pdf.left(), boxWidth: 200, size: 7,
                     font: .helveticaBold, color: branding.muted)
            pdf.gap(16)
        }

        let column = pdf.contentWidth() / Double(cells.count)
        let top = pdf.cursor()

        pdf.rect(x: pdf.left(), y: top - 30, width: pdf.contentWidth(), height: 34, color: branding.wash)

        var x = pdf.left()
        for cell in cells {
            pdf.textAt(cell.label, x: x, y: top - 8, size: 7.5,
                       font: .helvetica, color: branding.muted, align: .center, boxWidth: column)
            pdf.textAt(cell.value, x: x, y: top - 24, size: 11,
                       font: .helveticaBold, color: branding.ink, align: .center, boxWidth: column)
            x += column
        }
        pdf.move(to: top - 44)
    }

    /// Free text under a hairline.
    static func notes(_ pdf: Document, branding: Branding, heading: String = "", text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pdf.gap(20)
        pdf.breakIfNeeded(60)
        pdf.line(from: pdf.left(), pdf.cursor() + 12, to: pdf.right(), pdf.cursor() + 12,
                 color: branding.hairline, thickness: 0.5)
        pdf.gap(6)

        if !heading.isEmpty {
            pdf.cell(heading, x: pdf.left(), boxWidth: 200, size: 7,
                     font: .helveticaBold, color: branding.muted)
            pdf.gap(14)
        }

        pdf.block(trimmed, x: pdf.left(), width: pdf.contentWidth(),
                  size: 8.5, font: .helvetica, color: branding.ink, leading: 12)
    }

    /// Ruled lines for a signature and a date.
    ///
    /// Printed documents get signed. A delivery note or a timesheet without
    /// somewhere to sign has to be marked up by hand, which is how the copy
    /// that comes back stops matching the copy that was sent.
    static func signature(_ pdf: Document, branding: Branding, captions: [String]) {
        guard !captions.isEmpty else { return }

        pdf.gap(30)
        pdf.breakIfNeeded(70)

        let gutter = 24.0
        let width = (pdf.contentWidth() - gutter * Double(captions.count - 1)) / Double(captions.count)
        let top = pdf.cursor()
        var x = pdf.left()

        for caption in captions {
            pdf.line(from: x, top - 20, to: x + width, top - 20, color: branding.hairline, thickness: 0.5)
            pdf.textAt(caption, x: x, y: top - 32, size: 7.5, font: .helvetica, color: branding.muted)
            x += width + gutter
        }
        pdf.move(to: top - 44)
    }

    /// The running foot: small print, then the page number.
    static func footer(_ pdf: Document, branding: Branding, caption: String = "") {
        let brand = branding

        pdf.onEachPage { doc, page, total in
            var top = 58.0

            if !brand.footnotes.isEmpty {
                doc.line(from: doc.left(), top, to: doc.right(), top, color: brand.hairline)
                var y = 46.0
                for note in brand.footnotes {
                    doc.textAt(note, x: doc.left(), y: y, size: 7.5, font: .helvetica, color: .grey(150))
                    y -= 10
                }
                top = y
            } else if !caption.isEmpty {
                doc.line(from: doc.left(), 54, to: doc.right(), 54, color: brand.hairline, thickness: 0.5)
                doc.textAt(caption, x: doc.left(), y: 42, size: 7.5, font: .helvetica, color: .grey(145))
            }

            if total > 1 || !caption.isEmpty {
                doc.textAt("Page \(page) of \(total)",
                           x: doc.left(), y: brand.footnotes.isEmpty ? 42 : 46, size: 7.5,
                           font: .helvetica, color: .grey(145),
                           align: .right, boxWidth: doc.contentWidth())
            }
        }
    }
}
