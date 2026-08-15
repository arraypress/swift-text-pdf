//
//  Statement.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A statement of account: transactions over a period with a running balance.
//
//  A different shape from an invoice, not a variant of one. An invoice bills
//  for a set of line items; a statement reports what happened to an account —
//  charges, payments and credits in date order, opening balance to closing.
//

import Foundation

/// One line on a statement.
public struct Transaction: Sendable, Equatable, Codable {

    public let date: String

    /// The document this line refers to, e.g. `INV-2026-0042`.
    public let reference: String

    public let description: String

    /// What was charged, formatted. Empty for a payment.
    public let charge: String

    /// What was paid or credited, formatted. Empty for a charge.
    public let credit: String

    /// The running balance after this line.
    public let balance: String

    public init(
        date: String,
        reference: String = "",
        description: String,
        charge: String = "",
        credit: String = "",
        balance: String = ""
    ) {
        self.date = date
        self.reference = reference
        self.description = description
        self.charge = charge
        self.credit = credit
        self.balance = balance
    }
}

/// A statement of account.
public struct Statement: Sendable {

    public let branding: Branding
    public let account: Party

    /// The period covered, e.g. `1 July – 31 July 2026`.
    public let period: String

    public let transactions: [Transaction]

    /// Opening and closing figures, shown beside the account block.
    public let summary: [(label: String, value: String)]

    /// The headline figure, usually the amount now due.
    public let closing: [(label: String, value: String)]

    /// Amounts bucketed by how overdue they are.
    ///
    /// The part a statement is actually sent for. A closing balance says how
    /// much is owed; the ageing says how worried to be about it.
    public let ageing: [(label: String, value: String)]

    public let reference: String
    public let notes: String
    public let size: PageSize
    public let orientation: Orientation

    public init(
        branding: Branding,
        account: Party,
        period: String,
        transactions: [Transaction],
        summary: [(label: String, value: String)] = [],
        closing: [(label: String, value: String)] = [],
        ageing: [(label: String, value: String)] = [],
        reference: String = "",
        notes: String = "",
        size: PageSize = .a4,
        orientation: Orientation = .portrait
    ) {
        self.branding = branding
        self.account = account
        self.period = period
        self.transactions = transactions
        self.summary = summary
        self.closing = closing
        self.ageing = ageing
        self.reference = reference
        self.notes = notes
        self.size = size
        self.orientation = orientation
    }

    // MARK: Rendering

    /// Lays the document out.
    ///
    /// The font, if any, has to be in place before anything is drawn — text is
    /// committed to the content stream as it is laid out, so a font attached
    /// afterwards arrives too late to be used.
    public func render(embedding font: EmbeddedFont? = nil) -> Document {
        render(in: nil, fallback: font)
    }

