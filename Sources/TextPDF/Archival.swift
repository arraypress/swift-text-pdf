//
//  Archival.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  PDF/A-3, and the files carried inside a document.
//
//  This exists for one reason: an e-invoice. Germany's mandate is phasing in,
//  France's follows, Italy's has been running for years, and what all of them
//  want is a *structured* invoice — the machine-readable half. Factur-X and
//  ZUGFeRD say how: a PDF/A-3 with the invoice XML attached to it, so the
//  same file is both the document a person reads and the record a system
//  parses. Neither half is a rendering of the other; they travel together.
//
//  So a document can carry files, and can be written to conform.
//
//  ## What conformance costs
//
//  PDF/A forbids anything the file does not carry with it, which for this
//  writer means one thing: **every font must be embedded**. The base-14 faces
//  are not, and cannot be — they are the reader's. A document set in
//  Helvetica cannot be PDF/A whatever else it does, so asking for conformance
//  reports it rather than writing a file that claims a standard it fails.
//

import CoreGraphics
import Foundation

extension Document {

    /// Which standard the file should claim.
    public enum Standard: String, Sendable, CaseIterable {

        /// An ordinary PDF.
        case none

        /// PDF/A-3B: archivable, and allowed to carry attachments of any kind.
        /// The level Factur-X and ZUGFeRD are built on.
        case pdfA3b
    }

    /// How a carried file relates to the document.
    ///
    /// Not decoration: a Factur-X reader looks for `.alternative` to find the
    /// invoice XML, and a file attached as `.unspecified` is one it will not
    /// look at.
    public enum FileRelationship: String, Sendable, CaseIterable {

        /// The same content in another form — the invoice as XML.
        case alternative = "Alternative"

        /// What the document was made from.
        case source = "Source"

        /// Something the document refers to.
        case data = "Data"

        /// Supplementary material.
        case supplement = "Supplement"

        case unspecified = "Unspecified"
    }

    /// Attaches a file to the document.
    ///
    /// - Parameters:
    ///   - name: The filename a reader offers when saving it out.
    ///     `factur-x.xml` is the one Factur-X requires, exactly.
    ///   - relationship: How it relates to what is drawn. A reader looking
    ///     for structured data reads this to decide what to open.
    @discardableResult
    public func attach(
        _ contents: Data,
        name: String,
        mimeType: String = "application/octet-stream",
        description: String = "",
        relationship: FileRelationship = .unspecified,
        modified: Date? = nil
    ) -> Document {
        let filename = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, !contents.isEmpty else { return self }

        attachments.removeAll { $0.name == filename }
        attachments.append(
            Attachment(name: filename, contents: contents, mimeType: mimeType,
                       description: description, relationship: relationship,
                       modified: modified)
        )
        return self
    }

    /// A file carried inside the document.
    struct Attachment {
        let name: String
        let contents: Data
        let mimeType: String
        let description: String
        let relationship: FileRelationship
        let modified: Date?
    }

    // MARK: Conformance

    /// Why this document would not satisfy the standard it was asked for.
    ///
    /// Read after rendering, like ``fallbacks``. Empty means the file claims
    /// nothing it does not meet.
    public func conformanceIssues(for standard: Standard) -> [String] {
        guard standard != .none else { return [] }

        var issues: [String] = []

        // The one this writer can actually violate. PDF/A carries everything
        // it needs; the base-14 faces belong to the reader, so a document
        // drawn in them depends on a machine it has never met.
        if usesBaseFonts {
            issues.append(
                "Text is set in the base-14 fonts, which are not embedded. "
                    + "PDF/A requires every font to travel with the file — "
                    + "attach a family with `pdf.family` or pass `face:`."
            )
        }

        return issues
    }
}

// MARK: - The pieces a conforming file needs

enum Archival {

    /// The sRGB profile, from the system rather than from a file on disk.
    ///
    /// PDF/A wants an output intent so a colour means the same thing in
    /// twenty years as it does today. Asking CoreGraphics for the profile
    /// avoids both a licensing question and a build-time asset.
    static func sRGBProfile() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = space.copyICCData() as Data?
        else { return nil }
        return data
    }

    /// The XMP packet a PDF/A file must carry.
    ///
    /// The title, author and dates have to agree with the document
    /// information dictionary — a validator compares them, and a file whose
    /// two halves disagree fails for that alone.
    static func metadata(
        _ info: [String: String], creationDate: Date, standard: Document.Standard
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: creationDate)

        func field(_ key: String) -> String {
            (info[key] ?? info[key.lowercased()] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let title = xmlEscaped(field("Title"))
        let author = xmlEscaped(field("Author"))
        let subject = xmlEscaped(field("Subject"))

        var dublin = ""
        if !title.isEmpty {
            dublin += "\n      <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)"
                + "</rdf:li></rdf:Alt></dc:title>"
        }
        if !author.isEmpty {
            dublin += "\n      <dc:creator><rdf:Seq><rdf:li>\(author)</rdf:li></rdf:Seq></dc:creator>"
        }
        if !subject.isEmpty {
            dublin += "\n      <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(subject)"
                + "</rdf:li></rdf:Alt></dc:description>"
        }

        let part = standard == .pdfA3b
            ? """

              <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
                <pdfaid:part>3</pdfaid:part>
                <pdfaid:conformance>B</pdfaid:conformance>
              </rdf:Description>
            """
            : ""

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\(dublin)
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <xmp:CreateDate>\(stamp)</xmp:CreateDate>
              <xmp:ModifyDate>\(stamp)</xmp:ModifyDate>
              <xmp:CreatorTool>arraypress/swift-text-pdf</xmp:CreatorTool>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
              <pdf:Producer>arraypress/swift-text-pdf</pdf:Producer>
            </rdf:Description>\(part)
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// A stable file identifier, from what the file contains.
    ///
    /// The trailer wants two strings; for a file written once they are the
    /// same. Derived from the content rather than randomly, so writing the
    /// same document twice produces the same bytes — which is what makes a
    /// committed example diffable.
    static func identifier(_ seed: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return String(format: "%016lX%016lX", hash, hash &* 0x9E37_79B9_7F4A_7C15)
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
