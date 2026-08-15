//
//  ArchivalTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import PDFKit
import XCTest
@testable import TextPDF

final class ArchivalTests: XCTestCase {

    /// Pulls an attachment back out the way a Factur-X reader would.
    private func extracted(_ data: Data, named wanted: String) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog
        else { return nil }

        var names: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names else { return nil }

        var embedded: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded
        else { return nil }

        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(embedded, "Names", &array), let array else { return nil }

        var index = 0
        while index + 1 < CGPDFArrayGetCount(array) {
            var nameRef: CGPDFStringRef?
            var spec: CGPDFDictionaryRef?
            CGPDFArrayGetString(array, index, &nameRef)
            CGPDFArrayGetDictionary(array, index + 1, &spec)

            if let nameRef, let spec,
               let cf = CGPDFStringCopyTextString(nameRef), (cf as String) == wanted {
                var ef: CGPDFDictionaryRef?
                var stream: CGPDFStreamRef?
                CGPDFDictionaryGetDictionary(spec, "EF", &ef)
                if let ef, CGPDFDictionaryGetStream(ef, "F", &stream), let stream {
                    var format = CGPDFDataFormat.raw
                    return CGPDFStreamCopyData(stream, &format) as Data?
                }
            }
            index += 2
        }
        return nil
    }

    func testTheAttachmentComesBackOut() throws {
        let xml = Data("<?xml version=\"1.0\"?><rsm:CrossIndustryInvoice>INV-42</rsm:CrossIndustryInvoice>".utf8)

        let pdf = Document()
        pdf.text("INVOICE")
        pdf.attach(xml, name: "factur-x.xml", mimeType: "text/xml", relationship: .alternative)

        let data = pdf.render(standard: .pdfA3b)
        let back = extracted(data, named: "factur-x.xml")

        XCTAssertEqual(back, xml, "the file did not survive being carried")
    }
}

// MARK: - Carrying files

extension ArchivalTests {

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    private func embedded() throws -> EmbeddedFont {
        let arial = URL(fileURLWithPath: "/Library/Fonts/Arial Unicode.ttf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arial.path), "no face to embed")
        return try EmbeddedFont.load(arial)
    }

    func testSeveralFilesCanTravelTogether() throws {
        let pdf = Document()
        pdf.text("Invoice")
        pdf.attach(Data("<invoice/>".utf8), name: "factur-x.xml", mimeType: "text/xml",
                   relationship: .alternative)
        pdf.attach(Data("timesheet".utf8), name: "hours.csv", mimeType: "text/csv",
                   relationship: .supplement)

        let data = pdf.render()
        XCTAssertEqual(extracted(data, named: "factur-x.xml"), Data("<invoice/>".utf8))
        XCTAssertEqual(extracted(data, named: "hours.csv"), Data("timesheet".utf8))
    }

    func testTheRelationshipIsRecorded() throws {
        // A Factur-X reader looks for /Alternative to find the invoice XML,
        // and will not look at a file attached as anything else.
        let pdf = Document()
        pdf.attach(Data("<invoice/>".utf8), name: "factur-x.xml", relationship: .alternative)

        XCTAssertTrue(try raw(pdf.render()).contains("/AFRelationship /Alternative"))
    }

    func testAFilesAreReachableBothWays() throws {
        // /AF for a reader that goes looking, /Names for the panel a person
        // opens. Readers use both.
        let pdf = Document()
        pdf.attach(Data("x".utf8), name: "a.xml")

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/AF ["), "no associated files array")
        XCTAssertTrue(rendered.contains("/EmbeddedFiles"), "not in the attachments panel")
    }

    func testAMimeTypeWithASlashSurvives() throws {
        // A PDF name cannot carry "/" — application/xml has to be written
        // application#2Fxml or the dictionary is malformed from that point on.
        let pdf = Document()
        pdf.attach(Data("x".utf8), name: "a.xml", mimeType: "application/xml")

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.contains("/Subtype /application#2Fxml"), rendered)
        XCTAssertNotNil(PDFDocument(data: pdf.render()), "the file stopped parsing")
    }

    func testEmptyAttachmentsAreIgnored() throws {
        let pdf = Document()
        pdf.attach(Data(), name: "empty.xml")
        pdf.attach(Data("x".utf8), name: "   ")

        XCTAssertFalse(try raw(pdf.render()).contains("/EmbeddedFiles"))
    }

    func testAttachingTwiceUnderOneNameKeepsTheLast() throws {
        let pdf = Document()
        pdf.attach(Data("first".utf8), name: "factur-x.xml")
        pdf.attach(Data("second".utf8), name: "factur-x.xml")

        XCTAssertEqual(extracted(pdf.render(), named: "factur-x.xml"), Data("second".utf8))
    }

    func testBinaryContentSurvives() throws {
        // The stream is spliced in as bytes; a Latin-1 round trip would
        // corrupt anything above 0x7F.
        let bytes = Data((0...255).map { UInt8($0) })
        let pdf = Document()
        pdf.attach(bytes, name: "blob.bin")

        XCTAssertEqual(extracted(pdf.render(), named: "blob.bin"), bytes)
    }
}

// MARK: - Claiming the standard

extension ArchivalTests {

