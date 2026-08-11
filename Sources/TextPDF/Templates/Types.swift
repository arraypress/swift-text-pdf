//
//  Types.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The value types every document template shares.
//
//  Everything money-shaped is a pre-formatted string, deliberately. Rendering
//  an amount correctly means knowing the currency's decimal exponent, its
//  thousands convention and its symbol placement, and a layout type has no
//  business guessing at any of that. Format it where the money lives and pass
//  the result.
//

import Foundation

// MARK: - Party

/// A business or person on a document.
public struct Party: Sendable, Equatable, Codable {

    public let name: String
    public let address: [String]
    public let email: String
    public let taxID: String

    public init(name: String, address: [String] = [], email: String = "", taxID: String = "") {
        self.name = name
        self.address = address
        self.email = email
        self.taxID = taxID
    }

    /// The address block, one string per line.
    public func lines(vatLabel: String = "VAT") -> [String] {
        var lines = address
        if !email.isEmpty { lines.append(email) }
        if !taxID.isEmpty { lines.append("\(vatLabel) \(taxID)") }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Line item

/// One billable line.
public struct LineItem: Sendable, Equatable, Codable {

    public let description: String
    public let amount: String
    public let quantity: String
    public let unitPrice: String

    /// An optional second phrase, set alongside the description.
    public let note: String

    public init(
        description: String,
        amount: String,
        quantity: String = "1",
        unitPrice: String = "",
        note: String = ""
    ) {
        self.description = description
        self.amount = amount
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.note = note
    }
}

// MARK: - VAT

/// A net amount, the rate applied to it, and the tax that produced.
///
/// Required as soon as a document mixes rates — §14(1) UStG and Article 226 of
/// the VAT Directive both want the taxable amount shown per rate, not one
/// combined tax figure.
public struct VatLine: Sendable, Equatable, Codable {

    public let rate: String
    public let net: String
    public let vat: String
    public let label: String

    public init(rate: String, net: String, vat: String, label: String = "") {
        self.rate = rate
        self.net = net
        self.vat = vat
        self.label = label
    }
}

/// How VAT is being handled.
///
/// Where VAT is not charged at the normal domestic rate, the document has to
/// say why — and in most of the EU it has to say why in specific words. A
/// document missing that wording can be refused as evidence for the
/// recipient's input-tax deduction, which turns a formatting oversight into
/// their tax problem and your support ticket.
///
/// **This is not tax advice.** Which treatment applies depends on facts this
/// library cannot see. It only makes sure the note you chose is printed
/// correctly and prominently.
public enum VatTreatment: String, Sendable, CaseIterable, Codable {

    /// Ordinary domestic VAT at the applicable rate.
    case standard

    /// Cross-border B2B supply where the customer accounts for the VAT.
    case reverseCharge

    /// Zero-rated intra-community supply of goods.
    case intraCommunitySupply

    /// Supply to a customer outside the EU.
    case export

    /// Small-business exemption — §19 UStG in Germany.
    case smallBusiness

    /// Exempt for another reason.
    case exempt

    /// The wording that must appear on the document.
    public func notes(german: Bool = false) -> [String] {
        let english: [String]
        switch self {
        case .standard:
            return []
        case .reverseCharge:
            english = [
                "Reverse charge: VAT to be accounted for by the recipient.",
                "Article 196, Council Directive 2006/112/EC.",
            ]
        case .intraCommunitySupply:
            english = [
                "Zero-rated intra-community supply.",
                "Article 138, Council Directive 2006/112/EC.",
            ]
        case .export:
            english = ["Zero-rated export outside the European Union."]
        case .smallBusiness:
            english = ["No VAT charged under the small-business scheme."]
        case .exempt:
            english = ["Exempt from VAT."]
        }

        guard german else { return english }

        let germanNote: [String]
        switch self {
        case .reverseCharge: germanNote = ["Steuerschuldnerschaft des Leistungsempfängers (§ 13b UStG)."]
        case .intraCommunitySupply: germanNote = ["Steuerfreie innergemeinschaftliche Lieferung (§ 4 Nr. 1b UStG)."]
        case .export: germanNote = ["Steuerfreie Ausfuhrlieferung (§ 4 Nr. 1a UStG)."]
        case .smallBusiness: germanNote = ["Gemäß § 19 UStG wird keine Umsatzsteuer berechnet."]
        case .exempt: germanNote = ["Steuerfrei."]
        case .standard: germanNote = []
        }
        return english + germanNote
    }

    /// Whether both parties' VAT numbers must appear.
    ///
    /// Mandatory for reverse charge and intra-community supply — the
    /// recipient's number evidences their status, and without it the zero
    /// rating is not supportable.
    public var requiresBothVatNumbers: Bool {
        self == .reverseCharge || self == .intraCommunitySupply
    }
}

// MARK: - Branding

/// How a document looks, separated from what it says, so one definition
/// styles everything you issue.
public struct Branding: Sendable, Equatable, Codable {

    public let name: String
    public let tagline: String

    /// Brand colour as hex. Black by default: a monochrome document is harder
    /// to date, prints correctly on any device, stays legible when
    /// photocopied, and never clashes with the recipient's own paperwork.
    public let accent: String

    /// An SVG `d` attribute for a vector mark.
    public let logoPath: String?

    /// The viewBox height that path was drawn in.
    public let logoBox: Double

    public let address: [String]

    /// Small print for the page foot.
    public let footnotes: [String]

    public init(
        name: String,
        tagline: String = "",
        accent: String = "#111111",
        logoPath: String? = nil,
        logoBox: Double = 100,
        address: [String] = [],
        footnotes: [String] = []
    ) {
        self.name = name
        self.tagline = tagline
        self.accent = accent
        self.logoPath = logoPath
        self.logoBox = logoBox
        self.address = address
        self.footnotes = footnotes
    }

    public var accentColor: Color { .hex(accent) }

    /// Secondary text.
    public var muted: Color { .grey(115) }

    /// Primary text. Not pure black — slightly lifted reads better in print
    /// and on screen, and is what most well-set documents use.
    public var ink: Color { .grey(32) }

    /// Faint fill for banded rows and panels.
    public var wash: Color { .grey(250) }

    /// Hairline for rules and borders.
    public var hairline: Color { .grey(214) }

    /// Whether this branding is effectively monochrome.
    public var isMonochrome: Bool {
        let colour = accentColor
        return colour.red == colour.green && colour.green == colour.blue
    }
}
