//
//  Encoding.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Prepares text for a PDF string operator.
enum PDFEncoding {

    /// A PDF name, with the characters a name may not carry written as `#xx`.
    ///
    /// A MIME type is the case that matters: `application/xml` has a slash in
    /// it, which starts a name rather than sitting inside one.
    static func name(_ text: String) -> String {
        var out = ""
        for byte in Array(text.utf8) {
            let scalar = Unicode.Scalar(byte)
            let plain = (byte > 0x21 && byte < 0x7E)
                && !"#()<>[]{}/%".unicodeScalars.contains(scalar)
            out += plain ? String(Character(scalar)) : String(format: "#%02X", byte)
        }
        return out
    }

    /// Transcodes to Windows-1252, strips control characters, and escapes the
    /// three bytes that would end the string early.
    ///
    /// An unescaped `)` produces a file no reader will open, and a stray
    /// carriage return in a customer's name displaces the rest of the line.
    ///
    /// Characters outside Latin-1 — Greek, Cyrillic, CJK — cannot be
    /// represented by the base-14 fonts at all. They are transliterated where
    /// there is an obvious equivalent and replaced with `?` otherwise, which
    /// is the honest outcome: silently dropping them would leave a name
    /// looking merely short rather than wrong.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)

        for scalar in text.unicodeScalars {
            // C0 controls and DEL, including CR and LF.
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }

            switch scalar {
            case "\\": out += "\\\\"
            case "(": out += "\\("
            case ")": out += "\\)"
            default:
                if let byte = windows1252(scalar) {
                    out.unicodeScalars.append(Unicode.Scalar(byte))
                } else if let substitute = transliteration[scalar] {
                    out += substitute
                } else {
                    out += "?"
                }
            }
        }
        return out
    }

    /// The Windows-1252 byte for a scalar, or `nil` when it has none.
    private static func windows1252(_ scalar: Unicode.Scalar) -> UInt8? {
        // ASCII and the Latin-1 range map directly.
        if scalar.value < 0x80 { return UInt8(scalar.value) }
        if (0xA0...0xFF).contains(scalar.value) { return UInt8(scalar.value) }
        // The 0x80–0x9F window is where CP1252 differs from Latin-1: it holds
        // the curly quotes, dashes and the euro sign, which is precisely the
        // punctuation an invoice uses.
        return cp1252Highs[scalar]
    }

    private static let cp1252Highs: [Unicode.Scalar: UInt8] = [
        "\u{20AC}": 0x80, "\u{201A}": 0x82, "\u{0192}": 0x83, "\u{201E}": 0x84,
        "\u{2026}": 0x85, "\u{2020}": 0x86, "\u{2021}": 0x87, "\u{02C6}": 0x88,
        "\u{2030}": 0x89, "\u{0160}": 0x8A, "\u{2039}": 0x8B, "\u{0152}": 0x8C,
        "\u{017D}": 0x8E, "\u{2018}": 0x91, "\u{2019}": 0x92, "\u{201C}": 0x93,
        "\u{201D}": 0x94, "\u{2022}": 0x95, "\u{2013}": 0x96, "\u{2014}": 0x97,
        "\u{02DC}": 0x98, "\u{2122}": 0x99, "\u{0161}": 0x9A, "\u{203A}": 0x9B,
        "\u{0153}": 0x9C, "\u{017E}": 0x9E, "\u{0178}": 0x9F,
    ]

    /// Sensible stand-ins for characters CP1252 cannot hold.
    private static let transliteration: [Unicode.Scalar: String] = [
        "\u{0141}": "L", "\u{0142}": "l",   // Ł ł
        "\u{0106}": "C", "\u{0107}": "c",   // Ć ć
        "\u{0179}": "Z", "\u{017A}": "z",   // Ź ź
        "\u{015A}": "S", "\u{015B}": "s",   // Ś ś
        "\u{0143}": "N", "\u{0144}": "n",   // Ń ń
        "\u{0104}": "A", "\u{0105}": "a",   // Ą ą
        "\u{0118}": "E", "\u{0119}": "e",   // Ę ę
        "\u{2212}": "-",                     // minus sign
        "\u{00A0}": " ",                     // non-breaking space
    ]

    /// Whether text contains anything Windows-1252 cannot hold.
    ///
    /// Cheap enough to run per string: the answer is no for almost every
    /// invoice, and when it is yes only that string pays for the embedded
    /// font.
    static func needsEmbedding(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.value >= 0x20, scalar.value != 0x7F else { return false }
            return windows1252(scalar) == nil && cp1252Highs[scalar] == nil
        }
    }

    /// Clamps a value to something the format can express.
    ///
    /// `INF` and `NAN` would be written literally into the content stream, and
    /// neither is a PDF number — a reader that meets one drops the page or
    /// refuses the file. A dimension computed from a division by zero is
    /// exactly how one gets there. ±32767 is the specification's limit.
    static func number(_ value: Double) -> Double {
        // NaN has no position at all, so it becomes the origin. Infinity is
        // clamped instead: a mark far off-page is visible evidence that a
        // dimension overflowed, where drawing at 0,0 looks like a plausible
        // position and hides the bug.
        guard !value.isNaN else { return 0 }
        return min(max(value, -32767), 32767)
    }
}
