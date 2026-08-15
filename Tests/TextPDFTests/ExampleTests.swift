//
//  ExampleTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The examples in the repository, written by the library that makes them.
//
//  A business document is a thing you look at. Twelve kind names in a table
//  tell somebody nothing about whether a credit note from this looks like one,
//  so every kind and every template is committed as a PDF they can open before
//  installing anything.
//
//  Generated rather than curated, so none of them can go stale quietly:
//
//      WRITE_EXAMPLES=1 swift test --filter ExampleTests
//
//  The creation date is pinned, because a PDF carries one and regenerating
//  would otherwise rewrite every file whether or not its content changed.
//

import PDFKit
import XCTest
@testable import TextPDF

final class ExampleTests: XCTestCase {

    private static let stamped = Date(timeIntervalSince1970: 1_776_000_000)

    private var writing: Bool { ProcessInfo.processInfo.environment["WRITE_EXAMPLES"] == "1" }

    private var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TextPDFTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the package
            .appendingPathComponent("Examples", isDirectory: true)
    }

    private func put(_ document: Document, _ name: String) throws {
        let data = document.render(creationDate: Self.stamped)

        // Rendered either way: doing this in a test means every example is
        // proved to render on every run, not only when it is written out.
        XCTAssertNotNil(PDFDocument(data: data), "\(name) is not a readable PDF")
        XCTAssertGreaterThan(data.count, 1_500, "\(name) came out suspiciously small")

        guard writing else { return }
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file)
    }

    // MARK: The parties

    private static let branding = Branding(
        name: "Sugarcart Ltd",
        tagline: "Sample libraries and sound design",
        accent: "#1F3A5F",
        address: ["71–75 Shelton Street", "London WC2H 9JQ", "United Kingdom"],
        footnotes: ["Sugarcart Ltd is registered in England and Wales, no. 09182736."]
    )

    private static let supplier = Party(
        name: "Sugarcart Ltd",
        address: ["71–75 Shelton Street", "London WC2H 9JQ"],
        email: "accounts@sugarcart.co.uk",
        taxID: "GB 123 4567 89"
    )

    private static let customer = Party(
        name: "Acme Recordings Ltd",
        address: ["Studio 4, 118 Brick Lane", "London E1 6RL"],
        email: "payables@acmerecordings.com",
        taxID: "GB 987 6543 21"
    )

    private static let germanCustomer = Party(
        name: "Klangwerk Studios GmbH",
        address: ["Oranienburger Strasse 87", "10178 Berlin", "Deutschland"],
        email: "buchhaltung@klangwerk.de",
        taxID: "DE 811 5678 90"
    )

    private static let items = [
        LineItem(description: "Drum Kit Vol. 2 — sample library licence",
                 amount: "£149.00", quantity: "1", unitPrice: "£149.00"),
        LineItem(description: "Bespoke foley session", amount: "£420.00",
                 quantity: "6", unitPrice: "£70.00", note: "Studio B, 12–13 July"),
        LineItem(description: "Stem delivery and mastering", amount: "£180.00",
                 quantity: "1", unitPrice: "£180.00"),
    ]

    // MARK: Invoices

    func testEveryDocumentKind() throws {
        for kind in DocumentKind.allCases {
            // A delivery note lists what was sent, not what it cost — so it
            // is given no money to print. Supplying a total a document does
            // not carry is how an example ends up failing its own check.
            let priced = kind != .deliveryNote

            let invoice = Invoice(
                kind: kind,
                branding: Self.branding,
                number: "\(kind.reference)-2026-0042",
                from: Self.supplier,
                to: Self.customer,
                items: Self.items,
                totals: priced ? [("Subtotal", "£749.00"), ("VAT at 20%", "£149.80")] : [],
                total: priced ? [("Total due", "£898.80")] : [],
                details: [("Issued", "31 July 2026"), ("Due", "30 August 2026"),
                          ("Terms", "30 days net")],
                notes: kind.sampleNote,
                vatLines: priced ? [VatLine(rate: "20%", net: "£749.00", vat: "£149.80")] : [],
                supplyDate: "31 July 2026",
                reference: "PO-4471"
            )
            let document = invoice.render()
            // An example nobody could legally send is not an example. The
            // checker reads the finished page, so this also proves the wording
            // reached it rather than merely being set on the model.
            XCTAssertEqual(
                invoice.complianceWarnings(verifying: document), [],
                "the \(kind.rawValue) example would not pass its own compliance check"
            )
            try put(document, "invoices/\(kind.rawValue).pdf")
        }
    }

    func testTheVatTreatments() throws {
        // The wording is the document. A reverse-charge invoice without the
        // words on it can be refused as evidence for the recipient's deduction.
        let treatments: [(String, VatTreatment, Party)] = [
            ("reverse-charge", .reverseCharge, Self.germanCustomer),
            ("intra-community", .intraCommunitySupply, Self.germanCustomer),
            ("export", .export, Party(name: "Northwind Audio Inc.",
                                      address: ["1200 Market Street", "San Francisco, CA 94103", "USA"],
                                      email: "ap@northwindaudio.com")),
            ("small-business", .smallBusiness, Self.customer),
        ]

        for (name, treatment, customer) in treatments {
            let invoice = Invoice(
                branding: Self.branding,
                number: "INV-2026-0043",
                from: Self.supplier,
                to: customer,
                items: Self.items,
                totals: [("Subtotal", "£749.00")],
                total: [("Total due", "£749.00")],
                details: [("Issued", "31 July 2026"), ("Due", "30 August 2026")],
                vat: treatment,
                supplyDate: "31 July 2026",
                germanNotes: name != "export"
            )
            let document = invoice.render()
            XCTAssertEqual(
                invoice.complianceWarnings(verifying: document), [],
                "the \(name) example would not pass its own compliance check"
            )
            try put(document, "invoices/vat-\(name).pdf")
        }
    }

    // MARK: The other documents

    func testAStatement() throws {
        let statement = Statement(
            branding: Self.branding,
            account: Self.customer,
            period: "1 July – 31 July 2026",
            transactions: [
                Transaction(date: "1 Jul 2026", description: "Balance brought forward",
                            balance: "£1,240.00"),
                Transaction(date: "8 Jul 2026", reference: "INV-2026-0038",
                            description: "Invoice", charge: "£898.80", balance: "£2,138.80"),
                Transaction(date: "19 Jul 2026", reference: "REC-2026-0031",
                            description: "Payment received, thank you",
                            credit: "£1,240.00", balance: "£898.80"),
                Transaction(date: "24 Jul 2026", reference: "CRN-2026-0004",
                            description: "Credit note", credit: "£180.00", balance: "£718.80"),
            ],
            summary: [("Opening balance", "£1,240.00"), ("Invoiced", "£898.80"),
                      ("Received", "£1,420.00")],
            closing: [("Closing balance", "£718.80")],
            ageing: [("Current", "£718.80"), ("31–60 days", "£0.00"), ("61–90 days", "£0.00")],
            reference: "STMT-2026-07"
        )
        try put(statement.render(), "statements/statement.pdf")
    }

    func testATimesheet() throws {
        let timesheet = Timesheet(
            branding: Self.branding,
            worker: Party(name: "Alex Moreau", email: "alex@moreau.dev"),
            client: Self.customer,
            period: "1 – 15 July 2026",
            reference: "TS-2026-14",
            entries: [
                TimeEntry(date: "1 Jul", project: "Foley", description: "Session prep and mic setup",
                          hours: "3.5", rate: "£70.00", amount: "£245.00"),
                TimeEntry(date: "2 Jul", project: "Foley", description: "Recording, studio B",
                          hours: "8.0", rate: "£70.00", amount: "£560.00"),
                TimeEntry(date: "5 Jul", project: "Mastering", description: "Stem cleanup",
                          hours: "4.0", rate: "£85.00", amount: "£340.00"),
                TimeEntry(date: "8 Jul", project: "Admin", description: "Delivery call",
                          hours: "0.5", nonBillable: true),
            ],
            byProject: [("Foley", "£805.00"), ("Mastering", "£340.00")],
            totals: [("Billable hours", "15.5"), ("Total", "£1,145.00")],
            signatories: ["Alex Moreau", "For Acme Recordings Ltd"]
        )
        try put(timesheet.render(), "statements/timesheet.pdf")
    }

    func testARoyaltyStatement() throws {
        let royalty = RoyaltyStatement(
            branding: Self.branding,
            payee: Party(name: "Mira Okafor", address: ["44 Bath Road", "Bristol BS3 3PB"],
                         email: "mira@okafor.audio"),
            period: "Q2 2026",
            reference: "ROY-2026-Q2",
            agreement: "Publishing agreement dated 4 March 2024",
            lines: [
                RoyaltyLine(source: "Streaming", title: "Nightshift EP", quantity: "1,204,882",
                            gross: "£4,812.00", distributorShare: "£1,443.60",
                            net: "£3,368.40", rate: "15%", earned: "£505.26"),
                RoyaltyLine(source: "Sync", title: "Nightshift (instrumental)", quantity: "2",
                            gross: "£6,000.00", net: "£6,000.00", rate: "50%", earned: "£3,000.00"),
                RoyaltyLine(source: "Downloads", title: "Nightshift EP", quantity: "318",
                            gross: "£2,226.00", distributorShare: "£667.80",
                            net: "£1,558.20", rate: "15%", earned: "£233.73"),
            ],
            bySource: [("Streaming", "£505.26"), ("Sync", "£3,000.00"), ("Downloads", "£233.73")],
            reconciliation: [("Earned this period", "£3,738.99"),
                             ("Unrecouped advance brought forward", "-£2,500.00")],
            payable: [("Payable", "£1,238.99")],
            carriedForwardNote: "The advance is now fully recouped."
        )
        try put(royalty.render(), "statements/royalty.pdf")
    }

    func testAnAgedAnalysis() throws {
        for kind in AgedLedger.allCases {
            let aged = AgedAnalysis(
                branding: Self.branding,
                kind: kind,
                asAt: "31 July 2026",
                buckets: ["Current", "31–60", "61–90", "90+"],
                rows: [
                    DebtorRow(account: "Acme Recordings Ltd", reference: "ACME",
                              amounts: ["£898.80", "£0.00", "£0.00", "£0.00"], total: "£898.80"),
                    DebtorRow(account: "Klangwerk Studios GmbH", reference: "KLANG",
                              amounts: ["£0.00", "£1,420.00", "£0.00", "£0.00"], total: "£1,420.00"),
                    DebtorRow(account: "Northwind Audio Inc.", reference: "NWA",
                              amounts: ["£0.00", "£0.00", "£0.00", "£2,310.00"],
                              total: "£2,310.00", flagged: true),
                ],
                totals: ["£898.80", "£1,420.00", "£0.00", "£2,310.00"],
                highlights: [("Total outstanding", "£4,628.80"), ("Over 90 days", "£2,310.00")],
                notes: "Northwind has been referred for collection."
            )
            try put(aged.render(), "statements/aged-\(kind.rawValue).pdf")
        }
    }

    func testTheShippingDocuments() throws {
        for kind in ShippingDocument.allCases {
            let shipping = Consignment(
                branding: Self.branding,
                kind: kind,
                number: "EXP-2026-0117",
                date: "31 July 2026",
                exporter: Self.supplier,
                consignee: Party(name: "Northwind Audio Inc.",
                                 address: ["1200 Market Street", "San Francisco, CA 94103", "USA"],
                                 email: "receiving@northwindaudio.com"),
                details: [("Airway bill", "125-44718820"), ("Carrier", "DHL Express")],
                items: [
                    ConsignmentItem(description: "Studio monitor pair", commodityCode: "8518 22 00",
                                    countryOfOrigin: "GB", quantity: "2", netWeight: "18.4 kg",
                                    grossWeight: "21.0 kg", unitPrice: "£980.00",
                                    amount: "£1,960.00", package: "1 of 2"),
                    ConsignmentItem(description: "Microphone, condenser", commodityCode: "8518 10 30",
                                    countryOfOrigin: "GB", quantity: "4", netWeight: "2.1 kg",
                                    grossWeight: "3.4 kg", unitPrice: "£310.00",
                                    amount: "£1,240.00", package: "2 of 2"),
                ],
                incoterm: "DAP San Francisco (Incoterms 2020)",
                countryOfExport: "United Kingdom",
                countryOfDestination: "United States",
                reasonForExport: "Sale",
                totals: [("Net weight", "20.5 kg"), ("Gross weight", "24.4 kg"), ("Packages", "2")],
                value: [("Total value", "£3,200.00")],
                notes: "No commercial value declared for customs purposes other than as stated."
            )
            try put(shipping.render(), "shipping/\(kind.rawValue).pdf")
        }
    }

    // MARK: The look

    func testTheSameInvoiceUnderDifferentBranding() throws {
        let looks: [(String, Branding)] = [
            ("plain", Branding(name: "Sugarcart Ltd", address: Self.branding.address)),
            ("navy", Self.branding),
            ("warm", Branding(name: "Sugarcart Ltd", tagline: "Sample libraries and sound design",
                              accent: "#7A4A2B", address: Self.branding.address)),
        ]

        for (name, branding) in looks {
            let invoice = Invoice(
                branding: branding,
                number: "INV-2026-0042",
                from: Self.supplier,
                to: Self.customer,
                items: Self.items,
                totals: [("Subtotal", "£749.00"), ("VAT at 20%", "£149.80")],
                total: [("Total due", "£898.80")],
                details: [("Issued", "31 July 2026"), ("Due", "30 August 2026")],
                vatLines: [VatLine(rate: "20%", net: "£749.00", vat: "£149.80")],
                supplyDate: "31 July 2026"
            )
            try put(invoice.render(), "branding/\(name).pdf")
        }
    }
}