    func testAConformingFileCarriesWhatTheStandardAsksFor() throws {
        let pdf = Document()
        pdf.text("INVOICE INV-2026-0042", size: 14, face: try embedded())

        let data = pdf.render(metadata: ["Title": "INV-2026-0042", "Author": "SwiftInvoices Ltd"],
                              standard: .pdfA3b)
        let rendered = try raw(data)

        XCTAssertTrue(rendered.hasPrefix("%PDF-1.7"), "PDF/A-3 is built on 1.7")
        XCTAssertTrue(rendered.contains("<pdfaid:part>3</pdfaid:part>"))
        XCTAssertTrue(rendered.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        XCTAssertTrue(rendered.contains("/Type /Metadata"))
        XCTAssertTrue(rendered.contains("GTS_PDFA1"), "no output intent")
        XCTAssertTrue(rendered.contains("sRGB IEC61966-2.1"))
        XCTAssertTrue(rendered.contains("/ID [<"), "no file identifier")
        XCTAssertNotNil(PDFDocument(data: data))
    }

    func testTheMetadataAgreesWithTheDocumentInformation() throws {
        // A validator compares the two, and a file whose halves disagree
        // fails for that alone.
        let pdf = Document()
        pdf.text("x", face: try embedded())

        let rendered = try raw(pdf.render(metadata: ["Title": "INV-1", "Author": "Me"],
                                          standard: .pdfA3b))

        XCTAssertTrue(rendered.contains("/Title (INV-1)"))
        XCTAssertTrue(rendered.contains("<rdf:li xml:lang=\"x-default\">INV-1</rdf:li>"))
        XCTAssertTrue(rendered.contains("<rdf:li>Me</rdf:li>"))
    }

    func testMetadataIsEscapedForXML() throws {
        let pdf = Document()
        pdf.text("x", face: try embedded())

        let rendered = try raw(pdf.render(metadata: ["Title": "Smith & Sons <Ltd>"],
                                          standard: .pdfA3b))
        XCTAssertTrue(rendered.contains("Smith &amp; Sons &lt;Ltd&gt;"), "raw markup reached the packet")
    }

    func testAnOrdinaryFileClaimsNothing() throws {
        let pdf = Document()
        pdf.text("x")

        let rendered = try raw(pdf.render())
        XCTAssertTrue(rendered.hasPrefix("%PDF-1.4"))
        XCTAssertFalse(rendered.contains("pdfaid"))
        XCTAssertFalse(rendered.contains("GTS_PDFA1"))
    }

    func testTheSameDocumentTwiceIsTheSameBytes() throws {
        // The identifier is derived from the content rather than randomly, so
        // a committed example does not churn on every regeneration.
        func build() throws -> Data {
            let pdf = Document()
            pdf.text("x", face: try embedded())
            return pdf.render(metadata: ["Title": "T"],
                              creationDate: Date(timeIntervalSince1970: 1_776_000_000),
                              standard: .pdfA3b)
        }
        XCTAssertEqual(try build(), try build())
    }

    // MARK: What it cannot claim

    func testBaseFontsAreReportedAsUnconformant() throws {
        // The one violation this writer can produce: the base-14 faces belong
        // to the reader, and PDF/A carries everything it needs.
        let pdf = Document()
        pdf.text("Set in Helvetica")

        let issues = pdf.conformanceIssues(for: .pdfA3b)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(try XCTUnwrap(issues.first).contains("not embedded"), issues.joined())
    }

    func testAnEmbeddedDocumentHasNothingToReport() throws {
        let pdf = Document()
        pdf.text("Set in a face that travels", face: try embedded())

        XCTAssertEqual(pdf.conformanceIssues(for: .pdfA3b), [])
    }

    func testNothingIsReportedWhenNothingIsClaimed() throws {
        let pdf = Document()
        pdf.text("Set in Helvetica")
        XCTAssertEqual(pdf.conformanceIssues(for: .none), [])
    }

    func testWhitespaceInTheBaseFontDoesNotCount() throws {
        // A stray space drawn in Helvetica is not a font somebody depends on.
        let pdf = Document()
        pdf.text("   ", face: try embedded())
        pdf.text("Real text", face: try embedded())

        XCTAssertEqual(pdf.conformanceIssues(for: .pdfA3b), [])
    }

    func testAConformingFileCanStillCarryItsXML() throws {
        let xml = Data("<rsm:CrossIndustryInvoice/>".utf8)
        let pdf = Document()
        pdf.text("INVOICE", face: try embedded())
        pdf.attach(xml, name: "factur-x.xml", mimeType: "text/xml", relationship: .alternative)

        let data = pdf.render(standard: .pdfA3b)

        XCTAssertEqual(extracted(data, named: "factur-x.xml"), xml)
        XCTAssertEqual(pdf.conformanceIssues(for: .pdfA3b), [])
        XCTAssertTrue(try raw(data).contains("pdfaid:part"))
    }
}
