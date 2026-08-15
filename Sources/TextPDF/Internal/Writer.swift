//
//  Writer.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Turns page content streams into a PDF file.
//
//  The cross-reference table is the part that has to be exact: readers seek
//  directly to the byte offsets it records, so an off-by-one produces a file
//  that opens in one viewer and fails in another. Offsets are therefore
//  measured from the assembled output rather than calculated.
//

import Foundation

enum Writer {

    /// Encodes a built stream as single-byte text.
    ///
    /// Every string reaching here has already been through
    /// ``PDFEncoding/escape(_:)``, so each scalar is one Windows-1252 byte.
    /// Encoding as UTF-8 would re-expand `£` (U+00A3) into two bytes and the
    /// reader would show `Â£` — the double-encoding that makes a currency
    /// symbol look broken on every invoice.
    private static func bytes(_ string: String) -> Data {
        string.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(string.utf8)
    }

    /// One string literal, as it should appear in the file.
    ///
    /// Encrypted where the document is: a title, an outline entry, a link's
    /// address and an attachment's filename are all strings, and a document
    /// whose contents are locked but whose bookmarks read "Payslip — A
    /// Moreau" has told anybody who looks most of what they wanted.
    static func literal(_ text: String, object: Int, encrypting: Encryption?) -> String {
        guard let encrypting else { return "(\(PDFEncoding.escape(text)))" }
        return "<\(encrypting.encrypt(Data(text.utf8)).hex)>"
    }

