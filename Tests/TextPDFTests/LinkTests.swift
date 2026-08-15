//
//  LinkTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Link areas, read back by a reader that knows what one is.
//

import PDFKit
import XCTest
@testable import TextPDF

final class LinkTests: XCTestCase {

    private func open(_ pdf: Data) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: pdf), "PDFKit refused the file")
    }

    /// Every link annotation PDFKit finds on a page.
    private func links(_ document: PDFDocument, page index: Int = 0) throws -> [(url: String, bounds: CGRect)] {
        let page = try XCTUnwrap(document.page(at: index))
        return page.annotations.compactMap { annotation in
            guard let url = annotation.url ?? annotation.action.flatMap({ ($0 as? PDFActionURL)?.url }) else {
                return nil
            }
            return (url.absoluteString, annotation.bounds)
        }
    }

    func testALinkIsReadBackWithItsURL() throws {
        let pdf = Document()
        pdf.linked("github.com/alexmoreau", url: "https://github.com/alexmoreau",
                   x: 60, y: 700, size: 10)

        let found = try links(try open(pdf.render()))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.url, "https://github.com/alexmoreau")
    }

    func testTheLinkAreaCoversTheText() throws {
        let pdf = Document()
        let text = "github.com/alexmoreau"
        pdf.linked(text, url: "https://github.com/alexmoreau", x: 60, y: 700, size: 10)

        let bounds = try XCTUnwrap(try links(try open(pdf.render())).first?.bounds)
        let measured = pdf.width(of: text, size: 10)

        XCTAssertEqual(bounds.width, measured, accuracy: 1, "the box does not match the text")
        XCTAssertGreaterThan(bounds.height, 8)
        XCTAssertLessThan(abs(bounds.minX - 60), 1)
    }

    func testTextIsStillSelectable() throws {
        let pdf = Document()
        pdf.linked("alex@moreau.dev", url: "mailto:alex@moreau.dev", x: 60, y: 700, size: 10)

        let read = try XCTUnwrap(try open(pdf.render()).string)
        XCTAssertTrue(read.contains("alex@moreau.dev"), read)
    }

    func testLinksAttachToTheirOwnPage() throws {
        let pdf = Document()
        pdf.linked("one.example", url: "https://one.example", x: 60, y: 700, size: 10)
        pdf.pageBreak()
        pdf.linked("two.example", url: "https://two.example", x: 60, y: 700, size: 10)

        let document = try open(pdf.render())
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(try links(document, page: 0).first?.url, "https://one.example")
        XCTAssertEqual(try links(document, page: 1).first?.url, "https://two.example")
    }

    func testAFooterLinkLandsOnEveryPageItWasDrawnOn() throws {
        // The bug this guards: by the time the per-page callbacks run the
        // document is finished, so "the current page" is the last one and
        // every footer link piled onto it.
        let pdf = Document()
        pdf.text("one")
        pdf.pageBreak()
        pdf.text("two")

        pdf.onEachPage { doc, _, _ in
            doc.link("https://moreau.dev", x: 60, y: 40, width: 100, height: 10)
        }

        let document = try open(pdf.render())
        XCTAssertEqual(try links(document, page: 0).count, 1)
        XCTAssertEqual(try links(document, page: 1).count, 1)
    }

    func testAnEmptyURLDrawsNoAnnotation() throws {
        let pdf = Document()
        pdf.link("", x: 60, y: 700, width: 100, height: 10)
        pdf.link("   ", x: 60, y: 680, width: 100, height: 10)
        pdf.text("body")

        XCTAssertTrue(try links(try open(pdf.render())).isEmpty)
    }

    func testAZeroSizedAreaDrawsNoAnnotation() throws {
        let pdf = Document()
        pdf.link("https://moreau.dev", x: 60, y: 700, width: 0, height: 10)
        pdf.text("body")

        XCTAssertTrue(try links(try open(pdf.render())).isEmpty)
    }

    func testParenthesesInAURLDoNotEndTheString() throws {
        // An unescaped ) closes the PDF string early and the file stops being
        // readable at that byte.
        let pdf = Document()
        pdf.linked("wiki", url: "https://en.wikipedia.org/wiki/PDF_(format)",
                   x: 60, y: 700, size: 10)

        let found = try links(try open(pdf.render()))
        XCTAssertEqual(found.first?.url, "https://en.wikipedia.org/wiki/PDF_(format)")
    }
}

// MARK: - Language

extension LinkTests {

    func testTheLanguageIsDeclaredWhenSet() throws {
        let pdf = Document()
        pdf.language = "en-GB"
        pdf.text("body")

        let raw = try XCTUnwrap(String(data: pdf.render(), encoding: .isoLatin1))
        XCTAssertTrue(raw.contains("/Lang (en-GB)"), "no language on the catalog")
    }

    func testNoLanguageIsDeclaredWhenUnset() throws {
        let pdf = Document()
        pdf.text("body")

        let raw = try XCTUnwrap(String(data: pdf.render(), encoding: .isoLatin1))
        XCTAssertFalse(raw.contains("/Lang"), "a language nobody set was guessed at")
        XCTAssertNotNil(PDFDocument(data: pdf.render()))
    }
}
