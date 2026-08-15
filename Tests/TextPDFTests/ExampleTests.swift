//
//  ExampleTests.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The examples in the repository, written by the writer itself.
//
//  This package is the framework two document libraries are built on, so its
//  examples are the primitives rather than a finished document: what a table
//  looks like when it breaks across a page, what a curve looks like next to a
//  rectangle, what an embedded family buys over the base-14 fonts. Somebody
//  evaluating this is deciding whether the page will hold what they need, and
//  a feature list does not answer that.
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

    private func put(_ pdf: Document, _ name: String, pages: Int = 1) throws {
        let data = pdf.render(creationDate: Self.stamped)

        // Checked either way: doing this in a test means every example is
        // proved to render on every run, not only when it is written out.
        let document = try XCTUnwrap(PDFDocument(data: data), "\(name) is not a readable PDF")
        XCTAssertEqual(document.pageCount, pages, "\(name) ran to the wrong length")
        XCTAssertGreaterThan(data.count, 800, "\(name) came out suspiciously small")

        guard writing else { return }
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file)
    }

    /// A page with its subject named at the top, so a folder of these can be
    /// flicked through and understood without the README beside it.
    private func page(_ title: String, _ subtitle: String, size: PageSize = .a4) -> Document {
        let pdf = Document(size: size, margin: 48)
        pdf.text(title, size: 20, font: .helveticaBold)
        pdf.gap(2)
        pdf.text(subtitle, size: 9.5, color: .grey(120))
        pdf.gap(18)
        return pdf
    }

    // MARK: Tables

    func testATable() throws {
        let pdf = page("Tables", "Proportional columns, alignment, striping and a total row.")

        Table(headers: ["Description", "Qty", "Unit price", "Amount"])
            .widths([4, 1, 1.4, 1.4])
            .align([1: .right, 2: .right, 3: .right])
            .striped()
            .rows([
                ["Document generation licence — annual", "1", "£149.00", "£149.00"],
                ["Template design and setup", "6", "£70.00", "£420.00"],
                ["Priority support — first year", "1", "£180.00", "£180.00"],
                ["Data migration, per environment", "3", "£95.00", "£285.00"],
            ])
            .total(["Total", "", "", "£1,034.00"])
            .draw(pdf)

        pdf.gap(24)
        pdf.text("Columns are fractions of the measure, not points, so the table fits whatever "
                 + "page and margin it is given. A cell too long for its column is measured and "
                 + "truncated rather than allowed to collide with the next one.", size: 9.5)

        try put(pdf, "tables.pdf")
    }

    func testATableThatBreaksAcrossPages() throws {
        let pdf = page("Multi-page flow", "The table breaks, the header repeats, the footer knows the total.")

        pdf.onEachPage { document, index, total in
            document.line(from: document.left(), 52, to: document.right(), 52,
                          color: .grey(210), thickness: 0.5)
            document.textAt("Multi-page flow", x: document.left(), y: 38, size: 8, color: .grey(130))
            document.textAt("Page \(index) of \(total)", x: document.left(), y: 38, size: 8,
                            color: .grey(130), align: .right, boxWidth: document.contentWidth())
        }

        let table = Table(headers: ["Date", "Reference", "Description", "Amount"])
            .widths([1.2, 1.2, 4, 1.2])
            .align([3: .right])
            .striped()

        for index in 1...48 {
            table.row([
                "\(1 + index % 28) Jul 2026",
                "REF-\(String(format: "%04d", index))",
                "Line \(index) — the table carries on until the page runs out",
                "£\(index * 7).00",
            ])
        }
        table.draw(pdf)

        try put(pdf, "multi-page.pdf", pages: 2)
    }

    // MARK: Shapes

    func testCurvesAndShapes() throws {
        let pdf = page("Curves", "Circles, rings, arcs, rounded rectangles and meters, built from Béziers.")

        let ink = Color.grey(40)
        let accent = Color.hex("#1F3A5F")
        var y = pdf.cursor() - 60

        pdf.circle(x: pdf.left() + 40, y: y, radius: 34, color: accent)
        pdf.ring(x: pdf.left() + 140, y: y, radius: 34, thickness: 6, color: accent)
        pdf.arc(x: pdf.left() + 240, y: y, radius: 34, from: 40, to: 320,
                thickness: 6, color: accent)
        pdf.polygon([
            (x: pdf.left() + 320, y: y - 34),
            (x: pdf.left() + 388, y: y - 34),
            (x: pdf.left() + 354, y: y + 34),
        ], color: accent)

        pdf.move(to: y - 70)
        pdf.text("circle · ring · arc · polygon", size: 8.5, color: .grey(120))

        y = pdf.cursor() - 40
        for (index, radius) in [2.0, 8.0, 20.0, 40.0].enumerated() {
            pdf.roundedRect(x: pdf.left() + Double(index) * 118, y: y - 56,
                            width: 100, height: 56, radius: radius, color: .grey(232))
            pdf.textAt("r = \(Int(radius))", x: pdf.left() + Double(index) * 118 + 8,
                       y: y - 34, size: 9, color: ink)
        }

        pdf.move(to: y - 78)
        pdf.text("rounded rectangles — the radius is clamped to the shorter side, so a pill "
                 + "asked for as r = 400 is a pill rather than a knot", size: 8.5, color: .grey(120))

        pdf.gap(30)
        for fraction in [0.0, 0.25, 0.5, 0.85, 1.0] {
            pdf.meter(x: pdf.left(), y: pdf.cursor(), width: 300, height: 9,
                      fraction: fraction, color: accent)
            pdf.textAt("\(Int(fraction * 100))%", x: pdf.left() + 314, y: pdf.cursor() + 1,
                       size: 8.5, color: .grey(120))
            pdf.gap(20)
        }

        try put(pdf, "curves.pdf")
    }

    func testAVectorPath() throws {
        let pdf = page("Vector paths", "An SVG path becomes PDF path operators — sharp at any zoom, a few hundred bytes.")

        // A mark drawn once and stamped at four sizes. A raster would go soft
        // at the largest; this is the same handful of operators each time.
        let mark = "M12 2 L22 20 L2 20 Z M12 8 L17.5 18 L6.5 18 Z"
        var x = pdf.left()
        for scale in [1.5, 3.0, 5.0, 8.0] {
            pdf.svgPath(mark, x: x, y: pdf.cursor() - 20, scale: scale, color: .hex("#1F3A5F"))
            x += 24 * scale + 24
        }

        pdf.move(to: pdf.cursor() - 200)
        pdf.text("The same twelve path operators at four scales. Zoom in: the edges stay sharp, "
                 + "because there is nothing to resample.", size: 9.5)

        try put(pdf, "vector-path.pdf")
    }

    // MARK: Type

    func testTheBaseFontsAndAnEmbeddedFamily() throws {
        let inter = try? family()

        let pdf = page("Typography", "The base-14 fonts, and an embedded family beside them.")
        let sample = "Handgloves — 0123456789 £€ ffi"

        pdf.text("Base-14, carried by every reader", size: 10, font: .helveticaBold)
        pdf.gap(6)
        for font in [Font.helvetica, .helveticaBold, .courier] {
            pdf.text("\(sample)   \(font.rawValue)", size: 11, font: font)
            pdf.gap(4)
        }

        pdf.gap(18)
        pdf.text("Embedded, subset to the glyphs used", size: 10, font: .helveticaBold)
        pdf.gap(6)

        if let inter {
            for weight in [FontFamily.Weight.regular, .medium, .semibold, .bold] {
                pdf.text("\(sample)   Inter \(weight)", size: 11, face: inter.face(weight))
                pdf.gap(4)
            }
            pdf.text("\(sample)   Inter italic", size: 11, face: inter.face(.regular, italic: true))
        } else {
            pdf.text("(no family to hand — this page is the base-14 half only)", size: 10,
                     color: .grey(140))
        }

        pdf.gap(20)
        pdf.text("A page carrying three weights costs about 50 KB, because only the glyphs "
                 + "actually drawn are carried — not the 2 MB the files came from.", size: 9.5)

        try put(pdf, "typography.pdf")
    }

    func testJustifiedAgainstRagged() throws {
        let pdf = page("Justified text", "Set word by word, so it works with an embedded family too.")

        let prose = """
            A PDF has no line breaking of its own: every line is placed at a coordinate by \
            whoever writes the file. Justifying means measuring the words, dividing what is \
            left of the measure between the gaps, and setting each word at its own position — \
            which is why it works with an embedded face, whose widths come from the font \
            rather than from a table of assumptions.
            """

        let half = (pdf.contentWidth() - 24) / 2

        pdf.text("Ragged right", size: 9.5, font: .helveticaBold)
        pdf.gap(4)
        let top = pdf.cursor()
        pdf.block(prose, x: pdf.left(), width: half, size: 9.5)

        let bottom = pdf.cursor()
        pdf.move(to: top + 15)
        pdf.textAt("Justified", x: pdf.left() + half + 24, y: pdf.cursor(), size: 9.5,
                   font: .helveticaBold)
        pdf.move(to: top)
        pdf.block(prose, x: pdf.left() + half + 24, width: half, size: 9.5, align: .justified)

        pdf.move(to: min(bottom, pdf.cursor()) - 24)
        pdf.text("The last line of a paragraph is left ragged. Stretching four words across a "
                 + "full measure is what makes justified text look like a ransom note.", size: 9)

        try put(pdf, "justified.pdf")
    }

    func testTextBeyondLatin1() throws {
        let pdf = page("Beyond Latin-1", "What a fallback face buys, and what its absence costs.")

        let names = ["Ярослав Кузнецов", "Δημήτριος Παπαδόπουλος", "北京市朝阳区"]

        pdf.text("Without an embedded face", size: 10, font: .helveticaBold)
        pdf.gap(6)
        for name in names {
            pdf.text(name, size: 12)
            pdf.gap(3)
        }
        pdf.gap(4)
        pdf.text("The base-14 fonts cover Windows-1252 and nothing else, so these arrive as "
                 + "question marks — visibly, rather than silently vanishing.", size: 9.5,
                 color: .grey(110))

        pdf.gap(20)
        pdf.text("With one", size: 10, font: .helveticaBold)
        pdf.gap(6)

        let unicode = URL(fileURLWithPath: "/Library/Fonts/Arial Unicode.ttf")
        if let face = try? EmbeddedFont.load(unicode) {
            for name in names {
                pdf.text(name, size: 12, face: face)
                pdf.gap(3)
            }
            pdf.gap(4)
            pdf.text("Only the characters actually used are embedded, so one name costs a few "
                     + "kilobytes rather than the size of the font.", size: 9.5, color: .grey(110))
        } else {
            pdf.text("(no Unicode face installed on the machine that generated this)",
                     size: 10, color: .grey(140))
        }

        try put(pdf, "beyond-latin1.pdf")
    }

    // MARK: Pictures and links

    func testPictures() throws {
        let pdf = page("Pictures", "JPEG passed through undecoded; PNG decoded, with transparency kept.")

        pdf.behindEachPage { document, _, _ in
            document.rect(x: 0, y: 0, width: document.width(), height: document.height(),
                          color: .hex("#F4EFE6"))
        }

        let jpeg = try EmbeddedImage.load(Fixtures.jpeg)
        let png = try EmbeddedImage.load(Fixtures.dot)

        let top = pdf.cursor() - 130
        pdf.image(jpeg, x: pdf.left(), y: top, width: 220, height: 116)
        pdf.textAt("JPEG — the file's own bytes, undecoded", x: pdf.left(), y: top - 16,
                   size: 8.5, color: .grey(120))

        pdf.image(png, x: pdf.left() + 260, y: top - 4, width: 120, height: 120)
        pdf.textAt("PNG — decoded, re-deflated, alpha as a soft mask", x: pdf.left() + 260,
                   y: top - 16, size: 8.5, color: .grey(120))

        pdf.move(to: top - 46)
        pdf.text("The tinted page is behind both. A PNG's transparency becomes a soft mask "
                 + "rather than being flattened onto white, which is why the disc has no square "
                 + "around it — and why a cut-out logo can sit on a coloured band.", size: 9.5)

        try put(pdf, "pictures.pdf")
    }

    func testLinks() throws {
        let pdf = page("Links", "Invisible annotations over drawn text, so a URL is not a string to retype.")

        pdf.linked("arraypress.com", url: "https://arraypress.com", x: pdf.left(),
                   y: pdf.cursor(), size: 11, color: .hex("#1F3A5F"))
        pdf.gap(20)
        pdf.linked("accounts@swiftinvoices.co.uk", url: "mailto:accounts@swiftinvoices.co.uk",
                   x: pdf.left(), y: pdf.cursor(), size: 11, color: .hex("#1F3A5F"))
        pdf.gap(28)

        pdf.text("Both of the above are clickable in any reader. The annotation is a rectangle "
                 + "measured against the run it covers, so it stays over the words rather than "
                 + "beside them — and the text is still selectable, because it is text.", size: 9.5)

        try put(pdf, "links.pdf")
    }

    // MARK: A family to draw with

    private func family() throws -> FontFamily {
        // The writer ships no typefaces — that is the document libraries' job —
        // so this page borrows one where the machine has it.
        let candidates = [
            "/Users/\(NSUserName())/Developer/Swift/Libraries/swift-resume-pdf/Sources/ResumePDF/Resources/Fonts",
            "/Library/Fonts",
        ]

        for directory in candidates {
            let base = URL(fileURLWithPath: directory)
            let regular = base.appendingPathComponent("Inter-Regular.ttf")
            guard FileManager.default.fileExists(atPath: regular.path) else { continue }

            var family = FontFamily(name: "Inter")
            family.add(try EmbeddedFont.load(regular), weight: .regular)
            for (file, weight) in [("Inter-Medium.ttf", FontFamily.Weight.medium),
                                   ("Inter-SemiBold.ttf", .semibold),
                                   ("Inter-Bold.ttf", .bold)] {
                let url = base.appendingPathComponent(file)
                if let face = try? EmbeddedFont.load(url) { family.add(face, weight: weight) }
            }
            let italic = base.appendingPathComponent("Inter-Italic.ttf")
            if let face = try? EmbeddedFont.load(italic) {
                family.add(face, weight: .regular, italic: true)
            }
            return family
        }

        throw XCTSkip("no family installed to draw the embedded half with")
    }
}
