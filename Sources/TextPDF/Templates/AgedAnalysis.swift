//
//  AgedDebtors.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Who owes what, or who you owe, and for how long.
//
//  An internal report rather than a document anyone is sent, which changes what
//  it owes the reader. There is no branding to observe and no tone to strike;
//  it exists to be read down a column and acted on, so the ageing buckets are
//  fixed in position, the worst debt sorts to somewhere findable, and the
//  totals row is the one thing that must never be wrong.
//
//  The two directions are the same report read from opposite ends — debtors
//  before chasing, creditors before deciding what to pay this week — so they
//  are one template with a heading that says which, rather than two that drift.
//
//  The buckets are given as labels rather than computed. Where a debt ages from
//  is a policy decision — invoice date in some places, due date in others — and
//  a report that quietly picks one produces figures that disagree with the
//  ledger they came from.
//

import Foundation

/// Which way the ledger runs.
public enum AgedLedger: String, Sendable, Codable, CaseIterable {

    /// Money owed to you.
    case debtors

    /// Money you owe.
    case creditors

    public var title: String {
        switch self {
        case .debtors: return "AGED DEBTORS"
        case .creditors: return "AGED CREDITORS"
        }
    }

    /// What the first column holds.
    ///
    /// A creditors report lists suppliers, and calling that column "Account"
    /// leaves a reader working out which side of the ledger they are on from
    /// the figures.
    var accountHeading: String {
        switch self {
        case .debtors: return "Account"
        case .creditors: return "Supplier"
        }
    }
}

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

/// An aged debtors or creditors report.
public struct AgedAnalysis: Sendable {

    public let branding: Branding

    /// Which way round the report runs.
    public let kind: AgedLedger

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
        kind: AgedLedger = .debtors,
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
        self.kind = kind
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

        Layout.masthead(pdf, branding: branding, title: kind.title, reference: "As at \(asAt)")
        Layout.band(pdf, branding: branding, heading: "", cells: highlights)

        pdf.gap(highlights.isEmpty ? 0 : 8)
        debtorTable(pdf)

        Layout.notes(pdf, branding: branding, text: notes)
        Layout.footer(pdf, branding: branding, caption: "\(branding.name) — \(kind.title.lowercased()) as at \(asAt)")

        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "\(kind.title.capitalized) — \(asAt)",
            "Author": branding.name,
            "Subject": "\(kind.title.capitalized) as at \(asAt)",
        ])
    }

    // MARK: Sections

    private func debtorTable(_ pdf: Document) {
        let headers = [kind.accountHeading] + buckets + ["Total"]

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

/// The previous name for `AgedAnalysis`, when it only ran one way.
@available(*, deprecated, renamed: "AgedAnalysis")
public typealias AgedDebtors = AgedAnalysis
