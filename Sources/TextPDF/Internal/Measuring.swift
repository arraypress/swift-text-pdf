//
//  Measuring.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Text measured against a width table, escape-aware. Measuring the
//  escaped form is the rule that matters: a byte the encoder will write
//  is a byte the reader will draw, and the backslash of an escape pair
//  is not drawn at all. Pure functions of (text, table, size), pinned
//  by tests that need no font.
//

import Foundation

enum Measuring {

    /// The rendered width of `text` at `size`, in points, against a table
    /// of per-byte widths in 1/1000 em.
    static func width(of text: String, table: [Int: Int], size: Double) -> Double {
        let fallback = table[Int(UInt8(ascii: "n"))] ?? 556
        var total = 0
        var escaping = false

        // `escape` yields one scalar per encoded byte, so the scalar value is
        // the byte.
        for scalar in PDFEncoding.escape(text).unicodeScalars {
            if escaping {
                escaping = false
            } else if scalar == "\\" {
                // The backslash of an escape pair is not drawn.
                escaping = true
                continue
            }
            total += table[Int(scalar.value)] ?? fallback
        }
        return Double(total) * size / 1000
    }

    /// `text` cut to fit `width`, with an ellipsis when it had to be.
    static func truncated(_ text: String, size: Double, width: Double, table: [Int: Int]) -> String {
        guard Self.width(of: text, table: table, size: size) > width else { return text }

        let ellipsis = Self.width(of: "...", table: table, size: size)
        var trimmed = text
        while !trimmed.isEmpty, Self.width(of: trimmed, table: table, size: size) + ellipsis > width {
            trimmed.removeLast()
        }
        return trimmed + "..."
    }
}
