//
//  Shipping.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A commercial invoice and a packing list: the two documents that travel with
//  goods across a border.
//
//  These are not invoices with extra wording. A commercial invoice is what a
//  customs officer values a consignment from, so it carries fields a sales
//  invoice has no notion of — a tariff heading per line, where each good was
//  made, the delivery term that says who pays the duty, and gross and net
//  weights. Getting those wrong holds the goods, and inventing them is worse
//  than leaving the document unwritten.
//
//  A packing list answers a different question — what is in which carton — and
//  carries no prices at all, deliberately. It is read by people handling the
//  boxes, and in some trades it goes to the buyer's customer, who should not be
//  reading the seller's margins.
//
//  Country of origin is where goods were produced, which is not where they were
//  shipped from and not where the seller is registered. The three differ often
//  enough that the field is asked for plainly rather than derived.
//

import Foundation

/// One line of a consignment.
public struct ConsignmentItem: Sendable, Equatable, Codable {

    public let description: String

    /// The Harmonised System heading, six digits or more.
    ///
    /// What the duty rate is looked up from. Six digits are international; the
    /// digits after are national, so a code that works for export may need
    /// extending on entry.
    public let commodityCode: String

    /// Where the goods were produced, not where they ship from.
    public let countryOfOrigin: String

    /// Quantity with its unit, e.g. `120 pcs`.
    public let quantity: String

    /// Net weight — the goods alone.
    public let netWeight: String

    /// Gross weight — goods with their packaging.
    public let grossWeight: String

    public let unitPrice: String
    public let amount: String

    /// Which carton, pallet or case this line is in.
    public let package: String

    public init(
        description: String,
        commodityCode: String = "",
        countryOfOrigin: String = "",
        quantity: String = "",
        netWeight: String = "",
        grossWeight: String = "",
        unitPrice: String = "",
        amount: String = "",
        package: String = ""
    ) {
        self.description = description
        self.commodityCode = commodityCode
        self.countryOfOrigin = countryOfOrigin
        self.quantity = quantity
        self.netWeight = netWeight
        self.grossWeight = grossWeight
        self.unitPrice = unitPrice
        self.amount = amount
        self.package = package
    }
}

/// Which of the two documents to produce.
public enum ShippingDocument: String, Sendable, Codable, CaseIterable {

    /// Valued, for customs.
    case commercialInvoice

    /// Contents and weights, no prices.
    case packingList

    public var title: String {
        switch self {
        case .commercialInvoice: return "COMMERCIAL INVOICE"
        case .packingList: return "PACKING LIST"
        }
    }

    /// The declaration printed above the signature.
    ///
    /// A commercial invoice is a declaration, and an unsigned one is routinely
    /// refused. The wording is the ordinary form of words; it is stated on the
    /// document rather than assumed to be understood.
    var declaration: String {
        switch self {
        case .commercialInvoice:
            return "I declare that the information given above is true and complete, "
                + "and that the goods described are of the origin shown."
        case .packingList:
            return "I declare that the packages listed above contain the goods described."
        }
    }
}

/// A commercial invoice or packing list.
public struct Consignment: Sendable {

    public let branding: Branding
    public let kind: ShippingDocument

    public let number: String
    public let date: String

    /// Who is selling and sending. Where they differ, name the shipper in `details`.
    public let exporter: Party

    /// Who is buying.
    public let consignee: Party

    /// Where the goods are going, when that is not the consignee.
    ///
    /// Drop-shipments and delivery to a third-party warehouse are common
    /// enough that conflating the two puts goods in the wrong country.
    public let deliverTo: Party?

    /// Reference rows — order number, incoterm, port, vessel, waybill.
    public let details: [(label: String, value: String)]

    public let items: [ConsignmentItem]

    /// Delivery term and named place, e.g. `DAP Rotterdam (Incoterms 2020)`.
    ///
    /// Given as written rather than as a code alone: the term means nothing
    /// without its place, and the edition matters because the rules changed.
    public let incoterm: String

    /// Where the goods were shipped from, and to.
    public let countryOfExport: String
    public let countryOfDestination: String

    /// Why the goods are moving — sale, sample, repair, replacement.
    ///
    /// Customs treat a sale and a free replacement differently, so a document
    /// that does not say invites the officer to assume the dutiable one.
    public let reasonForExport: String

    /// Package counts and weights, drawn as a band.
    public let totals: [(label: String, value: String)]

    /// The value, for a commercial invoice. Ignored on a packing list.
    public let value: [(label: String, value: String)]

