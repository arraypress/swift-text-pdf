//
//  Invoice.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A complete invoice from data alone — no layout code at the call site.
//

import Foundation

/// An invoice, credit note, quote or reminder — one layout, six headings.
///
/// The documents differ in wording and in which blocks appear, not in shape,
/// so they share a renderer rather than four near-copies that drift apart.
public enum DocumentKind: String, Sendable, CaseIterable, Codable {

    case invoice
    /// Issued to reverse an invoice. Never amend the original — sequential
    /// numbering forbids it, so a refund is a separate document that cites it.
    case creditNote
    case quote
    /// A pre-payment invoice. Not a tax invoice, and says so.
    case proforma
    case receipt
    case reminder

    /// Sent when *you* pay someone, itemising which of their invoices the
    /// payment covers. Not a tax document — theirs is.
    case remittance

    /// Issued by the buyer on the supplier's behalf, as a marketplace does.
    /// "Self-billing" must appear on the face of it, and both parties' VAT
    /// numbers are required.
    case selfBilling

    /// Accompanies goods. Shows what was sent, never what it cost — a
    /// delivery note goes in the box, and the recipient's warehouse has no
    /// business seeing the price.
    case deliveryNote

    /// Issued by the buyer, committing to purchase.
    case purchaseOrder

    /// Sent by the seller acknowledging an order before fulfilment.
    case orderConfirmation

    /// The counterpart to a credit note: charging more after the fact.
    case debitNote

    public var title: String {
        switch self {
        case .invoice: return "INVOICE"
        case .creditNote: return "CREDIT NOTE"
        case .quote: return "QUOTE"
        case .proforma: return "PROFORMA"
        case .receipt: return "RECEIPT"
        case .reminder: return "REMINDER"
        case .remittance: return "REMITTANCE ADVICE"
        case .selfBilling: return "SELF-BILLED INVOICE"
        case .deliveryNote: return "DELIVERY NOTE"
        case .purchaseOrder: return "PURCHASE ORDER"
        case .orderConfirmation: return "ORDER CONFIRMATION"
        case .debitNote: return "DEBIT NOTE"
        }
    }

    /// The label above the totals block.
    var totalLabel: String {
        switch self {
        case .creditNote: return "Total credited"
        case .debitNote: return "Total charged"
        case .purchaseOrder, .orderConfirmation: return "Order total"
        case .quote, .proforma: return "Total"
        case .receipt, .remittance: return "Total paid"
        default: return "Total due"
        }
    }

    /// Wording printed under the total, when the kind needs it.
    var standingNote: String? {
        switch self {
        case .creditNote:
            return "This credit note reverses the invoice referenced above. Retain both for your records."
        case .quote:
            return "This is a quotation, not a demand for payment. No VAT is due until an invoice is issued."
        case .proforma:
            return "Proforma invoice — not a VAT invoice. A tax invoice follows on payment."
        case .receipt:
            return "Paid in full. No further payment is due."
        case .deliveryNote:
            return "Please check the contents against this note and report any discrepancy within 7 days."
        case .orderConfirmation:
            return "This confirms your order. An invoice follows on despatch."
        case .debitNote:
            return "This debit note charges the additional amount shown against the document referenced above."
        case .remittance:
            return "This advice confirms payment of the invoices listed above. No action is required."
        case .selfBilling:
            // HMRC requires the words on the face of the document; without
            // them the recipient cannot rely on it.
            return "Self-billing. This invoice was raised by the customer on the supplier's behalf under a self-billing agreement."
        default:
            return nil
        }
    }

    /// Whether money appears at all.
    ///
    /// A delivery note travels with the goods, and the recipient's warehouse
    /// has no business seeing what the buyer paid. Suppressing the columns is
    /// the document's defining behaviour, not a styling choice.
    var showsMoney: Bool { self != .deliveryNote }

    /// Whether the mandatory-particulars check applies.
    ///
    /// A quote is not a tax document, so demanding a supply date on one would
    /// be a false warning.
    var isTaxDocument: Bool {
        switch self {
        case .invoice, .creditNote, .receipt, .selfBilling, .debitNote: return true
        // A remittance advice reports a payment against someone else's
        // invoice; the tax particulars belong on theirs, not on this.
        case .quote, .proforma, .reminder, .remittance,
             .deliveryNote, .purchaseOrder, .orderConfirmation: return false
        }
    }
}