    /// Serialises pages into PDF bytes.
    static func write(
        pages: [String],
        width: Double,
        height: Double,
        metadata: [String: String],
        creationDate: Date,
        embedded: [(name: String, font: EmbeddedFont)] = [],
        images: [(name: String, image: EmbeddedImage)] = [],
        annotations: [Int: [Document.Link]] = [:],
        language: String = "",
        alphas: [Double] = [],
        outline: [(title: String, page: Int, y: Double)] = [],
        attachments: [Document.Attachment] = [],
        standard: Document.Standard = .none,
        encryption: Encryption? = nil
    ) -> Data {
        let streams = pages.isEmpty ? [""] : pages

        var objects: [Int: String] = [:]
        var binaries: [Int: Data] = [:]
        var pageRefs: [String] = []

        // 1 Catalog, 2 Pages, 3–5 base fonts, 6 Info, then five objects per
        // embedded face, one per image, then page/content pairs.
        let objectsPerFace = 5
        let firstFace = 7
        let firstImage = firstFace + (embedded.count * objectsPerFace)
        // Two slots per image: the image, and the soft mask it may need. The
        // slot is reserved whether or not the mask exists, because numbering
        // it conditionally would renumber every page after the first
        // transparent PNG.
        let firstPage = firstImage + (images.count * 2)
        let firstOutline = firstPage + (streams.count * 2)
        // Two objects per attachment — the file specification and the stream
        // it points at — then metadata, the output intent and its profile.
        let firstAttachment = firstOutline + (outline.isEmpty ? 0 : outline.count + 1)
        let metadataObject = firstAttachment + (attachments.count * 2)
        let intentObject = metadataObject + 1
        let profileObject = intentObject + 1

        // The resource names come from the caller, which assigned them as the
        // content streams were written. A face whose subset cannot be built
        // keeps its object slot — dropping it would renumber every face after
        // it, and the streams already name them.
        var fontResources = "/F1 3 0 R /F2 4 0 R /F3 5 0 R"
        for (index, face) in embedded.enumerated() {
            let first = firstFace + (index * objectsPerFace)
            guard let parts = face.font.embeddable() else { continue }
            fontResources += " /\(face.name) \(first) 0 R"
            addEmbedded(face.font, parts: parts, at: first, into: &objects, binaries: &binaries)
        }

        var imageResources = ""
        for (index, picture) in images.enumerated() {
            let object = firstImage + (index * 2)
            let maskObject = object + 1

            let mask = picture.image.maskObject()
            let (dictionary, bytes) = picture.image.xobject(mask: mask == nil ? nil : maskObject)

            imageResources += " /\(picture.name) \(object) 0 R"
            objects[object] = "\(dictionary)\nstream\n\u{0}STREAM\u{0}\nendstream"
            binaries[object] = bytes

            if let mask {
                objects[maskObject] = "\(mask.dictionary)\nstream\n\u{0}STREAM\u{0}\nendstream"
                binaries[maskObject] = mask.bytes
            }
        }

        var resources = "/Font <<\(fontResources)>>"
        if !imageResources.isEmpty { resources += " /XObject <<\(imageResources.dropFirst())>>" }

        // Constant alpha lives in a graphics state dictionary rather than in
        // the content stream, so each distinct value is named once and the
        // streams refer to it — /GS0 gs. Written inline: they are three
        // numbers each, and an indirect object apiece would renumber
        // everything after them for nothing.
        if !alphas.isEmpty {
            let states = alphas.enumerated().map { index, alpha in
                String(format: "/GS%d <</Type /ExtGState /ca %.3F /CA %.3F>>", index, alpha, alpha)
            }
            resources += " /ExtGState <<\(states.joined(separator: " "))>>"
        }

        for (index, stream) in streams.enumerated() {
            let pageObject = firstPage + (index * 2)
            let contentObject = pageObject + 1
            pageRefs.append("\(pageObject) 0 R")

            // Link areas are written straight into the array rather than as
            // objects of their own. The specification allows a direct
            // dictionary there, and numbering a dozen annotations would mean
            // renumbering every page after them.
            var annots = ""
            if let links = annotations[index], !links.isEmpty {
                let written = links.map { link in
                    String(
                        format: "<</Type /Annot /Subtype /Link /Rect [%.2F %.2F %.2F %.2F] "
                            + "/Border [0 0 0] /F 4 /A <</Type /Action /S /URI /URI %@>>>>",
                        PDFEncoding.number(link.rect.0), PDFEncoding.number(link.rect.1),
                        PDFEncoding.number(link.rect.2), PDFEncoding.number(link.rect.3),
                        literal(link.url, object: pageObject, encrypting: encryption)
                    )
                }
                annots = " /Annots [\(written.joined(separator: " "))]"
            }

            objects[pageObject] = "<</Type /Page /Parent 2 0 R "
                + "/Resources <<\(resources)>>\(annots) "
                + "/Contents \(contentObject) 0 R>>"

            // One byte per scalar, because the stream is Latin-1 by then.
            if encryption != nil {
                // Handed over as plain bytes, and encrypted with everything
                // else in one pass below. Encrypting it here as well was the
                // bug: the sweep does not know what it has already sealed, so
                // the content went out encrypted twice and decrypted to
                // nothing.
                let plain = bytes(stream)
                objects[contentObject] = "<</Length \(plain.count)>>\nstream\n\u{0}STREAM\u{0}\nendstream"
                binaries[contentObject] = plain
            } else {
                let length = stream.unicodeScalars.count
                objects[contentObject] = "<</Length \(length)>>\nstream\n\(stream)\nendstream"
            }
        }

        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        objects[1] = "<</Type /Catalog /Pages 2 0 R"
            + (tag.isEmpty ? "" : " /Lang (\(PDFEncoding.escape(tag)))")
            + (outline.isEmpty ? "" : " /Outlines \(firstOutline) 0 R /PageMode /UseOutlines")
            + attachmentEntries(attachments, firstObject: firstAttachment, encrypting: encryption)
            + (standard == .none ? "" : " /Metadata \(metadataObject) 0 R "
                + "/OutputIntents [\(intentObject) 0 R]")
            + ">>"
        objects[2] = "<</Type /Pages /Kids [\(pageRefs.joined(separator: " "))] /Count \(streams.count)"
            + String(format: " /MediaBox [0 0 %.2F %.2F]>>", width, height)
        objects[3] = baseFont(.helvetica)
        objects[4] = baseFont(.helveticaBold)
        objects[5] = baseFont(.courier)
        objects[6] = info(metadata, creationDate: creationDate, encrypting: encryption)

        // The outline tree: a root, then one item per bookmark, each naming
        // its neighbours. Flat rather than nested — a document this writes is
        // a document somebody scrolls, and a two-level tree in a statement of
        // account is a filing system nobody asked for.
        var last = firstPage + (streams.count * 2) - 1
        if !outline.isEmpty {
            let first = firstOutline + 1
            let items = outline.indices.map { first + $0 }

            objects[firstOutline] = "<</Type /Outlines /First \(items.first!) 0 R "
                + "/Last \(items.last!) 0 R /Count \(outline.count)>>"

            for (index, entry) in outline.enumerated() {
                let page = firstPage + (min(max(entry.page, 1), streams.count) - 1) * 2
                var item = "<</Title \(literal(entry.title, object: items[index], encrypting: encryption)) "
                    + "/Parent \(firstOutline) 0 R"
                if index > 0 { item += " /Prev \(items[index - 1]) 0 R" }
                if index < items.count - 1 { item += " /Next \(items[index + 1]) 0 R" }
                item += String(format: " /Dest [%d 0 R /XYZ 0 %.2F 0]>>", page, entry.y)
                objects[items[index]] = item
            }
            last = items.last!
        }

        let carried = attachmentObjects(attachments, firstObject: firstAttachment,
                                        encrypting: encryption)
        objects.merge(carried.objects) { _, new in new }
        binaries.merge(carried.binaries) { _, new in new }
        if !attachments.isEmpty { last = max(last, firstAttachment + attachments.count * 2 - 1) }

        let conforming = standardObjects(
            standard, metadata: metadata, creationDate: creationDate,
            metadataObject: metadataObject, intentObject: intentObject,
            profileObject: profileObject
        )
        objects.merge(conforming.objects) { _, new in new }
        binaries.merge(conforming.binaries) { _, new in new }
        if standard != .none { last = max(last, profileObject) }

        var encryptObject: Int?
        if let encryption {
            last += 1
            encryptObject = last
            objects[last] = encryption.dictionary
        }

        // Every binary stream: the subset fonts, the pictures, the carried
        // files, the metadata packet and the colour profile. Encrypted last,
        // after their dictionaries have been written with the plain length —
        // which then has to be corrected, because AES pads and prepends.
        if let encryption {
            for (number, payload) in binaries {
                let sealed = encryption.encrypt(payload)
                binaries[number] = sealed

                if let body = objects[number] {
                    objects[number] = body.replacingOccurrences(
                        of: "/Length \(payload.count)", with: "/Length \(sealed.count)"
                    )
                }
            }
        }

        return serialise(objects, upTo: last, binaries: binaries,
                         version: standard == .none ? "1.4" : "1.7",
                         identifier: Archival.identifier(
                             "\(metadata)\(creationDate.timeIntervalSince1970)\(streams.count)"),
                         encrypt: encryptObject)
    }