    /// The same, set in a family.
    ///
    /// Where `family` is the document's type and draws everything, `fallback`
    /// is reached for only when the family cannot — a Cyrillic customer name
    /// against a brand face that has no Cyrillic in it.
    public func render(in family: FontFamily?, fallback: EmbeddedFont? = nil) -> Document {
        let pdf = Document(size: size, orientation: orientation, margin: 48, fontSize: 9, leading: 12.5)
        pdf.family = family ?? branding.typeface.flatMap { try? $0.family() }
        pdf.embeddedFont = fallback

        masthead(pdf)
        accountBlock(pdf)

        let table = Table(headers: ["Date", "Reference", "Description", "Charges", "Credits", "Balance"])
        table.widths([0.13, 0.17, 0.30, 0.13, 0.13, 0.14])
            .align([3: .right, 4: .right, 5: .right])
            .rowHeight(17)

        for line in transactions {
            table.row([
                line.date, line.reference, line.description,
                line.charge, line.credit, line.balance,
            ])
        }
        table.draw(pdf, size: 8.5, headerFill: branding.wash)

        closingBlock(pdf)
        ageingBlock(pdf)
        notesBlock(pdf)

        let brand = branding
        pdf.onEachPage { doc, page, total in
            doc.line(from: doc.left(), 54, to: doc.right(), 54, color: brand.hairline, thickness: 0.5)
            doc.textAt("\(brand.name) — statement of account", x: doc.left(), y: 42,
                       size: 7.5, font: .helvetica, color: .grey(145))
            doc.textAt("Page \(page) of \(total)", x: doc.left(), y: 42, size: 7.5,
                       font: .helvetica, color: .grey(145), align: .right, boxWidth: doc.contentWidth())
        }
        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "Statement — \(period)",
            "Author": branding.name,
            "Subject": "Statement of account for \(account.name)",
        ])
    }

    // MARK: Sections

    private func masthead(_ pdf: Document) {
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

        pdf.textAt("STATEMENT", x: pdf.left(), y: top - 20, size: 24,
                   font: .helveticaBold, color: branding.ink, align: .right, boxWidth: pdf.contentWidth())
        pdf.textAt(period, x: pdf.left(), y: top - 36, size: 9.5,
                   font: .helvetica, color: branding.muted, align: .right, boxWidth: pdf.contentWidth())

        pdf.move(to: top - 66)
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(),
                 color: branding.ink, thickness: 0.75)
        pdf.move(to: pdf.cursor() - 26)
    }

    private func accountBlock(_ pdf: Document) {
        let top = pdf.cursor()

        pdf.textAt("ACCOUNT", x: pdf.left(), y: top, size: 7, font: .helveticaBold, color: branding.muted)
        pdf.textAt(account.name, x: pdf.left(), y: top - 15, size: 11, font: .helveticaBold, color: branding.ink)

        var y = top - 28
        for line in account.lines() {
            pdf.textAt(line, x: pdf.left(), y: y, size: 8.5, font: .helvetica, color: branding.muted)
            y -= 11
        }
        if !reference.isEmpty {
            pdf.textAt(reference, x: pdf.left(), y: y, size: 8.5, font: .helvetica, color: branding.muted)
            y -= 11
        }

        if !summary.isEmpty {
            let column = pdf.contentWidth() / 2

            // The right column needs its own heading, exactly as the invoice
            // pairs BILLED TO with DETAILS. Without one the first summary row
            // sits level with the 11pt company name and reads as a stray
            // line rather than the top of a block.
            pdf.textAt("SUMMARY", x: pdf.left() + column + 20, y: top, size: 7,
                       font: .helveticaBold, color: branding.muted)

            var detailY = top - 15
            for row in summary {
                pdf.textAt(row.label, x: pdf.left() + column + 20, y: detailY, size: 8.5,
                           font: .helvetica, color: branding.muted)
                pdf.textAt(row.value, x: pdf.left() + column + 20, y: detailY, size: 8.5,
                           font: .helveticaBold, color: branding.ink, align: .right, boxWidth: column - 20)
                detailY -= 12
            }
            y = min(y, detailY)
        }
        pdf.move(to: y - 16)
    }

    private func closingBlock(_ pdf: Document) {
        guard !closing.isEmpty else { return }

        let width = pdf.contentWidth() * 0.45
        let x = pdf.right() - width

        pdf.gap(10)
        pdf.breakIfNeeded(70)
        pdf.line(from: x, pdf.cursor(), to: pdf.right(), pdf.cursor(), color: branding.ink, thickness: 1)
        pdf.gap(20)

        for row in closing {
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

    /// The ageing buckets, drawn as one banded row.
    ///
    /// Laid out across the full width rather than as a list: the columns are
    /// meant to be compared with each other, and a reader scanning for the
    /// 90-day figure should find it in the same place every month.
    private func ageingBlock(_ pdf: Document) {
        guard !ageing.isEmpty else { return }

        pdf.gap(14)
        pdf.breakIfNeeded(60)

        pdf.cell("AGED ANALYSIS", x: pdf.left(), boxWidth: 200, size: 7,
                 font: .helveticaBold, color: branding.muted)
        pdf.gap(16)

        let column = pdf.contentWidth() / Double(ageing.count)
        let top = pdf.cursor()

        pdf.rect(x: pdf.left(), y: top - 30, width: pdf.contentWidth(), height: 34, color: branding.wash)

        var x = pdf.left()
        for bucket in ageing {
            pdf.textAt(bucket.label, x: x, y: top - 8, size: 7.5,
                       font: .helvetica, color: branding.muted, align: .center, boxWidth: column)
            pdf.textAt(bucket.value, x: x, y: top - 24, size: 11,
                       font: .helveticaBold, color: branding.ink, align: .center, boxWidth: column)
            x += column
        }
        pdf.move(to: top - 44)
    }

    private func notesBlock(_ pdf: Document) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pdf.gap(20)
        pdf.breakIfNeeded(60)
        pdf.line(from: pdf.left(), pdf.cursor() + 12, to: pdf.right(), pdf.cursor() + 12,
                 color: branding.hairline, thickness: 0.5)
        pdf.gap(6)

        pdf.block(trimmed, x: pdf.left(), width: pdf.contentWidth(),
                  size: 8.5, font: .helvetica, color: branding.ink, leading: 12)
    }
}
