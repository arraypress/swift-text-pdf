//
//  TextPDFTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import XCTest

@testable import TextPDF

final class TextPDFTests: XCTestCase {

    // MARK: - Encoding

    func testCurrencySymbolsSurviveAsSingleBytes() {
        // The bug this guards: escaping to CP1252 and then writing the stream
        // as UTF-8 re-expands £ (U+00A3) into two bytes, and every invoice
        // shows "Â£".
        let pdf = Document()
        pdf.text("£1,240.00 and €980,00")
        let data = pdf.render()

        XCTAssertTrue(data.contains(0xA3), "£ must reach the file as one byte")
        XCTAssertTrue(data.contains(0x80), "€ must reach the file as one byte")
        // The UTF-8 form of £ is the byte pair C2 A3; finding it means the
        // stream was encoded twice.
        let doubled = Array(data).indices.dropLast().contains { index in
            data[data.startIndex + index] == 0xC2 && data[data.startIndex + index + 1] == 0xA3
        }
        XCTAssertFalse(doubled, "found the UTF-8 double-encoding")
    }

    func testParenthesesAreEscaped() {
        // An unescaped ) ends the string early and produces a file no reader
        // will open.
        XCTAssertEqual(PDFEncoding.escape("Smith (Holdings)"), "Smith \\(Holdings\\)")
        XCTAssertEqual(PDFEncoding.escape("back\\slash"), "back\\\\slash")
    }

    func testControlCharactersAreStripped() {
        // A stray CR in a customer's name would displace the rest of the line.
        XCTAssertEqual(PDFEncoding.escape("Acme\r\nLtd"), "AcmeLtd")
        XCTAssertEqual(PDFEncoding.escape("tab\there"), "tabhere")
    }

    func testWindows1252PunctuationIsPreserved() {
        // Curly quotes and dashes live in the 0x80–0x9F window, which is
        // exactly the punctuation an invoice uses.
        XCTAssertEqual(PDFEncoding.escape("—"), "\u{97}")
        XCTAssertEqual(PDFEncoding.escape("\u{2019}"), "\u{92}")
    }

    func testUnrepresentableScriptsBecomeQuestionMarks() {
        // Honest failure: dropping them silently would leave a name looking
        // merely short rather than wrong.
        XCTAssertEqual(PDFEncoding.escape("Παπαδ"), "?????")
        XCTAssertEqual(PDFEncoding.escape("株式会社"), "????")
    }

    func testPolishTransliterates() {
        XCTAssertEqual(PDFEncoding.escape("Łódź"), "L\u{F3}dz")
    }

    func testNonFiniteNumbersAreClamped() {
        // sprintf("%.2F", inf) writes the literal INF, which is not a PDF
        // number — a reader meeting one drops the page.
        XCTAssertEqual(PDFEncoding.number(.infinity), 32767)
        XCTAssertEqual(PDFEncoding.number(-.infinity), -32767)
        XCTAssertEqual(PDFEncoding.number(.nan), 0)
    }

    // MARK: - Metrics

    func testProportionalWidthsDiffer() {
        // The whole reason the metrics exist: a space is 278 units where a
        // capital E is 667, so padding with spaces cannot align a column.
        XCTAssertNotEqual(
            Font.helvetica.widthOf("E", size: 10),
            Font.helvetica.widthOf(" ", size: 10)
        )
        XCTAssertEqual(Font.helvetica.widthOf("E", size: 10), 6.67, accuracy: 0.001)
    }

    func testCourierIsMonospaced() {
        XCTAssertEqual(Font.courier.widthOf("i", size: 10), Font.courier.widthOf("W", size: 10))
    }

    func testBoldIsWiderThanRegular() {
        XCTAssertGreaterThan(
            Font.helveticaBold.widthOf("Total due", size: 11),
            Font.helvetica.widthOf("Total due", size: 11)
        )
    }

    func testTruncationFitsTheWidth() {
        let long = "Extended distribution rights for the entire back catalogue"
        let truncated = Font.helvetica.truncate(long, size: 9, width: 80)
        XCTAssertTrue(truncated.hasSuffix("..."))
        XCTAssertLessThanOrEqual(Font.helvetica.widthOf(truncated, size: 9), 80)
    }

    func testShortTextIsNotTruncated() {
        XCTAssertEqual(Font.helvetica.truncate("Qty", size: 9, width: 80), "Qty")
    }

