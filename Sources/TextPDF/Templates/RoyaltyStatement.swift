//
//  RoyaltyStatement.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  What a contributor earned in a period, and what is actually payable.
//
//  The distinction that shapes this document: earnings and payment are not the
//  same number, and a statement that shows only one of them is the reason
//  royalty statements have the reputation they do.
//
//  Money reaches a contributor through a chain. A distributor sells at some
//  price, keeps a cut, and remits the rest. The remitted amount is split by
//  agreement. The contributor's share is then set against anything advanced
//  against future earnings — recoupment — and only what is left over is paid.
//  A balance that does not recoup carries forward and is not a debt.
//
//  Every one of those steps is shown, because a contributor who cannot see the
//  arithmetic has to take it on trust, and the ones who have been paid badly
//  before will not.
//

import Foundation

/// One earning line — a title, on a channel, in a period.
public struct RoyaltyLine: Sendable, Equatable, Codable {

    /// Who sold it: a distributor, a store, a platform.
    public let source: String

    /// What was sold — a pack, a track, a library.
    public let title: String

    /// Units, streams or licences, formatted.
    public let quantity: String

    /// What the customer paid, before anyone took a cut.
    public let gross: String

    /// What the distributor kept, formatted. Empty where it does not apply.
    public let distributorShare: String

    /// What reached the payer — the base the split is taken from.
    public let net: String

    /// The contributor's share, e.g. `50%`.
    public let rate: String

    /// The contributor's earnings on this line.
    public let earned: String

    public init(
        source: String,
        title: String,
        quantity: String = "",
        gross: String = "",
        distributorShare: String = "",
        net: String,
        rate: String = "",
        earned: String
    ) {
        self.source = source
        self.title = title
        self.quantity = quantity
        self.gross = gross
        self.distributorShare = distributorShare
        self.net = net
        self.rate = rate
        self.earned = earned
    }
}

/// A royalty or commission statement.
public struct RoyaltyStatement: Sendable {

    public let branding: Branding

    /// Who is being paid.
    public let payee: Party

    /// The period the earnings fall in, e.g. `July 2026`.
    public let period: String

    public let reference: String

    /// The agreement these earnings arise under, e.g. `Contributor agreement, 12 March 2024`.
    ///
    /// Named because the split has to come from somewhere, and a contributor
    /// checking a rate needs to know which document to check it against.
    public let agreement: String

    public let lines: [RoyaltyLine]

    /// Earnings totalled by source, drawn as a band.
    ///
    /// Where the money came from is the question a contributor asks first, and
    /// answering it from a long table means adding up by eye.
    public let bySource: [(label: String, value: String)]

    /// The path from earnings to what is payable.
    ///
    /// Opening unrecouped balance, earnings, advances, adjustments, closing
    /// balance — in that order, each line signed so the arithmetic reads
    /// straight down.
    public let reconciliation: [(label: String, value: String)]

    /// The headline figure, usually what is being paid now.
    public let payable: [(label: String, value: String)]

    /// Set when nothing is paid this period.
    ///
    /// A statement showing earnings but no payment looks like an error or a
    /// withholding unless it says which, so the reason is given as a sentence
    /// on the document rather than left to a covering email.
    public let carriedForwardNote: String

    public let notes: String
    public let size: PageSize
    public let orientation: Orientation

