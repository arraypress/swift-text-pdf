# Swift Text PDF

A PDF writer with no package dependencies. Text flow, tables, vector paths, embedded typefaces, images and multi-page layout — the page, not what goes on it.

```swift
let pdf = Document(size: .a4, margin: 48)

pdf.text("Statement of account", size: 18, face: .bold)
pdf.gap(12)
pdf.table(
    columns: [.init(title: "Description", width: 3), .init(title: "Amount", width: 1, align: .right)],
    rows: [["Consultancy, July", "£1,240.00"], ["Expenses", "£86.40"]]
)
pdf.rule()

try pdf.render().write(to: url)     // 3 KB
```

## Why

Generating a PDF usually means shelling out to a browser engine, pulling in a rendering library and its dependency tree, or paying an API to render a document that never leaves your own server.

This writes the PDF directly. It covers what a document actually needs — text flow, tables, rules, curves, a vector logo, an embedded typeface, an image, page breaks — and nothing else. No HTML engine, no rendering library, no service, and nothing outside the system frameworks.

**Business documents live next door.** Invoices, statements, timesheets, royalty statements, aged analyses and customs paperwork — with their VAT wording and compliance checks — are [swift-invoice-pdf](https://github.com/arraypress/swift-invoice-pdf), which is built on this. Résumés and CVs are [swift-resume-pdf](https://github.com/arraypress/swift-resume-pdf). This package is the framework both of them draw on.

## Features

- 📄 **Real multi-page flow** — content breaks across pages, headers repeat, footers know the final page count
- 📊 **Tables** — proportional columns, alignment, striping, measured truncation
- ✒️ **Vector logos** — an SVG `path` becomes PDF path operators, sharp at any zoom, a few hundred bytes
- 🔒 **Injection-safe** — a customer's name cannot escape the content stream
- ✒️ **Real typography** — embed a family, with metrics from the face and only the glyphs used carried
- ⭕ **Curves** — circles, rings, arcs, rounded rectangles and meters, built from Béziers rather than approximated
- 📷 **JPEG and PNG** — JPEG passed through undecoded, PNG decoded and re-deflated with transparency intact
- ⬌ **Justified text** — set word by word, so it works with an embedded family too
- 🔗 **Clickable links** — invisible annotations over drawn text, so a URL is not a string somebody has to retype
- 💧 **Watermarks** — rotation and constant alpha, so DRAFT sits behind the content rather than over the total
- ▦ **QR codes** — drawn as vector squares, sharp at any zoom; a bitmap at the wrong scale is a code a scanner works for
- 📎 **Attachments and PDF/A-3** — carry the XML inside the document, which is what an e-invoice is
- 🔖 **Bookmarks** — an outline for anything longer than a scroll
- ┈ **Dashed rules** — a signature line, a cut-here, a leader
- 🪶 **No package dependencies** — Foundation and the system's own frameworks, nothing from SwiftPM

## An e-invoice, and other files carried inside

Germany's e-invoicing mandate is phasing in, France's follows, Italy's has been running for years — and what they want is the *structured* half of an invoice. Factur-X and ZUGFeRD say how: a PDF/A-3 with the invoice XML attached, so one file is both the document a person reads and the record a system parses.

```swift
pdf.attach(xml, name: "factur-x.xml", mimeType: "text/xml", relationship: .alternative)
let data = pdf.render(metadata: ["Title": "INV-2026-0042"], standard: .pdfA3b)
```

That writes the metadata packet, the sRGB output intent and the file identifier conformance requires. What it cannot do on your behalf is embed the reader's own fonts, so:

```swift
pdf.conformanceIssues(for: .pdfA3b)
// ["Text is set in the base-14 fonts, which are not embedded. …"]
```

A document set in Helvetica cannot be PDF/A whatever else it does — the base-14 faces belong to the reader, and PDF/A carries everything it needs. That is reported rather than claimed falsely.

## Watermarks, and marks on the page

```swift
pdf.watermark("DRAFT")                       // behind the content, 45°, faint
pdf.watermark("VOID", over: true)            // over it, when obscuring is the point
pdf.transparent(0.1) { … }                   // constant alpha for anything
pdf.rotated(by: 90, around: x, y) { … }      // a turned column heading
pdf.line(from: x, y, to: x2, y, dash: [2, 2])
pdf.bookmark("Statement")
```

## Scan to pay

```swift
pdf.qr(epcPayload, x: 48, y: 560, size: 150)
```

Drawn as vector squares rather than embedded as a picture, so it stays sharp at any zoom and on any printer. Returns `false` rather than drawing an unreadable smudge when the text will not fit the densest grid.

## Examples

Nine pages showing what goes on a page — tables, curves, vector paths, typography, images, links — [as PDFs](Examples).

## Setting a document in a typeface

The base-14 fonts are the default because a business document is better for
being unremarkable. Where the typography *is* the point, attach a family and it
sets everything:

```swift
var inter = FontFamily(name: "Inter")
inter.add(try EmbeddedFont.load(regularURL), weight: .regular)
inter.add(try EmbeddedFont.load(semiboldURL), weight: .semibold)
inter.add(try EmbeddedFont.load(italicURL), weight: .regular, italic: true)

let pdf = Document()
pdf.family = inter

pdf.text("Alex Morgan", size: 22, font: .helveticaBold)   // Inter SemiBold
pdf.text("Senior Engineer")                                // Inter Regular
pdf.text("Formerly Stripe", face: pdf.face(.regular, italic: true))
```

Existing layout code upgrades without being touched: a template asking for
`.helveticaBold` gets the family's bold. Weights resolve to the nearest face
actually loaded, so a design asking for semibold in a family carrying only
regular and bold gets bold rather than nothing.

Only the faces actually drawn with are embedded, and only the glyphs they use —
a family of nine weights costs whatever the design touches.

Vertical metrics are read from each face rather than assumed at a fixed ratio.
Inter's cap height is 727 units where EB Garamond's is 662, and centring both
on one number leaves one riding high and the other sitting low in the same
band.

## Pictures

JPEG and PNG:

```swift
let portrait = try EmbeddedImage.load(url)
pdf.circularImage(portrait, x: 48, y: 700, diameter: 96)
```

A PDF takes JPEG bytes without decoding them — that is what `/DCTDecode` is — so a JPEG is passed through byte for byte.

PNG cannot be: its zlib runs over filtered scanlines and PDF's `/FlateDecode` runs over raw ones, so the pixels are read out and deflated again. Lossless both ways. The system supplies both halves, so this remains free of any package dependency. Transparency becomes a soft mask — PDF has no notion of an alpha channel inside an image, and a cut-out logo without one arrives on a black square.

Progressive JPEGs and CMYK are refused with the reason rather than embedded: both would produce a file that opens and shows nothing.

## Justified text

```swift
pdf.block(prose, x: 56, width: 300, size: 10, align: .justified)
```

Set a word at a time rather than with the `Tw` operator. Tw adds its space to byte 32, and under Identity-H — how every embedded font here is encoded — byte 32 is half of a two-byte character code, not a space. A document set in an embedded family would come out with gaps inside its words.

The last line of a paragraph is left ragged. Stretching four words across a full measure is what makes justified text look like a ransom note.

## Text beyond Latin-1

The base-14 fonts every reader is required to have cover Windows-1252 and nothing else, so Greek, Cyrillic and CJK come out as `?` — visibly, rather than silently vanishing. Point the document at a TrueType font and they render properly:

```swift
let pdf = Document(size: .a4, margin: 48)
pdf.embeddedFont = try EmbeddedFont.load(URL(fileURLWithPath: "/Library/Fonts/Arial Unicode.ttf"))

pdf.text("ООО «Ромашка», ул. Тверская 7, Москва")
pdf.text("株式会社サンプル")
pdf.text("Invoice INV-001")        // stays in Helvetica
```

Only the runs that need it are embedded, and only the glyphs they use: a document with one Cyrillic name carries a few kilobytes of font, not the 23 MB the file came from. Latin text keeps the base fonts, so the typography does not change under you.

Whatever still could not be drawn is listed in `document.substitutions` after rendering, so a name printed as `???????` is something you can report rather than something a customer finds.

**Arabic and Hebrew are refused, not embedded.** Both run right to left and Arabic letters change shape by position; placing their code points left to right produces disconnected letters in the wrong order. That needs a shaping engine, and being wrong in a language the writer cannot read is worse than declining.

TrueType outlines only — a `.ttf`. PostScript-outline `.otf` files and `.ttc` collections are reported rather than embedded incorrectly.

**Variable fonts are refused too.** One carries a single set of outlines plus the deltas that move them between weights; subsetting keeps the outlines and drops the deltas, so the file would embed cleanly and render every weight as the default instance — a document asking for bold and quietly getting regular. Most projects ship static instances alongside, and that is what to point at. Worth knowing because Google Fonts now distributes nothing else, and most of macOS's own `.ttf` files are variable.

## Requirements

- macOS 14+ / iOS 17+
- Swift 6

## License

MIT — see [LICENSE](LICENSE).
