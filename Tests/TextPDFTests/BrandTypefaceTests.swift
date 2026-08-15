//
//  BrandTypefaceTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Setting business documents in a typeface of the business's own.
//

import PDFKit
import XCTest
@testable import TextPDF

final class BrandTypefaceTests: XCTestCase {

    private let regular = "/System/Library/Fonts/Supplemental/Arial.ttf"
    private let bold = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

    private func brandFiles() throws -> TypefaceFiles {
        try XCTSkipUnless(
            [regular, bold].allSatisfy(FileManager.default.fileExists(atPath:)),
            "Arial is not installed in separate files"
        )
        return TypefaceFiles(name: "Arial", regular: regular, bold: bold)
    }

    private func invoice(branding: Branding) -> Invoice {
        Invoice(
            branding: branding,
            number: "INV-2026-0042",
            from: Party(name: "Sugarcart Ltd", address: ["71-75 Shelton Street"],
                        email: "billing@sugarcart.example", taxID: "GB123456789"),
            to: Party(name: "Acme Recordings Ltd", address: ["Studio 4, 118 Brick Lane"],
                      email: "ap@acme.example"),
            items: [LineItem(description: "Drum Kit Vol. 2", amount: "£149.00")],
            totals: [(label: "Subtotal", value: "£149.00")],
            total: [(label: "Total due", value: "£178.80")],
            supplyDate: "31 July 2026"
        )
    }

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    // MARK: Branding

    func testABrandTypefaceSetsTheDocument() throws {
        let files = try brandFiles()
        let branded = invoice(branding: Branding(name: "Sugarcart Ltd", typeface: files))

        let rendered = try raw(branded.render().render())
        XCTAssertTrue(rendered.contains("/FontFile2"), "the brand face was not embedded")
        XCTAssertTrue(rendered.contains("Arial"), "the brand face was not used")
    }

    func testWithoutOneTheDocumentStaysInHelvetica() throws {
        let plain = invoice(branding: Branding(name: "Sugarcart Ltd"))
        let rendered = try raw(plain.render().render())

        XCTAssertFalse(rendered.contains("/FontFile2"), "nothing should have been embedded")
        XCTAssertTrue(rendered.contains("/BaseFont /Helvetica"))
    }

    func testAFamilyPassedInWinsOverTheProfile() throws {
        let files = try brandFiles()
        let branded = invoice(branding: Branding(name: "Sugarcart Ltd", typeface: files))

        // Rendering with an explicit family is how a caller overrides a stored
        // profile for one document.
        var other = FontFamily(name: "Other")
        other.add(try EmbeddedFont.load(URL(fileURLWithPath: regular)), weight: .regular)

        XCTAssertNotNil(branded.render(in: other))
    }