    /// Writes the five objects a CID font needs.
    ///
    /// A Type0 wrapper points at a CIDFontType2 descendant, which points at a
    /// descriptor, which points at the subset bytes. The ToUnicode map is what
    /// makes the text selectable and searchable afterwards — without it a
    /// reader shows glyph indices when you copy from the page.
    private static func addEmbedded(
        _ font: EmbeddedFont,
        parts: (data: Data, mapping: [Int: Int], widths: [(cid: Int, width: Int)], toUnicode: [(cid: Int, scalar: UInt32)]),
        at first: Int,
        into objects: inout [Int: String],
        binaries: inout [Int: Data]
    ) {
        let type0 = first, descendant = first + 1, descriptor = first + 2
        let fileObject = first + 3, toUnicodeObject = first + 4

        objects[type0] = "<</Type /Font /Subtype /Type0 /BaseFont /\(font.name) "
            + "/Encoding /Identity-H /DescendantFonts [\(descendant) 0 R] /ToUnicode \(toUnicodeObject) 0 R>>"

        let widths = parts.widths
            .filter { $0.width > 0 }
            .map { "\($0.cid) [\($0.width)]" }
            .joined(separator: " ")

        objects[descendant] = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /\(font.name) "
            + "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> "
            + "/FontDescriptor \(descriptor) 0 R /DW 1000 /W [\(widths)] /CIDToGIDMap /Identity>>"

        // Flags bit 3 marks a symbolic font, which is the honest description
        // of an Identity-H subset: it has no standard character set. Bit 7
        // marks italic, which a reader uses when it has to synthesise a
        // missing face.
        let metrics = font.metrics
        let flags = 4 | (metrics.isItalic ? 64 : 0)

        // StemV has no equivalent in a TrueType file, and readers use it to
        // synthesise a substitute when the embedded font is unavailable.
        // Approximated from the weight class rather than left at a constant
        // that would describe every face as regular.
        let stemV = max(50, Int((Double(metrics.weightClass) / 65).rounded()) * 10 - 10)

        objects[descriptor] = "<</Type /FontDescriptor /FontName /\(font.name) /Flags \(flags) "
            + String(
                format: "/FontBBox [%.0F %.0F %.0F %.0F] /ItalicAngle %.1F /Ascent %.0F /Descent %.0F ",
                metrics.bbox.minX, metrics.bbox.minY, metrics.bbox.maxX, metrics.bbox.maxY,
                metrics.italicAngle, metrics.ascender, metrics.descender
            )
            + String(format: "/CapHeight %.0F ", metrics.capHeight)
            + "/StemV \(stemV) /FontFile2 \(fileObject) 0 R>>"

        objects[fileObject] = "<</Length \(parts.data.count) /Length1 \(parts.data.count)>>\nstream\n\u{0}STREAM\u{0}\nendstream"
        binaries[fileObject] = parts.data

        let cmap = bytes(toUnicodeMap(parts.toUnicode))
        objects[toUnicodeObject] = "<</Length \(cmap.count)>>\nstream\n\u{0}STREAM\u{0}\nendstream"
        binaries[toUnicodeObject] = cmap
    }

