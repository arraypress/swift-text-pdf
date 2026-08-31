//
//  Color.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// An RGB colour, 0–255 per channel.
public struct Color: Sendable, Equatable, Hashable {

    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int = 0, green: Int = 0, blue: Int = 0) {
        self.red = min(max(red, 0), 255)
        self.green = min(max(green, 0), 255)
        self.blue = min(max(blue, 0), 255)
    }

    /// Parses `#rgb`, `#rrggbb`, or the same without the hash.
    ///
    /// Anything unparseable becomes black rather than throwing: a malformed
    /// brand colour should print a slightly dull invoice, not refuse to
    /// produce one.
    public static func hex(_ string: String) -> Color {
        ColorParsing.color(from: string)
    }

    /// A neutral grey.
    public static func grey(_ level: Int) -> Color {
        Color(red: level, green: level, blue: level)
    }

    public static func black() -> Color { Color() }

    /// Whether this is pure black, which the writer can leave unstated.
    public var isBlack: Bool { red == 0 && green == 0 && blue == 0 }

    /// The three operands a PDF colour operator wants, 0–1.
    var operands: String {
        String(format: "%.3F %.3F %.3F", Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }
}
