//
//  ColorParsing.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Hex strings read as colours. Anything unparseable becomes black
//  rather than throwing: a malformed brand colour should print a
//  slightly dull invoice, not refuse to produce one.
//

import Foundation

enum ColorParsing {

    /// Parses `#rgb`, `#rrggbb`, or the same without the hash.
    static func color(from string: String) -> Color {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6,
              value.allSatisfy({ $0.isHexDigit }),
              let number = Int(value, radix: 16)
        else { return Color() }

        return Color(
            red: (number >> 16) & 0xFF,
            green: (number >> 8) & 0xFF,
            blue: number & 0xFF
        )
    }
}