/// A business document, rendered from data.
public struct Invoice: Sendable {

    public let kind: DocumentKind
    public let branding: Branding
    public let number: String
    public let from: Party
    public let to: Party
    public let items: [LineItem]

    /// Subtotal rows, in order. A list of pairs rather than a dictionary,
    /// because two `Discount` lines are legitimate and a map cannot hold them.
    public let totals: [(label: String, value: String)]

    /// The headline total.
    public let total: [(label: String, value: String)]

    /// Dates, terms and references.
    public let details: [(label: String, value: String)]

    public let notes: String

    /// An optional stamp, e.g. `PAID` or `OVERDUE`.
    public let status: String

    public let size: PageSize
    public let vat: VatTreatment
    public let vatLines: [VatLine]

    /// Date of supply, which German law requires separately from the document
    /// date and which is the particular most often left off.
    public let supplyDate: String

    /// The document this one refers to — the original invoice for a credit
    /// note, or the overdue invoice for a reminder.
    public let reference: String

    /// Print the German wording as well as the English.
    public let germanNotes: Bool

    public init(
        kind: DocumentKind = .invoice,
        branding: Branding,
        number: String,
        from: Party,
        to: Party,
        items: [LineItem],
        totals: [(label: String, value: String)] = [],
        total: [(label: String, value: String)] = [],
        details: [(label: String, value: String)] = [],
        notes: String = "",
        status: String = "",
        size: PageSize = .a4,
        vat: VatTreatment = .standard,
        vatLines: [VatLine] = [],
        supplyDate: String = "",
        reference: String = "",
        germanNotes: Bool = false
    ) {
        self.kind = kind
        self.branding = branding
        self.number = number
        self.from = from
        self.to = to
        self.items = items
        self.totals = totals
        self.total = total
        self.details = details
        self.notes = notes
        self.status = status
        self.size = size
        self.vat = vat
        self.vatLines = vatLines
        self.supplyDate = supplyDate
        self.reference = reference
        self.germanNotes = germanNotes
    }

    // MARK: Compliance

