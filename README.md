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
- 🧾 **Twelve invoice kinds** — invoice, credit note, debit note, quote, proforma, receipt, reminder, remittance advice, self-billed invoice, delivery note, purchase order, order confirmation
- 📚 **Six document types** — invoice, statement of account, timesheet, royalty statement, aged debtors or creditors, and the pair that cross a border
- 🇪🇺 **VAT-aware** — reverse charge, intra-community supply, export and small-business wording, in English and German
- ✅ **Compliance checks** — the §14 UStG / Article 226 particulars, verified before you send
- 🔒 **Injection-safe** — customer names cannot escape the content stream
- ✒️ **Real typography** — embed a family in several weights and italic; metrics come from the face, and only the glyphs used are carried
- 🪶 **Zero dependencies**

## Documents

Six types, because these are genuinely different documents rather than one document with the words changed.

| Type | For |
|---|---|
| `Invoice` | billing, in twelve kinds — see below |
| `Statement` | an account over a period: charges, payments, running balance, aged analysis |
| `Timesheet` | time worked, by day and project — the evidence behind an invoice, and signed by someone else |
| `RoyaltyStatement` | what a contributor earned, and what is actually payable after recoupment |
| `AgedAnalysis` | who owes what, or who you owe — internal, not sent |
| `Consignment` | a commercial invoice or a packing list, for goods crossing a border |

### Invoice kinds

| Kind | For |
|---|---|
| `invoice` | the tax invoice |
| `creditNote` | reversing one — you cannot amend an invoice, so a refund cites it |
| `debitNote` | charging more against an earlier invoice |
| `quote` | pre-sale, no VAT due |
| `proforma` | advance payment; not a tax invoice, and says so |
| `receipt` | proof of payment |
| `reminder` | chasing an overdue invoice |
| `remittance` | telling a supplier what you have just paid, and against what |
| `selfBilling` | the buyer raising the invoice, by prior agreement |
| `deliveryNote` | what was sent, with no prices |
| `purchaseOrder` | ordering |
| `orderConfirmation` | acknowledging an order |

### Royalty statements

Earnings and payment are not the same number, and a statement showing only one of them is why royalty statements have the reputation they do. The template lays out the whole chain — what the distributor sold, what it kept, what reached you, the contributor's split — and then the reconciliation from opening unrecouped balance to what is payable now.

Where nothing is payable, `carriedForwardNote` prints the reason on the document. A statement with earnings and no payment reads as a withholding unless it says otherwise, and that explanation should not live in a covering email.

### Crossing a border

`Consignment` produces a commercial invoice or a packing list. These carry fields a sales invoice has no notion of — a tariff heading and country of origin per line, the delivery term with its named place, net and gross weights — because a customs officer values the consignment from them.

A packing list carries no prices at all. That is the difference between the two documents, not a formatting option: the list is read by people handling the boxes, and in some trades it reaches the buyer's customer.

`complianceWarnings()` checks what the template can see: supplier tax number, both addresses, a sequential number, the date of supply, the customer VAT number where the treatment requires it, and — for a credit note — the invoice it reverses.

`Consignment` has its own, covering the commodity code, origin and weight on every line, the delivery term and the reason for export.

Not tax advice, and not exhaustive. Both verify that the particulars are present, not that they are right — no template can tell whether a commodity code is the correct heading for what is in the box.

## Money is a string, deliberately

Every amount is pre-formatted. Rendering money correctly means knowing the currency's decimal exponent, its thousands convention and its symbol placement, and a layout type has no business guessing at any of that. Format it where the money lives and pass the result.

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
