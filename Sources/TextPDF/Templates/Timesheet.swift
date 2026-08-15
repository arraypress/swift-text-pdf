//
//  Timesheet.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A record of time worked over a period, and what it comes to.
//
//  Not an invoice with different words. A timesheet is the evidence behind an
//  invoice: it is approved by somebody other than the person who wrote it, it
//  is organised by day rather than by deliverable, and the figure at the bottom
//  is hours first and money second — a client disputing a bill argues about the
//  hours, so those are what the document has to make checkable.
//

import Foundation

/// One period of work.
public struct TimeEntry: Sendable, Equatable, Codable {

    public let date: String

    /// The project, matter or job code this time is booked to.
    public let project: String

    public let description: String

    /// Hours as written, e.g. `7.5` or `7:30`.
    ///
    /// A string like every other quantity here: decimal hours and hours:minutes
    /// are both in use, sites differ over rounding to the nearest six or
    /// fifteen minutes, and a total that disagrees with the timekeeping system
    /// by a rounding rule is worse than no total.
    public let hours: String

    /// The charge-out rate, formatted. Empty where time is not billed.
    public let rate: String

    /// Hours times rate, formatted.
    public let amount: String

    /// `true` where the time is recorded but not charged.
    ///
    /// Shown rather than omitted: written-off time is the most useful thing on
    /// a timesheet, and a client who never sees it never knows it was given.
    public let nonBillable: Bool

    public init(
        date: String,
        project: String = "",
        description: String,
        hours: String,
        rate: String = "",
        amount: String = "",
        nonBillable: Bool = false
    ) {
        self.date = date
        self.project = project
        self.description = description
        self.hours = hours
        self.rate = rate
        self.amount = amount
        self.nonBillable = nonBillable
    }
}

/// A timesheet for a period.
public struct Timesheet: Sendable {

    public let branding: Branding

    /// Who did the work.
    public let worker: Party

    /// Who it was done for. Omitted for an internal sheet.
    public let client: Party?

    /// The period covered, e.g. `1 – 31 July 2026`.
    public let period: String

    public let reference: String
    public let entries: [TimeEntry]

    /// Totals by project, drawn as a band above the money.
    public let byProject: [(label: String, value: String)]

    /// Hours, then value. Both, because they are checked separately.
    public let totals: [(label: String, value: String)]

    /// Who approves it, e.g. `["Prepared by", "Approved by"]`.
    public let signatories: [String]

    public let notes: String
    public let size: PageSize
    public let orientation: Orientation

    public init(
        branding: Branding,
        worker: Party,
        client: Party? = nil,
        period: String,
        reference: String = "",
        entries: [TimeEntry],
        byProject: [(label: String, value: String)] = [],
        totals: [(label: String, value: String)] = [],
        signatories: [String] = [],
        notes: String = "",
        size: PageSize = .a4,
        orientation: Orientation = .portrait
    ) {
        self.branding = branding
        self.worker = worker
        self.client = client
        self.period = period
        self.reference = reference
        self.entries = entries
        self.byProject = byProject
        self.totals = totals
        self.signatories = signatories
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

        Layout.masthead(pdf, branding: branding, title: "TIMESHEET", reference: period)

        var rows: [(label: String, value: String)] = []
        if !reference.isEmpty { rows.append((label: "Reference", value: reference)) }
        rows.append((label: "Period", value: period))
        if let client { rows.append((label: "Client", value: client.name)) }

        Layout.partyColumns(
            pdf, branding: branding,
            leftHeading: "WORKED BY", party: worker,
            rightHeading: "DETAILS", rows: rows
        )

        entriesTable(pdf)

        Layout.band(pdf, branding: branding, heading: "BY PROJECT", cells: byProject)
        Layout.totals(pdf, branding: branding, rows: totals)
        Layout.notes(pdf, branding: branding, text: notes)
        Layout.signature(pdf, branding: branding, captions: signatories)
        Layout.footer(pdf, branding: branding, caption: "\(branding.name) — timesheet, \(period)")

        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "Timesheet — \(period)",
            "Author": branding.name,
            "Subject": "Time recorded by \(worker.name), \(period)",
        ])
    }

    // MARK: Sections

    private func entriesTable(_ pdf: Document) {
        // The rate and amount columns are dropped entirely when no entry is
        // charged, rather than drawn empty: an internal sheet with two blank
        // money columns invites somebody to fill them in.
        let priced = entries.contains { !$0.amount.isEmpty || !$0.rate.isEmpty }

        let table = priced
            ? Table(headers: ["Date", "Project", "Description", "Hours", "Rate", "Amount"])
            : Table(headers: ["Date", "Project", "Description", "Hours"])

        if priced {
            table.widths([0.12, 0.18, 0.36, 0.10, 0.11, 0.13]).align([3: .right, 4: .right, 5: .right])
        } else {
            table.widths([0.14, 0.24, 0.50, 0.12]).align([3: .right])
        }
        table.rowHeight(17)

        for entry in entries {
            // Non-billable time is marked in the description rather than by
            // colour alone, so it survives a photocopy and a printout.
            let description = entry.nonBillable
                ? "\(entry.description) (non-billable)"
                : entry.description

            table.row(priced
                ? [entry.date, entry.project, description, entry.hours, entry.rate, entry.amount]
                : [entry.date, entry.project, description, entry.hours])
        }
        table.draw(pdf, size: 8.5, headerFill: branding.wash)
    }
}