    public init(
        branding: Branding,
        payee: Party,
        period: String,
        reference: String = "",
        agreement: String = "",
        lines: [RoyaltyLine],
        bySource: [(label: String, value: String)] = [],
        reconciliation: [(label: String, value: String)] = [],
        payable: [(label: String, value: String)] = [],
        carriedForwardNote: String = "",
        notes: String = "",
        size: PageSize = .a4,
        orientation: Orientation = .portrait
    ) {
        self.branding = branding
        self.payee = payee
        self.period = period
        self.reference = reference
        self.agreement = agreement
        self.lines = lines
        self.bySource = bySource
        self.reconciliation = reconciliation
        self.payable = payable
        self.carriedForwardNote = carriedForwardNote
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

        Layout.masthead(pdf, branding: branding, title: "ROYALTY STATEMENT", reference: period)

        var rows: [(label: String, value: String)] = []
        if !reference.isEmpty { rows.append((label: "Statement", value: reference)) }
        rows.append((label: "Period", value: period))
        if !agreement.isEmpty { rows.append((label: "Under", value: agreement)) }

        Layout.partyColumns(
            pdf, branding: branding,
            leftHeading: "PAYABLE TO", party: payee,
            rightHeading: "DETAILS", rows: rows
        )

        earningsTable(pdf)

        Layout.band(pdf, branding: branding, heading: "BY SOURCE", cells: bySource)
        reconciliationBlock(pdf)
        Layout.totals(pdf, branding: branding, rows: payable)
        carriedForward(pdf)
        Layout.notes(pdf, branding: branding, text: notes)
        Layout.footer(pdf, branding: branding, caption: "\(branding.name) — royalty statement, \(period)")

        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "Royalty statement — \(period)",
            "Author": branding.name,
            "Subject": "Royalties for \(payee.name), \(period)",
        ])
    }

    // MARK: Sections

    private func earningsTable(_ pdf: Document) {
        // Columns nobody filled in are dropped rather than drawn empty. A
        // commission statement has no gross and no distributor cut; a label's
        // does. Both should look deliberate.
        let showsGross = lines.contains { !$0.gross.isEmpty }
        let showsShare = lines.contains { !$0.distributorShare.isEmpty }
        let showsQuantity = lines.contains { !$0.quantity.isEmpty }
        let showsRate = lines.contains { !$0.rate.isEmpty }

        var headers = ["Source", "Title"]
        var widths = [0.16, 0.26]
        var right: Set<Int> = []

        if showsQuantity { headers.append("Units"); widths.append(0.09); right.insert(headers.count - 1) }
        if showsGross { headers.append("Gross"); widths.append(0.12); right.insert(headers.count - 1) }
        if showsShare { headers.append("Distributor"); widths.append(0.12); right.insert(headers.count - 1) }
        headers.append("Net"); widths.append(0.12); right.insert(headers.count - 1)
        if showsRate { headers.append("Share"); widths.append(0.08); right.insert(headers.count - 1) }
        headers.append("Earnings"); widths.append(0.13); right.insert(headers.count - 1)

        // The proportions above are written for the full set; normalising lets
        // a narrower table still fill the page.
        let scale = widths.reduce(0, +)
        let table = Table(headers: headers)
        table.widths(widths.map { $0 / scale })
            .align(Dictionary(uniqueKeysWithValues: right.map { ($0, Align.right) }))
            .rowHeight(17)

        for line in lines {
            var row = [line.source, line.title]
            if showsQuantity { row.append(line.quantity) }
            if showsGross { row.append(line.gross) }
            if showsShare { row.append(line.distributorShare) }
            row.append(line.net)
            if showsRate { row.append(line.rate) }
            row.append(line.earned)
            table.row(row)
        }
        table.draw(pdf, size: 8.5, headerFill: branding.wash)
    }

    /// Opening balance through to closing, as a right-hand column.
    ///
    /// Deliberately not the same shape as the totals block beneath it: this is
    /// a sequence that has to be read in order, and setting it as a list of
    /// equals makes the last line look like a total of the ones above it when
    /// it is a balance carried out.
    private func reconciliationBlock(_ pdf: Document) {
        guard !reconciliation.isEmpty else { return }

        pdf.gap(16)
        pdf.breakIfNeeded(40 + Double(reconciliation.count) * 14)

        let width = pdf.contentWidth() * 0.52
        let x = pdf.right() - width

        pdf.cell("RECONCILIATION", x: x, boxWidth: width, size: 7,
                 font: .helveticaBold, color: branding.muted)
        pdf.gap(18)

        for row in reconciliation {
            let baseline = pdf.cursor()
            pdf.textAt(row.label, x: x, y: baseline, size: 9, font: .helvetica, color: branding.muted)
            pdf.textAt(row.value, x: x, y: baseline, size: 9, font: .helveticaBold,
                       color: branding.ink, align: .right, boxWidth: width)
            pdf.gap(14)
        }
    }

    /// The sentence explaining why nothing is being paid.
    private func carriedForward(_ pdf: Document) {
        let trimmed = carriedForwardNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let inset = 14.0
        let textWidth = pdf.contentWidth() - inset * 2
        let height = pdf.blockHeight(trimmed, size: 9, width: textWidth, leading: 13) + 20

        pdf.gap(14)
        pdf.breakIfNeeded(height + 16)

        let top = pdf.cursor()
        pdf.rect(x: pdf.left(), y: top - height + 10, width: pdf.contentWidth(), height: height, color: branding.wash)
        pdf.rect(x: pdf.left(), y: top - height + 10, width: 3, height: height, color: branding.accentColor)

        pdf.move(to: top - 4)
        pdf.block(trimmed, x: pdf.left() + inset, width: textWidth,
                  size: 9, font: .helvetica, color: branding.ink, leading: 13)
        pdf.move(to: top - height - 4)
    }
}