// MARK: - Wording per kind

private extension DocumentKind {

    /// A short reference prefix, so the examples do not all say INV.
    var reference: String {
        switch self {
        case .invoice: return "INV"
        case .creditNote: return "CRN"
        case .debitNote: return "DBN"
        case .quote: return "QTE"
        case .proforma: return "PRO"
        case .receipt: return "REC"
        case .reminder: return "REM"
        case .remittance: return "RMT"
        case .selfBilling: return "SBI"
        case .deliveryNote: return "DEL"
        case .purchaseOrder: return "PO"
        case .orderConfirmation: return "ORD"
        }
    }

    /// What somebody would actually write on one of these.
    var sampleNote: String {
        switch self {
        case .invoice: return "Payment by bank transfer to the account on file, quoting the invoice number."
        case .creditNote: return "Issued against invoice INV-2026-0038 of 8 July 2026."
        case .debitNote: return "Raised against invoice INV-2026-0038 for undercharged studio time."
        case .quote: return "Valid for 30 days from the date of issue."
        case .proforma: return "Not a VAT invoice. A tax invoice follows on payment."
        case .receipt: return "Received with thanks. No further payment is due."
        case .reminder: return "Our records show this remains unpaid. Please disregard if payment has crossed with this notice."
        case .remittance: return "Sent by bank transfer on 30 July 2026."
        case .selfBilling: return "Self-billing. Raised by the customer under a self-billing agreement dated 4 March 2024."
        case .deliveryNote: return "Please check the consignment on receipt and report shortages within three working days."
        case .purchaseOrder: return "Quote this order number on all correspondence and invoices."
        case .orderConfirmation: return "Thank you for your order. Delivery is scheduled for 7 August 2026."
        }
    }
}