    public let notes: String
    public let size: PageSize
    public let orientation: Orientation

    public init(
        branding: Branding,
        kind: ShippingDocument = .commercialInvoice,
        number: String,
        date: String = "",
        exporter: Party,
        consignee: Party,
        deliverTo: Party? = nil,
        details: [(label: String, value: String)] = [],
        items: [ConsignmentItem],
        incoterm: String = "",
        countryOfExport: String = "",
        countryOfDestination: String = "",
        reasonForExport: String = "",
        totals: [(label: String, value: String)] = [],
        value: [(label: String, value: String)] = [],
        notes: String = "",
        size: PageSize = .a4,
        orientation: Orientation = .portrait
    ) {
        self.branding = branding
        self.kind = kind
        self.number = number
        self.date = date
        self.exporter = exporter
        self.consignee = consignee
        self.deliverTo = deliverTo
        self.details = details
        self.items = items
        self.incoterm = incoterm
        self.countryOfExport = countryOfExport
        self.countryOfDestination = countryOfDestination
        self.reasonForExport = reasonForExport
        self.totals = totals
        self.value = value
        self.notes = notes
        self.size = size
        self.orientation = orientation
    }

    // MARK: Compliance

    /// Particulars a consignment is expected to carry.
    ///
    /// The same bargain the invoice template strikes: this checks that the
    /// fields are present, not that they are right. A commodity code is either
    /// there or it is not, and no template can tell whether it is the correct
    /// heading for what is in the box.
    public func complianceWarnings() -> [String] {
        var missing: [String] = []

        if exporter.name.isEmpty { missing.append("exporter's name") }
        if exporter.address.isEmpty { missing.append("exporter's address") }
        if consignee.name.isEmpty { missing.append("consignee's name") }
        if consignee.address.isEmpty { missing.append("consignee's address") }
        if number.isEmpty { missing.append("document number") }
        if date.isEmpty { missing.append("date") }
        if countryOfExport.isEmpty { missing.append("country of export") }
        if countryOfDestination.isEmpty { missing.append("country of destination") }

        if items.contains(where: { $0.commodityCode.isEmpty }) {
            missing.append("commodity code on every line")
        }
        if items.contains(where: { $0.countryOfOrigin.isEmpty }) {
            missing.append("country of origin on every line")
        }
        if items.contains(where: { $0.grossWeight.isEmpty && $0.netWeight.isEmpty }) {
            missing.append("a weight on every line")
        }

        if kind == .commercialInvoice {
            if incoterm.isEmpty { missing.append("delivery term (Incoterm) and named place") }
            if reasonForExport.isEmpty { missing.append("reason for export") }
            if value.isEmpty { missing.append("total value") }
            if items.contains(where: { $0.amount.isEmpty }) {
                missing.append("a value on every line")
            }
        }
        return missing
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

        Layout.masthead(pdf, branding: branding, title: kind.title, reference: number, titleSize: 20)
        parties(pdf)
        route(pdf)
        itemsTable(pdf)

        Layout.band(pdf, branding: branding, heading: "TOTALS", cells: totals)
        if kind == .commercialInvoice {
            Layout.totals(pdf, branding: branding, rows: value)
        }

        Layout.notes(pdf, branding: branding, text: notes)
        declaration(pdf)
        Layout.footer(pdf, branding: branding, caption: "\(branding.name) — \(kind.title.lowercased()) \(number)")

        return pdf
    }

    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "\(kind.title.capitalized) \(number)",
            "Author": branding.name,
            "Subject": "\(kind.title.capitalized) \(number) for \(consignee.name)",
        ])
    }

    // MARK: Sections

    private func parties(_ pdf: Document) {
        var rows = details
        if !date.isEmpty { rows.insert((label: "Date", value: date), at: 0) }

        Layout.partyColumns(
            pdf, branding: branding,
            leftHeading: "EXPORTER", party: exporter,
            rightHeading: "DETAILS", rows: rows
        )

        // Consignee and delivery address side by side, since the whole point
        // is that they may differ.
        let top = pdf.cursor()
        let column = pdf.contentWidth() / 2

        pdf.textAt("CONSIGNEE", x: pdf.left(), y: top, size: 7, font: .helveticaBold, color: branding.muted)
        pdf.textAt(consignee.name, x: pdf.left(), y: top - 15, size: 10, font: .helveticaBold, color: branding.ink)

        var leftY = top - 28
        for line in consignee.lines() {
            pdf.textAt(line, x: pdf.left(), y: leftY, size: 8.5, font: .helvetica, color: branding.muted)
            leftY -= 11
        }

        var rightY = leftY
        if let deliverTo {
            let x = pdf.left() + column + 20
            pdf.textAt("DELIVER TO", x: x, y: top, size: 7, font: .helveticaBold, color: branding.muted)
            pdf.textAt(deliverTo.name, x: x, y: top - 15, size: 10, font: .helveticaBold, color: branding.ink)

            rightY = top - 28
            for line in deliverTo.lines() {
                pdf.textAt(line, x: x, y: rightY, size: 8.5, font: .helvetica, color: branding.muted)
                rightY -= 11
            }
        }
        pdf.move(to: min(leftY, rightY) - 14)
    }

    /// Where the goods are going, on what terms, and why.
    private func route(_ pdf: Document) {
        let cells = [
            (label: "From", value: countryOfExport),
            (label: "To", value: countryOfDestination),
            (label: "Terms", value: incoterm),
            (label: "Reason for export", value: reasonForExport),
        ].filter { !$0.value.isEmpty }

        guard !cells.isEmpty else { return }

        let column = pdf.contentWidth() / Double(cells.count)
        let inner = column - 20

        // A delivery term carries its named place, so these values wrap rather
        // than run into the column beside them.
        let tallest = cells
            .map { pdf.blockHeight($0.value, size: 8.5, width: inner, leading: 11) }
            .max() ?? 0
        let height = tallest + 26

        pdf.breakIfNeeded(height + 14)
        let top = pdf.cursor()
        pdf.rect(x: pdf.left(), y: top - height + 6, width: pdf.contentWidth(), height: height, color: branding.wash)

        var x = pdf.left()
        for cell in cells {
            pdf.textAt(cell.label.uppercased(), x: x + 10, y: top - 8, size: 6.5,
                       font: .helveticaBold, color: branding.muted)
            pdf.move(to: top - 14)
            pdf.block(cell.value, x: x + 10, width: inner, size: 8.5,
                      font: .helvetica, color: branding.ink, leading: 11)
            x += column
        }
        pdf.move(to: top - height - 10)
    }

    private func itemsTable(_ pdf: Document) {
        // A packing list carries no prices. That is the difference between the
        // two documents, not a formatting choice.
        let priced = kind == .commercialInvoice

        // Column widths are a customs matter, not a typographic one. A country
        // of origin abbreviated to "Unite..." is the difference between goods
        // clearing and goods being held, so origin and the tariff heading get
        // room before the description does.
        // Derived once and used for both the header and the rows. Asking the
        // header list whether it contains a column was the bug that dropped
        // every package number and shifted the whole row one place left.
        let hasPackages = items.contains { !$0.package.isEmpty }

        var headers = ["Description", "HS code", "Origin", "Qty"]
        var widths = [0.22, 0.12, 0.15, 0.08]
        var right: Set<Int> = [3]

        if hasPackages {
            headers.insert("Pkg", at: 1)
            widths.insert(0.07, at: 1)
            right = Set(right.map { $0 + 1 })
        }

        headers += ["Net", "Gross"]
        widths += [0.08, 0.08]
        right.insert(headers.count - 2)
        right.insert(headers.count - 1)

        if priced {
            headers += ["Price", "Amount"]
            widths += [0.09, 0.10]
            right.insert(headers.count - 2)
            right.insert(headers.count - 1)
        }

        let scale = widths.reduce(0, +)
        let table = Table(headers: headers)
        table.widths(widths.map { $0 / scale })
            .align(Dictionary(uniqueKeysWithValues: right.map { ($0, Align.right) }))
            .rowHeight(17)

        for item in items {
            var row = [item.description]
            if hasPackages { row.append(item.package) }
            row += [item.commodityCode, item.countryOfOrigin, item.quantity, item.netWeight, item.grossWeight]
            if priced { row += [item.unitPrice, item.amount] }
            table.row(row)
        }
        table.draw(pdf, size: 8, headerFill: branding.wash)
    }

    private func declaration(_ pdf: Document) {
        pdf.gap(16)
        pdf.breakIfNeeded(90)

        pdf.cell(kind.declaration, x: pdf.left(), boxWidth: pdf.contentWidth() * 0.72,
                 size: 8, font: .helvetica, color: branding.muted)
        pdf.gap(14)

        Layout.signature(pdf, branding: branding, captions: ["Signature", "Name and position", "Date"])
    }
}