    /// A CMap mapping each CID back to the character it came from.
    /// The CMap body that makes the text selectable.
    ///
    /// Returned as bytes rather than as a finished object, so it goes through
    /// the same splice as every other stream — which is what lets one pass
    /// encrypt all of them. Written as text it was the one stream a locked
    /// document never encrypted, and a reader that cannot decrypt this one
    /// extracts no text at all.
    private static func toUnicodeMap(_ pairs: [(cid: Int, scalar: UInt32)]) -> String {
        var body = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange

            """

        // A CMap allows at most 100 entries per block.
        for chunk in stride(from: 0, to: pairs.count, by: 100) {
            let slice = Array(pairs[chunk..<min(chunk + 100, pairs.count)])
            body += "\(slice.count) beginbfchar\n"
            for pair in slice {
                let scalar = Unicode.Scalar(pair.scalar).map { String(String.UnicodeScalarView([$0])) } ?? ""
                let utf16 = Array(scalar.utf16).map { String(format: "%04X", $0) }.joined()
                body += "<\(String(format: "%04X", pair.cid))> <\(utf16)>\n"
            }
            body += "endbfchar\n"
        }
        body += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"

        return body
    }

    /// One of the base-14 fonts, with its metrics published.
    ///
    /// The widths are optional for these fonts — a reader is required to know
    /// Helvetica already — but leaving them out means trusting its built-in
    /// table, and those tables predate the euro. Without this the euro is
    /// advanced by nothing and the next digit is drawn on top of it.
    private static func baseFont(_ font: Font) -> String {
        let table = font.widths
        let widths = (32...255).map { String(table[$0] ?? 0) }.joined(separator: " ")
        return "<</Type /Font /Subtype /Type1 /BaseFont /\(font.rawValue)"
            + " /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255"
            + " /Widths [\(widths)]>>"
    }

    private static func info(
        _ metadata: [String: String], creationDate: Date, encrypting: Encryption? = nil
    ) -> String {
        var parts: [String] = []

        for field in ["Title", "Author", "Subject", "Keywords", "Creator"] {
            let value = (metadata[field] ?? metadata[field.lowercased()] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                parts.append("/\(field) \(literal(value, object: 6, encrypting: encrypting))")
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        parts.append("/Producer \(literal("arraypress/swift-text-pdf", object: 6, encrypting: encrypting))")
        parts.append("/CreationDate \(literal("D:\(formatter.string(from: creationDate))Z", object: 6, encrypting: encrypting))")

        return "<<" + parts.joined(separator: " ") + ">>"
    }

    /// Serialises objects with a correct cross-reference table.
    private static func serialise(
        _ objects: [Int: String], upTo max: Int, binaries: [Int: Data] = [:],
        version: String = "1.4", identifier: String? = nil, encrypt: Int? = nil
    ) -> Data {
        var pdf = bytes("%PDF-\(version)\n")

        // A binary comment on the second line, so anything moving the file
        // treats it as binary rather than as text to be line-ending-converted.
        pdf.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
        var offsets: [Int: Int] = [:]

        for number in 1...max {
            offsets[number] = pdf.count
            let body = objects[number] ?? "<<>>"

            // A font file is binary and cannot survive Latin-1 round-tripping,
            // so it is spliced in as raw bytes around its dictionary.
            if let binary = binaries[number], let marker = body.range(of: "\u{0}STREAM\u{0}") {
                pdf.append(bytes("\(number) 0 obj\n" + String(body[body.startIndex..<marker.lowerBound])))
                pdf.append(binary)
                pdf.append(bytes(String(body[marker.upperBound...]) + "\nendobj\n"))
            } else {
                pdf.append(bytes("\(number) 0 obj\n\(body)\nendobj\n"))
            }
        }

        let xref = pdf.count
        pdf.append(bytes("xref\n0 \(max + 1)\n0000000000 65535 f \n"))

        for number in 1...max {
            pdf.append(bytes(String(format: "%010d 00000 n \n", offsets[number] ?? 0)))
        }

        // /ID is required for a conforming file and useful for any other:
        // it is how two versions of the same document are told apart.
        let fileID = identifier.map { " /ID [<\($0)> <\($0)>]" } ?? ""
        let sealed = encrypt.map { " /Encrypt \($0) 0 R" } ?? ""
        pdf.append(bytes("trailer\n<</Size \(max + 1) /Root 1 0 R /Info 6 0 R\(fileID)\(sealed)>>"
                         + "\nstartxref\n\(xref)\n%%EOF"))
        return pdf
    }
}

// MARK: - Carried files, and the standard

extension Writer {

    /// The catalog entries that make attachments findable.
    ///
    /// Two ways in, because readers use both: `/Names /EmbeddedFiles` is the
    /// attachments panel, and `/AF` is what a Factur-X reader follows to find
    /// the invoice XML without opening a panel at all.
    static func attachmentEntries(
        _ attachments: [Document.Attachment], firstObject: Int, encrypting: Encryption? = nil
    ) -> String {
        guard !attachments.isEmpty else { return "" }

        let specs = attachments.indices.map { "\(firstObject + $0 * 2) 0 R" }
        let names = attachments.enumerated().map { index, file in
            "\(literal(file.name, object: firstObject + index * 2, encrypting: encrypting)) "
                + "\(firstObject + index * 2) 0 R"
        }

        return " /AF [\(specs.joined(separator: " "))]"
            + " /Names <</EmbeddedFiles <</Names [\(names.joined(separator: " "))]>>>>"
    }

    /// The file specification and the stream behind it.
    static func attachmentObjects(
        _ attachments: [Document.Attachment], firstObject: Int, encrypting: Encryption? = nil
    ) -> (objects: [Int: String], binaries: [Int: Data]) {
        var objects: [Int: String] = [:]
        var binaries: [Int: Data] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for (index, file) in attachments.enumerated() {
            let spec = firstObject + index * 2
            let stream = spec + 1
            let name = literal(file.name, object: spec, encrypting: encrypting)

            // /UF as well as /F: the first is a byte string in the reader's
            // own encoding, the second is Unicode, and a reader that only
            // reads one of them is a reader somebody uses.
            var dictionary = "<</Type /Filespec /F \(name) /UF \(name) "
            dictionary += "/AFRelationship /\(file.relationship.rawValue) "
            if !file.description.isEmpty {
                dictionary += "/Desc \(literal(file.description, object: spec, encrypting: encrypting)) "
            }
            dictionary += "/EF <</F \(stream) 0 R /UF \(stream) 0 R>>>>"
            objects[spec] = dictionary

            var params = "/Size \(file.contents.count)"
            if let modified = file.modified {
                params += " /ModDate (D:\(formatter.string(from: modified))Z)"
            }

            objects[stream] = "<</Type /EmbeddedFile /Subtype /\(PDFEncoding.name(file.mimeType)) "
                + "/Length \(file.contents.count) /Params <<\(params)>>>>\n"
                + "stream\n\u{0}STREAM\u{0}\nendstream"
            binaries[stream] = file.contents
        }

        return (objects, binaries)
    }

    /// The metadata packet, the output intent and the profile behind it.
    static func standardObjects(
        _ standard: Document.Standard,
        metadata: [String: String],
        creationDate: Date,
        metadataObject: Int,
        intentObject: Int,
        profileObject: Int
    ) -> (objects: [Int: String], binaries: [Int: Data]) {
        guard standard != .none else { return ([:], [:]) }

        var objects: [Int: String] = [:]
        var binaries: [Int: Data] = [:]

        // Uncompressed on purpose: a validator, and anything reading the file
        // without a PDF parser, expects to find the packet as plain text.
        let packet = Archival.metadata(metadata, creationDate: creationDate, standard: standard)
        let bytes = Data(packet.utf8)
        objects[metadataObject] = "<</Type /Metadata /Subtype /XML /Length \(bytes.count)>>\n"
            + "stream\n\u{0}STREAM\u{0}\nendstream"
        binaries[metadataObject] = bytes

        let profile = Archival.sRGBProfile() ?? Data()
        objects[intentObject] = "<</Type /OutputIntent /S /GTS_PDFA1 "
            + "/OutputConditionIdentifier (sRGB IEC61966-2.1) "
            + "/Info (sRGB IEC61966-2.1) /RegistryName (http://www.color.org) "
            + "/DestOutputProfile \(profileObject) 0 R>>"

        objects[profileObject] = "<</N 3 /Length \(profile.count)>>\n"
            + "stream\n\u{0}STREAM\u{0}\nendstream"
        binaries[profileObject] = profile

        return (objects, binaries)
    }
}
