//
//  TemplateTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import XCTest
@testable import TextPDF

/// The documents added alongside the invoice and the statement.
///
/// These check the things that make each document the document it is — a
/// packing list without prices, a customs line that keeps its country of
/// origin — rather than that a PDF came out at all.
final class TemplateTests: XCTestCase {

    private let brand = Branding(name: "ArrayPress", accent: "#0f766e")

    /// The file as text.
    ///
    /// Decoded as Latin-1, which is what the writer encodes: `£` is one byte
    /// there and not valid UTF-8 on its own, so decoding it as UTF-8 replaces
    /// it and nothing containing a currency symbol can be found.
    private func text(of document: Document) -> String {
        String(data: document.render(), encoding: .isoLatin1) ?? ""
    }

    // MARK: Wrapped blocks

    func testLongTextWrapsRatherThanRunningOffThePage() {
        let pdf = Document(size: .a4, margin: 48)
        let sentence = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)

        let height = pdf.block(sentence, x: pdf.left(), width: 200, size: 9, leading: 12)

        // A single line would be 12 points; this has to have wrapped.
        XCTAssertGreaterThan(height, 12 * 5)
        XCTAssertEqual(height, pdf.blockHeight(sentence, size: 9, width: 200, leading: 12), accuracy: 0.01)
    }

    func testBlockRespectsExplicitLineBreaks() {
        let pdf = Document(size: .a4, margin: 48)
        let two = pdf.blockHeight("one\ntwo", size: 9, width: 400, leading: 12)
        let one = pdf.blockHeight("one", size: 9, width: 400, leading: 12)
        XCTAssertEqual(two, one * 2, accuracy: 0.01)
    }

    func testBlockAdvancesTheCursorByWhatItDrew() {
        let pdf = Document(size: .a4, margin: 48)
        let before = pdf.cursor()
        let height = pdf.block("A short line", x: pdf.left(), width: 400, size: 9, leading: 12)
        XCTAssertEqual(pdf.cursor(), before - height, accuracy: 0.01)
    }

    // MARK: Tables

    func testTotalRowIsDrawnWithTheSameColumns() {
        let pdf = Document(size: .a4, margin: 48)
        let table = Table(headers: ["Account", "Current", "Total"])
        table.widths([0.5, 0.25, 0.25]).align([1: .right, 2: .right])
        table.row(["Northwind", "£100.00", "£100.00"])
        table.total(["Total", "£100.00", "£100.00"])
        table.draw(pdf, size: 9)

        let rendered = text(of: pdf)
        XCTAssertTrue(rendered.contains("(Total) Tj"))
        // Two occurrences of the figure: the row and the total beneath it.
        XCTAssertEqual(rendered.components(separatedBy: "(\u{A3}100.00) Tj").count - 1, 4)
    }

    // MARK: Timesheet

    func testTimesheetDropsMoneyColumnsWhenNothingIsCharged() {
        let internalSheet = Timesheet(
            branding: brand,
            worker: Party(name: "Daniel Okafor"),
            period: "July 2026",
            entries: [TimeEntry(date: "02 Jul", description: "Library maintenance", hours: "4.0", nonBillable: true)]
        )
        let rendered = text(of: internalSheet.render())

        // Empty rate and amount columns on an internal sheet invite someone to
        // fill them in, so they are not drawn at all.
        XCTAssertFalse(rendered.contains("(Rate) Tj"))
        XCTAssertFalse(rendered.contains("(Amount) Tj"))
        XCTAssertTrue(rendered.contains("(Hours) Tj"))
    }

    func testTimesheetKeepsMoneyColumnsWhenTimeIsCharged() {
        let billed = Timesheet(
            branding: brand,
            worker: Party(name: "Daniel Okafor"),
            period: "July 2026",
            entries: [TimeEntry(date: "02 Jul", description: "Foley", hours: "6.5", rate: "£65.00", amount: "£422.50")]
        )
        let rendered = text(of: billed.render())
        XCTAssertTrue(rendered.contains("(Rate) Tj"))
        XCTAssertTrue(rendered.contains("(Amount) Tj"))
    }

    func testNonBillableTimeIsMarkedInTheTextNotOnlyByColour() {
        let sheet = Timesheet(
            branding: brand,
            worker: Party(name: "Daniel Okafor"),
            period: "July 2026",
            entries: [TimeEntry(date: "02 Jul", description: "Library maintenance", hours: "4.0", nonBillable: true)]
        )
        // It has to survive a photocopy.
        XCTAssertTrue(text(of: sheet.render()).contains("non-billable"))
    }

    // MARK: Royalty statement

    func testRoyaltyStatementDropsColumnsNobodyFilledIn() {
        let commission = RoyaltyStatement(
            branding: brand,
            payee: Party(name: "Mireille Fontaine"),
            period: "July 2026",
            lines: [RoyaltyLine(source: "Direct", title: "Tape Textures", net: "£143.00", earned: "£100.10")]
        )
        let rendered = text(of: commission.render())
        XCTAssertFalse(rendered.contains("(Gross) Tj"))
        XCTAssertFalse(rendered.contains("(Distributor) Tj"))
        XCTAssertTrue(rendered.contains("(Earnings) Tj"))
    }

    func testRoyaltyStatementShowsTheWholeChainWhenGiven() {
        let full = RoyaltyStatement(
            branding: brand,
            payee: Party(name: "Mireille Fontaine"),
            period: "July 2026",
            lines: [
                RoyaltyLine(source: "Splice", title: "Analogue Drift", quantity: "1,284",
                            gross: "£3,210.00", distributorShare: "£1,605.00",
                            net: "£1,605.00", rate: "50%", earned: "£802.50"),
            ]
        )
        let rendered = text(of: full.render())
        for column in ["Gross", "Distributor", "Net", "Share", "Earnings", "Units"] {
            XCTAssertTrue(rendered.contains("(\(column)) Tj"), "missing the \(column) column")
        }
    }

    func testCarriedForwardReasonIsPrintedOnTheDocument() {
        let unrecouped = RoyaltyStatement(
            branding: brand,
            payee: Party(name: "Mireille Fontaine"),
            period: "July 2026",
            lines: [RoyaltyLine(source: "Splice", title: "Analogue Drift", net: "£100.00", earned: "£50.00")],
            payable: [("Payable this period", "£0.00")],
            carriedForwardNote: "The advance is not yet recouped. An unrecouped balance is not a debt."
        )
        // Earnings but no payment reads as a withholding unless the document
        // says otherwise, so the reason cannot live in a covering email.
        XCTAssertTrue(text(of: unrecouped.render()).contains("not yet recouped"))
    }

    // MARK: Aged debtors

    func testShortDebtorRowIsPaddedRatherThanShiftingColumns() {
        let report = AgedDebtors(
            branding: brand,
            asAt: "31 July 2026",
            buckets: ["Current", "31–60", "61–90", "90+"],
            rows: [DebtorRow(account: "Northwind", amounts: ["£100.00"], total: "£100.00")]
        )
        let rendered = text(of: report.render())

        // With only one amount given, the figure must stay under Current and
        // the total under Total — not slide left into the wrong bucket.
        XCTAssertTrue(rendered.contains("(Northwind) Tj"))
        XCTAssertEqual(rendered.components(separatedBy: "(\u{A3}100.00) Tj").count - 1, 2)
    }

    func testOverlongDebtorRowIsCutToTheBuckets() {
        let report = AgedDebtors(
            branding: brand,
            asAt: "31 July 2026",
            buckets: ["Current", "90+"],
            rows: [DebtorRow(account: "Northwind", amounts: ["£1.00", "£2.00", "£3.00", "£4.00"], total: "£10.00")]
        )
        let rendered = text(of: report.render())
        XCTAssertFalse(rendered.contains("(\u{A3}4.00) Tj"), "a figure with no column should not be drawn")
    }

    // MARK: Consignments

    private var goods: [ConsignmentItem] {
        [ConsignmentItem(
            description: "Field recorder",
            commodityCode: "8519.81",
            countryOfOrigin: "Japan",
            quantity: "4 pcs",
            netWeight: "3.2 kg",
            grossWeight: "4.6 kg",
            unitPrice: "£880.00",
            amount: "£3,520.00",
            package: "1 of 3"
        )]
    }

    func testPackingListCarriesNoPrices() {
        let list = Consignment(
            branding: brand, kind: .packingList, number: "PL-1", date: "11 August 2026",
            exporter: Party(name: "ArrayPress Ltd", address: ["London"]),
            consignee: Party(name: "Kestrel GmbH", address: ["Frankfurt"]),
            items: goods,
            value: [("Total value", "£3,520.00")]
        )
        let rendered = text(of: list.render())

        // Not a formatting choice: the list is handled by people who should
        // not be reading the seller's prices.
        XCTAssertFalse(rendered.contains("3,520.00"))
        XCTAssertFalse(rendered.contains("(Amount) Tj"))
        XCTAssertTrue(rendered.contains("(Gross) Tj"))
    }

    func testCommercialInvoiceCarriesPricesAndTheDeclaration() {
        let invoice = Consignment(
            branding: brand, kind: .commercialInvoice, number: "CI-1", date: "11 August 2026",
            exporter: Party(name: "ArrayPress Ltd", address: ["London"]),
            consignee: Party(name: "Kestrel GmbH", address: ["Frankfurt"]),
            items: goods,
            incoterm: "DAP Duisburg (Incoterms 2020)",
            value: [("Total value", "£3,520.00")]
        )
        let rendered = text(of: invoice.render())
        XCTAssertTrue(rendered.contains("3,520.00"))
        XCTAssertTrue(rendered.contains("I declare"))
        XCTAssertTrue(rendered.contains("(Signature) Tj"))
    }

    func testPackageNumbersAreDrawnWhenGiven() {
        let list = Consignment(
            branding: brand, kind: .packingList, number: "PL-1",
            exporter: Party(name: "ArrayPress Ltd"),
            consignee: Party(name: "Kestrel GmbH"),
            items: goods
        )
        // Naming the column and then dropping every value shifted the whole
        // row one place left, which put commodity codes under Pkg.
        let rendered = text(of: list.render())
        XCTAssertTrue(rendered.contains("(Pkg) Tj"))
        XCTAssertTrue(rendered.contains("(1 of 3) Tj"))
        XCTAssertTrue(rendered.contains("(8519.81) Tj"))
    }

    func testCountryOfOriginIsNotTruncated() {
        let invoice = Consignment(
            branding: brand, kind: .commercialInvoice, number: "CI-1",
            exporter: Party(name: "ArrayPress Ltd"),
            consignee: Party(name: "Kestrel GmbH"),
            items: [ConsignmentItem(
                description: "Windshield kit", commodityCode: "3926.90",
                countryOfOrigin: "United Kingdom", quantity: "6 pcs",
                netWeight: "2.4 kg", grossWeight: "3.8 kg",
                unitPrice: "£95.00", amount: "£570.00", package: "2 of 3"
            )]
        )
        // An origin cut to "Unite..." is the difference between goods clearing
        // and goods being held.
        XCTAssertTrue(text(of: invoice.render()).contains("(United Kingdom) Tj"))
    }

    func testConsignmentNamesTheParticularsItIsMissing() {
        let bare = Consignment(
            branding: brand, kind: .commercialInvoice, number: "",
            exporter: Party(name: "ArrayPress Ltd"),
            consignee: Party(name: "Kestrel GmbH"),
            items: [ConsignmentItem(description: "Something")]
        )
        let warnings = bare.complianceWarnings()

        XCTAssertTrue(warnings.contains("document number"))
        XCTAssertTrue(warnings.contains("commodity code on every line"))
        XCTAssertTrue(warnings.contains("country of origin on every line"))
        XCTAssertTrue(warnings.contains("delivery term (Incoterm) and named place"))
        XCTAssertTrue(warnings.contains("reason for export"))
    }

    func testPackingListIsNotAskedForPrices() {
        let list = Consignment(
            branding: brand, kind: .packingList, number: "PL-1", date: "11 August 2026",
            exporter: Party(name: "ArrayPress Ltd", address: ["London"]),
            consignee: Party(name: "Kestrel GmbH", address: ["Frankfurt"]),
            items: goods,
            countryOfExport: "United Kingdom",
            countryOfDestination: "Germany"
        )
        let warnings = list.complianceWarnings()
        XCTAssertFalse(warnings.contains("total value"))
        XCTAssertFalse(warnings.contains("a value on every line"))
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    // MARK: Every template

    func testEveryTemplateProducesAReadableFile() {
        let documents: [Document] = [
            Timesheet(branding: brand, worker: Party(name: "A"), period: "July",
                      entries: [TimeEntry(date: "1", description: "x", hours: "1")]).render(),
            RoyaltyStatement(branding: brand, payee: Party(name: "B"), period: "July",
                             lines: [RoyaltyLine(source: "S", title: "T", net: "£1", earned: "£1")]).render(),
            AgedDebtors(branding: brand, asAt: "31 July", buckets: ["Current"],
                        rows: [DebtorRow(account: "C", amounts: ["£1"], total: "£1")]).render(),
            Consignment(branding: brand, number: "1", exporter: Party(name: "D"),
                        consignee: Party(name: "E"), items: [ConsignmentItem(description: "F")]).render(),
        ]

        for document in documents {
            let data = document.render()
            XCTAssertTrue(String(decoding: data.prefix(8), as: UTF8.self).hasPrefix("%PDF-1."))
            XCTAssertTrue(String(decoding: data.suffix(8), as: UTF8.self).contains("%%EOF"))
            XCTAssertGreaterThan(document.pageCount(), 0)
        }
    }
}