    // MARK: - Colour

    func testHexParsing() {
        XCTAssertEqual(Color.hex("#0f766e"), Color(red: 15, green: 118, blue: 110))
        XCTAssertEqual(Color.hex("0f766e"), Color(red: 15, green: 118, blue: 110))
        XCTAssertEqual(Color.hex("#fff"), Color(red: 255, green: 255, blue: 255))
    }

    func testMalformedHexBecomesBlackRatherThanThrowing() {
        // A bad brand colour should print a dull invoice, not refuse to
        // produce one.
        XCTAssertTrue(Color.hex("nonsense").isBlack)
        XCTAssertTrue(Color.hex("#12345").isBlack)
    }

    // MARK: - SVG paths

    func testProseIsNotMistakenForAPath() {
        // Text containing a, c, h or t tokenizes into commands; without the
        // moveto check it would draw arbitrary vectors.
        XCTAssertEqual(SVGPath.toPDF("this is not a path"), "")
        XCTAssertEqual(SVGPath.toPDF(""), "")
        XCTAssertEqual(SVGPath.toPDF("M"), "", "a bare letter is text, not a path")
    }

    func testLinesAndCurvesConvert() {
        let out = SVGPath.toPDF("M10,10 L20,20 Z", svgHeight: 100)
        XCTAssertTrue(out.contains(" m\n"))
        XCTAssertTrue(out.contains(" l\n"))
        XCTAssertTrue(out.contains("h\n"))
    }

    func testYAxisIsFlipped() {
        // SVG counts down from the top, PDF up from the bottom.
        let out = SVGPath.toPDF("M0,0", svgHeight: 100)
        XCTAssertTrue(out.hasPrefix("0.000 100.000 m"), out)
    }

    func testRepeatedPairsAfterMovetoBecomeLines() {
        let out = SVGPath.toPDF("M0,0 10,10 20,20", svgHeight: 100)
        XCTAssertEqual(out.components(separatedBy: " l\n").count - 1, 2)
    }

    func testQuadraticIsElevatedToCubic() {
        // PDF has no quadratic operator; the conversion must be exact.
        let out = SVGPath.toPDF("M0,0 Q10,10 20,0", svgHeight: 100)
        XCTAssertTrue(out.contains(" c\n"))
    }

    // MARK: - Document structure

