//
//  AgedDebtors.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Who owes what, and for how long.
//
//  An internal report rather than a document anyone is sent, which changes what
//  it owes the reader. There is no branding to observe and no tone to strike;
//  it exists to be read down a column and acted on, so the ageing buckets are
//  fixed in position, the worst debt sorts to somewhere findable, and the
//  totals row is the one thing that must never be wrong.
//
//  The buckets are given as labels rather than computed. Where a debt ages from
//  is a policy decision — invoice date in some places, due date in others — and
//  a report that quietly picks one produces figures that disagree with the
//  ledger they came from.
//

import Foundation

/// One account's exposure, split by age.
public struct DebtorRow: Sendable, Equatable, Codable {

    public let account: String

    /// A contact or account code, shown under the name.
    public let reference: String

    /// Amounts per bucket, in the same order as the report's `buckets`.
    ///
    /// Short rows are padded and long ones truncated when drawn, so a row that
    /// does not match the header cannot silently shift every figure one column
    /// to the left.
    public let amounts: [String]

    public let total: String

    /// Marks the row for attention — over its limit, on stop, in dispute.
    public let flagged: Bool

    public init(
        account: String,
        reference: String = "",
        amounts: [String],
        total: String,
        flagged: Bool = false
    ) {
        self.account = account
        self.reference = reference
        self.amounts = amounts
        self.total = total
        self.flagged = flagged
    }
}

/// An aged debtors report.
public struct AgedDebtors: Sendable {

    public let branding: Branding

    /// The date the ageing is calculated to.
    public let asAt: String

    /// Bucket headings, e.g. `["Current", "31–60", "61–90", "90+"]`.
    public let buckets: [String]

    public let rows: [DebtorRow]

    /// The totals row, one figure per bucket then the grand total.
    public let totals: [String]

    /// Figures worth pulling out — total owed, overdue, oldest debt.
    public let highlights: [(label: String, value: String)]

    public let notes: String
    public let size: PageSize
    public let orientation: Orientation

    public init(
        branding: Branding,
        asAt: String,
        buckets: [String],
        rows: [DebtorRow],
        totals: [String] = [],
        highlights: [(label: String, value: String)] = [],
        notes: String = "",
        size: PageSize = .a4,
        orientation: Orientation = .landscape
    ) {
        self.branding = branding
        self.asAt = asAt
        self.buckets = buckets
        self.rows = rows
        self.totals = totals
        self.highlights = highlights
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
        let pdf = Document(size: size, orientation: orientation, margin: 48, fontSize: 9, leading: 12.5)
        pdf.embeddedFont = font

        Layout.masthead(pdf, branding: branding, title: "AGED DEBTORS", reference: "As at \(asAt)")
        Layout.band(pdf, branding: branding, heading: "", cells: highlights)

        pdf.gap(highlights.isEmpty ? 0 : 8)
        debtorTable(pdf)

        Layout.notes(pdf, branding: branding, text: notes)
        Layout.footer(pdf, branding: branding, caption: "\(branding.name) — aged debtors as at \(asAt)")

        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "Aged debtors — \(asAt)",
            "Author": branding.name,
            "Subject": "Aged debtors as at \(asAt)",
        ])
    }

    // MARK: Sections

    private func debtorTable(_ pdf: Document) {
        let headers = ["Account"] + buckets + ["Total"]

        // The account column takes what is left after the figures, which are
        // all the same width so the eye can compare down and across.
        let figure = 0.62 / Double(buckets.count + 1)
        let widths = [0.38] + Array(repeating: figure, count: buckets.count + 1)

        let table = Table(headers: headers)
        table.widths(widths)
            .align(Dictionary(uniqueKeysWithValues: (1...(buckets.count + 1)).map { ($0, Align.right) }))
            .rowHeight(17)

        for row in rows {
            // A row shorter than the header would shift every figure left, so
            // it is padded; a longer one is cut. Either way the columns mean
            // what the heading says they mean.
            var amounts = row.amounts
            if amounts.count < buckets.count {
                amounts += Array(repeating: "", count: buckets.count - amounts.count)
            } else if amounts.count > buckets.count {
                amounts = Array(amounts.prefix(buckets.count))
            }

            let name = row.reference.isEmpty ? row.account : "\(row.account)  ·  \(row.reference)"
            table.row([row.flagged ? "! \(name)" : name] + amounts + [row.total])
        }

        if !totals.isEmpty {
            var figures = totals
            if figures.count < buckets.count + 1 {
                figures += Array(repeating: "", count: buckets.count + 1 - figures.count)
            }
            table.total(["Total"] + Array(figures.prefix(buckets.count + 1)))
        }

        table.draw(pdf, size: 8.5, headerFill: branding.wash)
    }
}