    /// Mandatory particulars that are missing.
    ///
    /// Checks against the fields §14 UStG and Article 226 of the VAT Directive
    /// require. A document missing any of them can be refused as evidence for
    /// the recipient's input-tax deduction — which makes it their problem and
    /// your support ticket.
    ///
    /// Not tax advice, and not exhaustive: it verifies the particulars this
    /// template can see, not whether the treatment chosen is correct.
    public func complianceWarnings() -> [String] {
        guard kind.isTaxDocument else { return [] }

        var missing: [String] = []

        if from.taxID.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("The supplier VAT or tax number is missing.")
        }
        if from.address.isEmpty {
            missing.append("The supplier address is missing.")
        }
        if to.address.isEmpty {
            missing.append("The customer address is missing.")
        }
        if number.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("A sequential document number is required.")
        }
        if supplyDate.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("The date of supply is required, separately from the document date.")
        }
        if vat.requiresBothVatNumbers, to.taxID.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("The customer VAT number is required for this VAT treatment.")
        }
        // A self-billed invoice carries both numbers whatever the treatment —
        // the supplier's is what makes it their invoice.
        if kind == .selfBilling, to.taxID.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("A self-billed invoice must show the supplier's VAT number.")
        }
        if kind == .creditNote, reference.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("A credit note must reference the invoice it reverses.")
        }
        if kind == .debitNote, reference.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("A debit note must reference the document it adjusts.")
        }
        if vatLines.count > 1 { return missing }

        if vat == .standard, vatLines.isEmpty, totals.isEmpty {
            missing.append("The taxable amount and VAT must be shown per rate.")
        }
        return missing
    }

    // MARK: Rendering

    /// Lays the document out.
    public func render() -> Document {
        let pdf = Document(size: size, orientation: .portrait, margin: 48, fontSize: 9.5, leading: 13)

        masthead(pdf)
        parties(pdf)
        itemTable(pdf)
        vatBreakdown(pdf)
        totalsBlock(pdf)
        vatNotes(pdf)
        paymentNotes(pdf)

        let brand = branding
        pdf.onEachPage { doc, page, total in
            if !brand.footnotes.isEmpty {
                doc.line(from: doc.left(), 58, to: doc.right(), 58, color: brand.hairline)
                var y = 46.0
                for note in brand.footnotes {
                    doc.textAt(note, x: doc.left(), y: y, size: 7.5, font: .helvetica, color: .grey(150))
                    y -= 10
                }
            }
            if total > 1 {
                doc.textAt(
                    "Page \(page) of \(total)",
                    x: doc.left(), y: 46, size: 7.5, font: .helvetica,
                    color: .grey(150), align: .right, boxWidth: doc.contentWidth()
                )
            }
        }
        return pdf
    }

    /// Renders and writes to a file.
    @discardableResult
    public func save(to url: URL) throws -> Int {
        try render().save(to: url, metadata: [
            "Title": "\(kind.title) \(number)",
            "Author": from.name,
            "Subject": "\(kind.title) for \(to.name)",
        ])
    }

    // MARK: Sections

    private func masthead(_ pdf: Document) {
        let top = pdf.height() - 48
        var x = pdf.left()

        if let logoPath = branding.logoPath, !logoPath.isEmpty {
            pdf.svgPath(
                logoPath, x: x, y: top - 34,
                scale: 34 / branding.logoBox,
                color: branding.accentColor,
                svgHeight: branding.logoBox
            )
            x += 46
        }

        pdf.textAt(branding.name.uppercased(), x: x, y: top - 14, size: 15,
                   font: .helveticaBold, color: branding.accentColor)

        if !branding.tagline.isEmpty {
            pdf.textAt(branding.tagline, x: x, y: top - 27, size: 8, font: .helvetica, color: branding.muted)
        }

        // Title, reference and status stack down the right edge. Each needs
        // its own band — overlaying them puts the stamp across the reference
        // number, which is the one thing a customer has to quote back.
        pdf.textAt(kind.title, x: pdf.left(), y: top - 20, size: 26,
                   font: .helveticaBold, color: branding.ink, align: .right, boxWidth: pdf.contentWidth())
        pdf.textAt(number, x: pdf.left(), y: top - 36, size: 9.5,
                   font: .helvetica, color: branding.muted, align: .right, boxWidth: pdf.contentWidth())

        var ruleY = top - 66
        if !status.isEmpty {
            stamp(pdf, y: top - 58)
            ruleY = top - 78
        }

        pdf.move(to: ruleY)
        pdf.line(from: pdf.left(), pdf.cursor(), to: pdf.right(), pdf.cursor(), color: branding.ink, thickness: 0.75)
        pdf.move(to: pdf.cursor() - 28)
    }

    /// An outlined status stamp.
    ///
    /// Outlined rather than filled: reversed-out white text on a light accent
    /// is unreadable, and on a mono palette it disappears entirely.
    private func stamp(_ pdf: Document, y: Double) {
        let label = status.uppercased()
        let width = Font.helveticaBold.widthOf(label, size: 8) + 22
        let height = 16.0
        let left = pdf.right() - width
        let bottom = y - 4

        pdf.line(from: left, bottom, to: left + width, bottom, color: branding.ink, thickness: 0.75)
        pdf.line(from: left, bottom + height, to: left + width, bottom + height, color: branding.ink, thickness: 0.75)
        pdf.line(from: left, bottom, to: left, bottom + height, color: branding.ink, thickness: 0.75)
        pdf.line(from: left + width, bottom, to: left + width, bottom + height, color: branding.ink, thickness: 0.75)

        pdf.textAt(
            label, x: left,
            y: bottom + ((height - Font.helveticaBold.capHeight(8)) / 2),
            size: 8, font: .helveticaBold, color: branding.ink,
            align: .center, boxWidth: width
        )
    }

    private func parties(_ pdf: Document) {
        let top = pdf.cursor()
        let column = pdf.contentWidth() / 2

        let heading: String
        switch kind {
        case .remittance: heading = "PAID TO"
        case .selfBilling, .purchaseOrder: heading = "SUPPLIER"
        case .deliveryNote: heading = "DELIVER TO"
        default: heading = "BILLED TO"
        }
        pdf.textAt(heading, x: pdf.left(), y: top, size: 7, font: .helveticaBold, color: branding.muted)
        pdf.textAt(to.name, x: pdf.left(), y: top - 16, size: 11, font: .helveticaBold, color: branding.ink)

        var y = top - 29
        for line in to.lines() {
            pdf.textAt(line, x: pdf.left(), y: y, size: 9, font: .helvetica, color: branding.muted)
            y -= 11.5
        }

        let detailX = pdf.left() + column + 20
        let detailWidth = column - 20

        // The supply date is a mandatory particular in its own right and the
        // one most often left off, so it is added rather than relying on the
        // caller to remember it.
        var rows = details
        if !supplyDate.isEmpty, !rows.contains(where: { $0.label == "Date of supply" }) {
            rows.append((label: "Date of supply", value: supplyDate))
        }
        if !reference.isEmpty, !rows.contains(where: { $0.label.lowercased().contains("reference") }) {
            rows.append((label: kind == .creditNote ? "Original invoice" : "Reference", value: reference))
        }

        if !rows.isEmpty {
            pdf.textAt("DETAILS", x: detailX, y: top, size: 7, font: .helveticaBold, color: branding.muted)
            var detailY = top - 16
            for row in rows {
                pdf.textAt(row.label, x: detailX, y: detailY, size: 9, font: .helvetica, color: branding.muted)
                pdf.textAt(row.value, x: detailX, y: detailY, size: 9, font: .helveticaBold,
                           color: branding.ink, align: .right, boxWidth: detailWidth)
                detailY -= 13
            }
            y = min(y, detailY)
        }
        pdf.move(to: y - 18)
    }

    private func itemTable(_ pdf: Document) {
        guard !items.isEmpty else { return }

        guard kind.showsMoney else {
            let table = Table(headers: ["Description", "Qty"])
            table.widths([0.85, 0.15]).align([1: .center]).rowHeight(22)
            for item in items {
                let description = item.note.isEmpty ? item.description : "\(item.description)   \(item.note)"
                table.row([description, item.quantity])
            }
            table.draw(pdf, size: 9, headerFill: branding.wash)
            return
        }

        let hasUnit = items.contains { !$0.unitPrice.isEmpty }

        let headers = hasUnit
            ? ["Description", "Qty", "Unit price", "Amount"]
            : ["Description", "Qty", "Amount"]

        let table = Table(headers: headers)
        table.widths(hasUnit ? [0.50, 0.10, 0.20, 0.20] : [0.66, 0.14, 0.20])
            .align(hasUnit ? [1: .center, 2: .right, 3: .right] : [1: .center, 2: .right])
            .rowHeight(22)

        for item in items {
            let description = item.note.isEmpty ? item.description : "\(item.description)   \(item.note)"
            table.row(hasUnit
                ? [description, item.quantity, item.unitPrice, item.amount]
                : [description, item.quantity, item.amount])
        }
        table.draw(pdf, size: 9, headerFill: branding.wash)
    }

    /// Whether the per-rate breakdown earns its place on the page.
    ///
    /// It exists because §14 UStG and Article 226 require the taxable amount
    /// shown against each rate when rates are *mixed*. With a single standard
    /// rate it repeats the totals block verbatim — the same two figures, in a
    /// column that lines up with nothing — so it is omitted.
    ///
    /// A non-standard treatment keeps it even at one rate: the row is what
    /// evidences the zero rating.
    var showsVatBreakdown: Bool {
        guard !vatLines.isEmpty else { return false }
        return vatLines.count > 1 || vat != .standard
    }

    private func vatBreakdown(_ pdf: Document) {
        guard showsVatBreakdown else { return }

        pdf.gap(18)
        pdf.breakIfNeeded(90)

        let width = pdf.contentWidth() * 0.55
        pdf.cell("VAT BREAKDOWN", x: pdf.left(), boxWidth: width, size: 7,
                 font: .helveticaBold, color: branding.muted)
        pdf.gap(14)

        let table = Table(headers: ["Rate", "Net", "VAT"])
        table.widths([0.4, 0.3, 0.3]).align([1: .right, 2: .right]).rowHeight(18)

        for line in vatLines {
            let rate = line.label.isEmpty ? line.rate : "\(line.label) (\(line.rate))"
            table.row([rate, line.net, line.vat])
        }

        let saved = pdf.cursor()
        table.draw(pdf, size: 8.5, headerFill: branding.wash)
        pdf.move(to: min(pdf.cursor(), saved))
    }

    private func totalsBlock(_ pdf: Document) {
        guard kind.showsMoney else {
            if let standing = kind.standingNote {
                pdf.gap(20)
                pdf.cell(standing, x: pdf.left(), boxWidth: pdf.contentWidth(), size: 8.5,
                         font: .helvetica, color: branding.muted)
                pdf.gap(12)
            }
            return
        }

        let width = pdf.contentWidth() * 0.42
        let x = pdf.right() - width

        pdf.gap(14)

        for row in totals {
            pdf.breakIfNeeded(60)
            pdf.cell(row.label, x: x, boxWidth: width, size: 9, font: .helvetica, color: branding.muted)
            pdf.cell(row.value, x: x, boxWidth: width, size: 9, font: .helvetica, color: branding.ink, align: .right)
            pdf.gap(15)
        }

        guard !total.isEmpty else { return }

        // A rule and a change of weight, rather than a filled block. It reads
        // as clearly, prints the same on any device, and cannot look subtly
        // wrong the way a band of colour with text in it can.
        pdf.gap(6)
        pdf.line(from: x, pdf.cursor(), to: pdf.right(), pdf.cursor(), color: branding.ink, thickness: 1)
        pdf.gap(20)

        for row in total {
            let baseline = pdf.cursor()
            pdf.textAt(row.label, x: x, y: baseline, size: 11, font: .helveticaBold, color: branding.ink)
            pdf.textAt(row.value, x: x, y: baseline, size: 14, font: .helveticaBold,
                       color: branding.ink, align: .right, boxWidth: width)
            pdf.gap(12)
            pdf.line(from: x, pdf.cursor(), to: pdf.right(), pdf.cursor(), color: branding.hairline, thickness: 0.5)
            pdf.gap(14)
        }

        if let standing = kind.standingNote {
            pdf.gap(4)
            pdf.cell(standing, x: pdf.left(), boxWidth: pdf.contentWidth(), size: 8.5,
                     font: .helvetica, color: branding.muted)
            pdf.gap(12)
        }
    }

    /// The mandatory VAT wording, printed prominently rather than buried,
    /// because its absence is what invalidates the recipient's deduction.
    private func vatNotes(_ pdf: Document) {
        let notes = vat.notes(german: germanNotes)
        guard !notes.isEmpty else { return }

        let height = 20 + (12 * Double(notes.count))

        pdf.gap(24)
        pdf.breakIfNeeded(height + 20)

        let top = pdf.cursor() + 14
        let bottom = pdf.cursor() - height + 14

        pdf.line(from: pdf.left(), top, to: pdf.right(), top, color: branding.hairline, thickness: 0.5)
        pdf.line(from: pdf.left(), bottom, to: pdf.right(), bottom, color: branding.hairline, thickness: 0.5)

        // A heavier stub on the left edge draws the eye without needing
        // colour, which matters because this is the wording that makes the
        // document valid for the recipient's deduction.
        pdf.line(from: pdf.left(), top, to: pdf.left(), bottom, color: branding.ink, thickness: 2)
        pdf.gap(2)

        for (index, note) in notes.enumerated() {
            pdf.cell(note, x: pdf.left() + 14, boxWidth: pdf.contentWidth() - 28, size: 8.5,
                     font: index == 0 ? .helveticaBold : .helvetica, color: branding.ink)
            pdf.gap(12)
        }
    }

    private func paymentNotes(_ pdf: Document) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pdf.gap(26)
        pdf.breakIfNeeded(70)

        pdf.line(from: pdf.left(), pdf.cursor() + 12, to: pdf.right(), pdf.cursor() + 12,
                 color: branding.hairline, thickness: 0.5)
        pdf.gap(6)
        let notesHeading: String
        switch kind {
        case .quote: notesHeading = "TERMS"
        case .remittance: notesHeading = "PAYMENT DETAILS"
        default: notesHeading = "PAYMENT"
        }
        pdf.cell(notesHeading, x: pdf.left(), boxWidth: 200, size: 7,
                 font: .helveticaBold, color: branding.muted)
        pdf.gap(14)

        for line in trimmed.components(separatedBy: "\n") {
            pdf.cell(line, x: pdf.left(), boxWidth: pdf.contentWidth(), size: 8.5,
                     font: .helvetica, color: branding.ink)
            pdf.gap(12)
        }
    }
}