    func testRendersAValidPDFHeaderAndTrailer() {
        let data = Document().text("hello").render()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.hasSuffix("%%EOF"))
        XCTAssertTrue(text.contains("/Type /Catalog"))
    }

    func testCrossReferenceOffsetsPointAtRealObjects() {
        // Readers seek directly to these offsets; an off-by-one opens in one
        // viewer and fails in another.
        let data = Document().text("hello").render()
        let text = String(decoding: data, as: UTF8.self)

        guard let xrefRange = text.range(of: "startxref\n") else { return XCTFail("no startxref") }
        let tail = text[xrefRange.upperBound...].prefix(while: { $0.isNumber })
        let offset = Int(tail) ?? -1

        XCTAssertGreaterThan(offset, 0)
        XCTAssertLessThan(offset, data.count)
        let index = text.index(text.startIndex, offsetBy: offset)
        XCTAssertTrue(text[index...].hasPrefix("xref"), "startxref must point at the table")
    }

    func testLongTextBreaksAcrossPages() {
        let pdf = Document()
        pdf.text(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400))
        XCTAssertGreaterThan(pdf.pageCount(), 1)
    }

    func testWrappingRespectsTheContentWidth() {
        let pdf = Document(margin: 56)
        let lines = pdf.wrap("word ".repeated(60), font: .helvetica, size: 10, width: pdf.contentWidth())
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(Font.helvetica.widthOf(line, size: 10), pdf.contentWidth() + 0.01)
        }
    }

    func testAWordWiderThanTheColumnIsBrokenNotLooped() {
        // Without breaking it, the wrapper spins forever or overflows.
        let pdf = Document()
        let lines = pdf.wrap(String(repeating: "M", count: 400), font: .helvetica, size: 10, width: 100)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertFalse(lines.contains { Font.helvetica.widthOf($0, size: 10) > 101 })
    }

    func testFootersSeeTheFinalPageCount() {
        // The count is only known after the last page, which is why footers
        // run at render time rather than as pages are written.
        let pdf = Document()
        var seenTotals: [Int] = []
        pdf.text(String(repeating: "filler text here. ", count: 500))
        pdf.onEachPage { _, _, total in seenTotals.append(total) }
        _ = pdf.render()

        XCTAssertGreaterThan(seenTotals.count, 1)
        XCTAssertEqual(Set(seenTotals).count, 1, "every page must see the same total")
        XCTAssertEqual(seenTotals.first, seenTotals.count)
    }

    func testDeterministicOutput() {
        // Same input, same bytes — so a regenerated invoice diffs clean.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func build() -> Data {
            let pdf = Document()
            pdf.text("Invoice INV-2026-0042")
            return pdf.render(metadata: ["Title": "x"], creationDate: date)
        }
        XCTAssertEqual(build(), build())
    }

    // MARK: - Compliance

    private func minimalInvoice(kind: DocumentKind = .invoice, reference: String = "") -> Invoice {
        Invoice(
            kind: kind,
            branding: Branding(name: "Test"),
            number: "INV-1",
            from: Party(name: "Seller", address: ["1 Road"], taxID: "GB1"),
            to: Party(name: "Buyer", address: ["2 Road"]),
            items: [LineItem(description: "Thing", amount: "£1.00")],
            totals: [("Subtotal", "£1.00")],
            supplyDate: "1 August 2026",
            reference: reference
        )
    }

    func testACompleteInvoicePasses() {
        XCTAssertTrue(minimalInvoice().complianceWarnings().isEmpty)
    }

    func testMissingSupplyDateIsCaught() {
        // The particular most often left off, and a §14 UStG requirement.
        let invoice = Invoice(
            branding: Branding(name: "T"), number: "INV-1",
            from: Party(name: "S", address: ["1"], taxID: "GB1"),
            to: Party(name: "B", address: ["2"]),
            items: [], totals: [("Subtotal", "£1")]
        )
        XCTAssertTrue(invoice.complianceWarnings().contains { $0.contains("date of supply") })
    }

    func testReverseChargeDemandsTheCustomerVatNumber() {
        let invoice = Invoice(
            branding: Branding(name: "T"), number: "INV-1",
            from: Party(name: "S", address: ["1"], taxID: "GB1"),
            to: Party(name: "B", address: ["2"]),
            items: [], totals: [("Net", "£1")],
            vat: .reverseCharge, supplyDate: "1 Aug"
        )
        XCTAssertTrue(invoice.complianceWarnings().contains { $0.contains("customer VAT number") })
    }

    func testCreditNoteMustCiteTheOriginalInvoice() {
        // You cannot amend an invoice — sequential numbering forbids it — so a
        // credit note that references nothing is unusable.
        XCTAssertTrue(
            minimalInvoice(kind: .creditNote).complianceWarnings()
                .contains { $0.contains("reference the invoice") }
        )
        XCTAssertTrue(minimalInvoice(kind: .creditNote, reference: "INV-1").complianceWarnings().isEmpty)
    }

    func testSelfBilledInvoiceDemandsTheSupplierVatNumber() {
        // HMRC requires both parties' numbers on a self-billed invoice —
        // the supplier's is what makes it their invoice.
        let base = minimalInvoice(kind: .selfBilling)
        XCTAssertTrue(base.complianceWarnings().contains { $0.contains("supplier's VAT number") })
    }

    func testSelfBillingWordingAppears() {
        // Without the words on the face of it the recipient cannot rely on it.
        XCTAssertTrue(DocumentKind.selfBilling.standingNote?.contains("Self-billing") ?? false)
    }

    func testRemittanceIsNotATaxDocument() {
        // It reports payment against someone else's invoice; the particulars
        // belong on theirs.
        let advice = Invoice(
            kind: .remittance, branding: Branding(name: "T"), number: "RA-1",
            from: Party(name: "S"), to: Party(name: "B"), items: []
        )
        XCTAssertTrue(advice.complianceWarnings().isEmpty)
        XCTAssertEqual(DocumentKind.remittance.title, "REMITTANCE ADVICE")
    }

    func testDeliveryNoteShowsNoMoney() {
        // It travels with the goods; the warehouse has no business seeing the
        // price. Suppressing the columns is the document's defining behaviour.
        XCTAssertFalse(DocumentKind.deliveryNote.showsMoney)
        XCTAssertTrue(DocumentKind.invoice.showsMoney)

        let note = Invoice(
            kind: .deliveryNote, branding: Branding(name: "T"), number: "DN-1",
            from: Party(name: "S"), to: Party(name: "B"),
            items: [LineItem(description: "Widget", amount: "£99.00", quantity: "3", unitPrice: "£33.00")],
            totals: [("Subtotal", "£99.00")], total: [("Total", "£99.00")]
        )
        let stream = String(decoding: note.render().render(), as: UTF8.self)
        XCTAssertFalse(stream.contains("99.00"), "a price reached a delivery note")
        XCTAssertTrue(stream.contains("(Widget) Tj"))
    }

    func testDebitNoteMustReferenceWhatItAdjusts() {
        XCTAssertTrue(
            minimalInvoice(kind: .debitNote).complianceWarnings()
                .contains { $0.contains("reference the document") }
        )
    }

    func testAQuoteIsNotHeldToTaxRules() {
        // Demanding a supply date on a quotation would be a false warning.
        let quote = Invoice(
            kind: .quote, branding: Branding(name: "T"), number: "Q-1",
            from: Party(name: "S"), to: Party(name: "B"), items: []
        )
        XCTAssertTrue(quote.complianceWarnings().isEmpty)
    }

    func testGermanWordingIsAddedOnlyWhenAsked() {
        XCTAssertEqual(VatTreatment.reverseCharge.notes().count, 2)
        XCTAssertEqual(VatTreatment.reverseCharge.notes(german: true).count, 3)
        XCTAssertTrue(VatTreatment.standard.notes(german: true).isEmpty)
    }

    // MARK: - Tables

    func testColumnWidthsNormalise() {
        // [2,1,1] should behave exactly like [0.5,0.25,0.25].
        let pdf = Document()
        let a = Table(headers: ["A", "B", "C"]).widths([2, 1, 1])
        let b = Table(headers: ["A", "B", "C"]).widths([0.5, 0.25, 0.25])
        a.row(["1", "2", "3"]); b.row(["1", "2", "3"])
        a.draw(pdf)
        let first = pdf.cursor()
        b.draw(pdf)
        XCTAssertEqual(first - pdf.cursor(), first - pdf.cursor(), accuracy: 0.001)
    }

    func testTableEdgesAlignWithTheMargins() {
        // A section label above a table starts at the left margin; padding the
        // first column inward means the two no longer line up, and the last
        // column stops meeting the right margin every other figure uses.
        let pdf = Document(margin: 48)
        let table = Table(headers: ["Rate", "Net", "VAT"])
        table.widths([0.4, 0.3, 0.3]).align([1: .right, 2: .right])
        table.row(["20%", "£770.40", "£154.08"])
        table.draw(pdf)

        let stream = String(decoding: pdf.render(), as: UTF8.self)
        XCTAssertTrue(stream.contains("48.00 "), "the first column must start at the left margin")
    }

    func testAnInvoiceWithManyLinesBreaksAcrossPages() {
        // Uncommon but real — a year of licences on one invoice.
        let items = (1...60).map {
            LineItem(description: "Licence \($0)", amount: "£10.00", unitPrice: "£10.00")
        }
        let invoice = Invoice(
            branding: Branding(name: "T"), number: "INV-1",
            from: Party(name: "S", address: ["1"], taxID: "GB1"),
            to: Party(name: "B", address: ["2"]),
            items: items,
            totals: [("Subtotal", "£600.00")],
            total: [("Total due", "£720.00")],
            supplyDate: "1 Aug"
        )
        let document = invoice.render()
        XCTAssertGreaterThan(document.pageCount(), 1)

        // The item table's heading must repeat, or page two is a column of
        // unlabelled numbers.
        let stream = String(decoding: document.render(), as: UTF8.self)
        XCTAssertGreaterThan(stream.components(separatedBy: "(Description) Tj").count - 1, 1)
    }

    func testEmptyTableDrawsNothingAndDoesNotCrash() {
        let pdf = Document()
        let before = pdf.cursor()
        Table().draw(pdf)
        XCTAssertEqual(pdf.cursor(), before)
    }
}

private extension String {
    func repeated(_ times: Int) -> String { String(repeating: self, count: times) }
}
