# Swift Text PDF

A PDF writer with no dependencies. Invoices, credit notes, quotes and receipts — tables, vector logos, multi-page flow and VAT-compliant wording.

```swift
let invoice = Invoice(
    branding: branding,
    number: "INV-2026-0042",
    from: seller,
    to: buyer,
    items: items,
    totals: [("Subtotal", "£856.00"), ("VAT at 20%", "£154.08")],
    total: [("Total due", "£924.48")]
)
try invoice.save(to: url)     // 7 KB
```

## Why

Generating an invoice usually means shelling out to a browser engine, pulling in a rendering library and its dependency tree, or paying an API to render a document that never leaves your own server.

This writes the PDF directly. It covers what a business document actually needs — text flow, tables, rules, a vector logo, page breaks — and nothing else. No HTML engine, no font embedding, no image codecs.

## Features

- 📄 **Real multi-page flow** — content breaks across pages, headers repeat, footers know the final page count
- 📊 **Tables** — proportional columns, alignment, striping, measured truncation
- ✒️ **Vector logos** — an SVG `path` becomes PDF path operators, sharp at any zoom, a few hundred bytes
- 🧾 **Six document kinds** — invoice, credit note, quote, proforma, receipt, reminder
- 🇪🇺 **VAT-aware** — reverse charge, intra-community supply, export and small-business wording, in English and German
- ✅ **Compliance checks** — the §14 UStG / Article 226 particulars, verified before you send
- 🔒 **Injection-safe** — customer names cannot escape the content stream
- 🪶 **Zero dependencies**

## Documents

| Kind | For |
|---|---|
| `invoice` | the tax invoice |
| `creditNote` | reversing one — you cannot amend an invoice, so a refund cites it |
| `quote` | pre-sale, no VAT due |
| `proforma` | advance payment; not a tax invoice, and says so |
| `receipt` | proof of payment |
| `reminder` | chasing an overdue invoice |

`complianceWarnings()` checks what the template can see: supplier tax number, both addresses, a sequential number, the date of supply, the customer VAT number where the treatment requires it, and — for a credit note — the invoice it reverses.

Not tax advice, and not exhaustive. It verifies the particulars, not whether the treatment you chose is correct.

## Money is a string, deliberately

Every amount is pre-formatted. Rendering money correctly means knowing the currency's decimal exponent, its thousands convention and its symbol placement, and a layout type has no business guessing at any of that. Format it where the money lives and pass the result.

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

## Requirements

- macOS 14+ / iOS 17+
- Swift 6

## License

MIT — see [LICENSE](LICENSE).
