//
//  EncryptionTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import CryptoKit
import PDFKit
import XCTest
@testable import TextPDF

final class EncryptionTests: XCTestCase {

    private let password = "correct horse battery staple"

    private func payslip(password: String = "correct horse battery staple") -> Data {
        let pdf = Document()
        pdf.text("Payslip — March 2026", size: 16)
        pdf.gap(8)
        pdf.text("Alex Moreau — net pay £2,481.06")
        pdf.bookmark("Payslip")
        pdf.linked("payroll@meridianstudio.co.uk", url: "mailto:payroll@meridianstudio.co.uk",
                   x: 60, y: 600, size: 10)
        return pdf.render(metadata: ["Title": "Payslip — Alex Moreau", "Author": "Meridian Studio Ltd"],
                          password: password)
    }

    private func raw(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    // MARK: It locks

    func testTheDocumentIsLocked() throws {
        let document = try XCTUnwrap(PDFDocument(data: payslip()))
        XCTAssertTrue(document.isLocked)
    }

    func testTheWrongPasswordIsRefused() throws {
        let document = try XCTUnwrap(PDFDocument(data: payslip()))
        XCTAssertFalse(document.unlock(withPassword: "hunter2"))
        XCTAssertFalse(document.unlock(withPassword: ""))
        XCTAssertTrue(document.isLocked)
    }

    func testTheRightPasswordOpensIt() throws {
        let document = try XCTUnwrap(PDFDocument(data: payslip()))
        XCTAssertTrue(document.unlock(withPassword: password))
        XCTAssertFalse(document.isLocked)
        XCTAssertTrue(try XCTUnwrap(document.string).contains("net pay £2,481.06"))
    }

    func testASecondParserAgrees() throws {
        // PDFKit and CoreGraphics are different implementations, and a file
        // only one of them accepts is a file somebody cannot open.
        let provider = try XCTUnwrap(CGDataProvider(data: payslip() as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))

        XCTAssertTrue(document.isEncrypted)
        XCTAssertFalse(document.isUnlocked)
        XCTAssertFalse(document.unlockWithPassword("hunter2"))
        XCTAssertTrue(document.unlockWithPassword(password))
        XCTAssertEqual(document.numberOfPages, 1)
    }

    // MARK: Nothing is left in the open

    func testTheContentIsNotInTheFile() throws {
        let rendered = try raw(payslip())

        XCTAssertFalse(rendered.contains("2,481.06"), "the pay is readable without the password")
        XCTAssertFalse(rendered.contains("Payslip — March"), "the heading is readable")
    }

    func testTheMetadataIsNotEither() throws {
        // A document whose contents are locked but whose title reads
        // "Payslip — Alex Moreau" has told anybody who looks most of what
        // they wanted.
        let rendered = try raw(payslip())
        XCTAssertFalse(rendered.contains("Alex Moreau"), "the title is in the clear")
        XCTAssertFalse(rendered.contains("Meridian Studio Ltd"), "the author is in the clear")
    }

    func testBookmarksAndLinksAreNotEither() throws {
        let rendered = try raw(payslip())
        XCTAssertFalse(rendered.contains("payroll@meridianstudio.co.uk"), "the link is in the clear")
        XCTAssertFalse(rendered.contains("/Title (Payslip)"), "the outline entry is in the clear")
    }

    func testTheEncryptionDictionaryIsThere() throws {
        let rendered = try raw(payslip())

        XCTAssertTrue(rendered.contains("/Filter /Standard"))
        XCTAssertTrue(rendered.contains("/V 5"), "not the AES-256 handler")
        XCTAssertTrue(rendered.contains("/R 6"))
        XCTAssertTrue(rendered.contains("/CFM /AESV3"))
        XCTAssertTrue(rendered.contains("/Encrypt "), "the trailer does not point at it")
        XCTAssertTrue(rendered.contains("/ID [<"), "an encrypted file needs an identifier")
    }

    // MARK: What survives

    func testAnImageSurvivesBeingEncrypted() throws {
        let pdf = Document()
        pdf.image(try EmbeddedImage.load(Fixtures.jpeg), x: 40, y: 400, width: 200, height: 105)

        let document = try XCTUnwrap(PDFDocument(data: pdf.render(password: password)))
        XCTAssertTrue(document.unlock(withPassword: password))
        XCTAssertEqual(document.pageCount, 1)
    }

    func testAnEmbeddedFontSurvives() throws {
        let arial = URL(fileURLWithPath: "/Library/Fonts/Arial Unicode.ttf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arial.path), "no face to embed")

        let pdf = Document()
        pdf.text("Ярослав Кузнецов", size: 14, face: try EmbeddedFont.load(arial))

        let document = try XCTUnwrap(PDFDocument(data: pdf.render(password: password)))
        XCTAssertTrue(document.unlock(withPassword: password))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Ярослав"),
                      "the subset font did not survive encryption")
    }

    func testAnAttachmentSurvives() throws {
        let xml = Data("<invoice/>".utf8)
        let pdf = Document()
        pdf.text("Invoice")
        pdf.attach(xml, name: "factur-x.xml", mimeType: "text/xml")

        let data = pdf.render(password: password)
        XCTAssertFalse(try raw(data).contains("<invoice/>"), "the attachment is in the clear")

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(document.unlock(withPassword: password))
    }

    func testAMultiPageDocumentSurvives() throws {
        let pdf = Document()
        for page in 1...3 {
            if page > 1 { pdf.pageBreak() }
            pdf.text("Page \(page)", size: 14)
        }

        let document = try XCTUnwrap(PDFDocument(data: pdf.render(password: password)))
        XCTAssertTrue(document.unlock(withPassword: password))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Page 3"))
    }

    // MARK: Refusing

    func testAnEmptyPasswordLocksNothing() throws {
        // A document encrypted with nothing opens with a return key, which is
        // worse than an unencrypted one: it claims a protection it lacks.
        let document = try XCTUnwrap(PDFDocument(data: payslip(password: "")))
        XCTAssertFalse(document.isLocked)
        XCTAssertFalse(try raw(payslip(password: "")).contains("/Encrypt"))
    }

    func testTwoDocumentsWithTheSamePasswordDiffer() throws {
        // The key is random per document, not derived from the password, so
        // one recovered key does not open the next payslip.
        XCTAssertNotEqual(payslip(), payslip())
    }

    func testAPasswordOutsideASCIIIsRefused() throws {
        // The format allows it and this wrote it correctly — CoreGraphics
        // opened the file. PDFKit did not, and PDFKit is Preview. A password
        // that works in one reader and not the one your recipient has is
        // worse than being told to pick another.
        let problem = try XCTUnwrap(Document.passwordProblem("Käsestraße-1990"))
        XCTAssertTrue(problem.contains("ASCII"), problem)
        XCTAssertTrue(problem.contains("Preview"), problem)
    }

    func testAnOrdinaryPasswordHasNoProblem() {
        XCTAssertNil(Document.passwordProblem("correct horse battery staple"))
        XCTAssertNil(Document.passwordProblem(""), "no password is not a problem, it is no lock")
    }

    func testALongPasswordWorks() throws {
        let secret = String(repeating: "a very long passphrase ", count: 20)
        let pdf = Document()
        pdf.text("Locked")

        let document = try XCTUnwrap(PDFDocument(data: pdf.render(password: secret)))
        XCTAssertTrue(document.unlock(withPassword: secret))
    }

    // MARK: The hardened hash

    func testTheHashIsNotASingleDigest() throws {
        // Algorithm 2.B is sixty-four rounds at minimum. A single SHA-256
        // would let a password list be tried at the speed of a hash.
        let hashed = Encryption.hardened(password: Data("password".utf8),
                                         salt: Data(count: 8), extra: Data())
        XCTAssertEqual(hashed.count, 32)
        XCTAssertNotEqual(hashed, Data(SHA256.hash(data: Data("password".utf8) + Data(count: 8))))
    }

    func testTheSameInputsGiveTheSameHash() throws {
        let salt = Data((0..<8).map { UInt8($0) })
        XCTAssertEqual(
            Encryption.hardened(password: Data("x".utf8), salt: salt, extra: Data()),
            Encryption.hardened(password: Data("x".utf8), salt: salt, extra: Data())
        )
    }

    func testADifferentSaltGivesADifferentHash() throws {
        XCTAssertNotEqual(
            Encryption.hardened(password: Data("x".utf8), salt: Data(count: 8), extra: Data()),
            Encryption.hardened(password: Data("x".utf8), salt: Data(repeating: 1, count: 8), extra: Data())
        )
    }
}