    func testTheOlderSignatureStillWorks() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: regular), "Arial is not installed")

        // render(embedding:) meant "use this where Windows-1252 falls short",
        // and documents written against it must keep doing exactly that.
        let plain = invoice(branding: Branding(name: "Sugarcart Ltd"))
        let font = try EmbeddedFont.load(URL(fileURLWithPath: regular))

        let rendered = try raw(plain.render(embedding: font).render())
        XCTAssertFalse(rendered.contains("/FontFile2"), "Latin text should not have embedded it")
    }

    // MARK: Reporting what the face could not draw

    func testAFaceMissingTheCurrencySymbolIsReported() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: regular), "Arial is not installed")

        // A brand face drawn for a logo commonly has no £ or €. The run falls
        // back and appears correctly, but in a different face — which on a
        // total is the one figure nobody should have to look at twice.
        var sparse = FontFamily(name: "Sparse")
        sparse.add(try EmbeddedFont.load(URL(fileURLWithPath: regular)), weight: .regular)

        let pdf = Document()
        pdf.family = sparse
        pdf.text("Total due")
        XCTAssertTrue(pdf.fallbacks.isEmpty, "Arial covers this")

        // A face that covers nothing at all: every run falls back.
        let document = Document()
        document.family = FontFamily(name: "Empty")
        document.text("Total due £178.80")

        XCTAssertEqual(document.fallbacks, ["Total due £178.80"])
    }

    func testNothingIsReportedWithoutAFamily() {
        let pdf = Document()
        pdf.text("Total due £178.80")
        XCTAssertTrue(pdf.fallbacks.isEmpty, "there was no family to fall back from")
    }

    func testAFallbackIsReportedOnceHoweverOftenItIsDrawn() {
        let pdf = Document()
        pdf.family = FontFamily(name: "Empty")
        pdf.text("Total due")
        pdf.text("Total due")

        XCTAssertEqual(pdf.fallbacks.count, 1)
    }

    // MARK: Links and language

    func testTheCustomerEmailIsClickable() throws {
        let branded = invoice(branding: Branding(name: "Sugarcart Ltd"))
        let document = try XCTUnwrap(PDFDocument(data: branded.render().render()))
        let page = try XCTUnwrap(document.page(at: 0))

        let urls = page.annotations.compactMap { $0.url?.absoluteString }
        XCTAssertTrue(urls.contains("mailto:ap@acme.example"), "\(urls)")
    }

    func testAGermanInvoiceSaysSo() throws {
        let german = Invoice(
            branding: Branding(name: "Sugarcart Ltd"),
            number: "INV-1",
            from: Party(name: "A", taxID: "DE1"),
            to: Party(name: "B", address: ["Berlin"], taxID: "DE2"),
            items: [LineItem(description: "x", amount: "€1")],
            vat: .reverseCharge,
            supplyDate: "31 Juli 2026",
            germanNotes: true
        )
        XCTAssertTrue(try raw(german.render().render()).contains("/Lang (de)"))

        let english = invoice(branding: Branding(name: "Sugarcart Ltd"))
        XCTAssertTrue(try raw(english.render().render()).contains("/Lang (en)"))
    }

    // MARK: Loading

    func testTypefaceFilesResolveToAFamily() throws {
        let family = try brandFiles().family()

        XCTAssertNotNil(family.face(.regular))
        XCTAssertTrue(try XCTUnwrap(family.face(.bold)).isBold)
        // A weight that was not supplied resolves to the nearest that was.
        XCTAssertNotNil(family.face(.semibold))
    }

    func testAMissingFileIsReported() {
        let files = TypefaceFiles(regular: "/no/such/brand.ttf")
        XCTAssertThrowsError(try files.family()) { error in
            XCTAssertEqual(error as? EmbeddingError, .unreadable("brand.ttf"))
        }
    }

    func testBrandingSurvivesJSON() throws {
        let branding = Branding(name: "Sugarcart Ltd", accent: "#1F3A5F",
                                typeface: TypefaceFiles(name: "Arial", regular: regular))
        let decoded = try JSONDecoder().decode(Branding.self, from: JSONEncoder().encode(branding))

        XCTAssertEqual(decoded, branding)
        XCTAssertEqual(decoded.typeface?.regular, regular)
    }
}

// MARK: - Compliance against the page rather than the data

extension BrandTypefaceTests {

    private func reverseCharge() -> Invoice {
        Invoice(
            branding: Branding(name: "Sugarcart Ltd"),
            number: "INV-2026-0042",
            from: Party(name: "Sugarcart Ltd", address: ["London"], taxID: "GB123456789"),
            to: Party(name: "Klangwerk GmbH", address: ["Berlin"], taxID: "DE811567890"),
            items: [LineItem(description: "Sound design", amount: "€1,200.00")],
            total: [(label: "Total due", value: "€1,200.00")],
            vat: .reverseCharge,
            supplyDate: "31 July 2026"
        )
    }

    func testACompliantInvoiceVerifiesAgainstItsOwnPage() throws {
        let invoice = reverseCharge()
        let document = invoice.render()

        XCTAssertTrue(invoice.complianceWarnings().isEmpty, "\(invoice.complianceWarnings())")
        XCTAssertTrue(
            invoice.complianceWarnings(verifying: document).isEmpty,
            "\(invoice.complianceWarnings(verifying: document))"
        )
    }

    func testWordingThatNeverReachedThePageIsCaught() throws {
        // The gap this closes: the data says reverse charge, so the data check
        // passes — but only the page decides whether the recipient can rely on
        // the document. A blank document has the same fields and none of the
        // words.
        let invoice = reverseCharge()
        let blank = Document()

        let missing = invoice.complianceWarnings(verifying: blank)
        XCTAssertFalse(missing.isEmpty)
        XCTAssertTrue(missing.contains { $0.contains("did not reach the page") },
                      "\(missing)")
        XCTAssertTrue(missing.contains { $0.contains("Article 196") }, "\(missing)")
    }

    func testTheTotalIsCheckedAgainstThePage() throws {
        let invoice = reverseCharge()
        let blank = Document()
        XCTAssertTrue(
            invoice.complianceWarnings(verifying: blank).contains { $0.contains("€1,200.00") }
        )
    }

    func testTheDataCheckIsUnchanged() {
        // The older call still answers the older question, so nothing that
        // depends on it changes behaviour.
        let incomplete = Invoice(
            branding: Branding(name: "A"),
            number: "",
            from: Party(name: "A"),
            to: Party(name: "B"),
            items: []
        )
        XCTAssertFalse(incomplete.complianceWarnings().isEmpty)
    }

    func testDrawnTextRecordsWhatWasDrawn() {
        let pdf = Document()
        pdf.text("Total due")
        pdf.textAt("£178.80", x: 50, y: 50, size: 10)

        XCTAssertEqual(pdf.drawnText, ["Total due", "£178.80"])
    }
}
