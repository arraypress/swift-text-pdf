//
//  Font.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  The base-14 fonts every reader is required to have, so nothing is
//  embedded and the output stays a few kilobytes.
//
//  The width tables are the reason this can lay out a table at all.
//  Helvetica is proportional — a space is 278 units where a capital E is 667
//  — so padding a label with spaces only aligns in a monospace font.
//  Anything that right-aligns a currency column has to measure the string
//  first, and measuring means carrying the metrics.
//
//  Widths are Adobe's AFM values, in 1/1000 em.
//

import Foundation

public enum Font: String, Sendable, CaseIterable {

    case helvetica = "Helvetica"
    case helveticaBold = "Helvetica-Bold"
    case courier = "Courier"

    /// Character widths for ASCII 32–126, in 1/1000 em.
    var widths: [Int: Int] {
        switch self {
        case .courier:
            return Dictionary(uniqueKeysWithValues: (32...126).map { ($0, 600) })
        case .helvetica:
            return Self.helveticaWidths
        case .helveticaBold:
            return Self.helveticaBoldWidths
        }
    }

    /// Distance from the top of a line box down to the baseline.
    ///
    /// PDF positions text by its baseline, but layout code thinks in terms of
    /// the top of a line. Confusing the two puts ascenders above the top
    /// margin and draws rules through the text beneath them.
    public func ascender(_ size: Double) -> Double { size * 0.78 }

    /// Cap height — a capital letter's height above the baseline.
    ///
    /// The measurement to centre on. Using the full em box leaves text
    /// looking high, because the descender space is counted even when
    /// nothing occupies it.
    public func capHeight(_ size: Double) -> Double { size * 0.717 }

    /// The baseline offset that vertically centres text in a band.
    public func bandBaseline(bandHeight: Double, size: Double) -> Double {
        (bandHeight + capHeight(size)) / 2
    }

    /// The rendered width of `text` at `size`, in points.
    ///
    /// Measured on the **encoded** bytes, so it matches what actually reaches
    /// the content stream.
    public func widthOf(_ text: String, size: Double) -> Double {
        let table = widths
        let fallback = table[Int(UInt8(ascii: "n"))] ?? 556
        var total = 0
        for byte in Array(text.utf8) {
            total += table[Int(byte)] ?? fallback
        }
        return Double(total) * size / 1000
    }

    /// How many characters of `text` fit in `width`, truncating with an
    /// ellipsis when it does not.
    public func truncate(_ text: String, size: Double, width: Double) -> String {
        guard widthOf(text, size: size) > width else { return text }

        let ellipsis = widthOf("...", size: size)
        var trimmed = text
        while !trimmed.isEmpty, widthOf(trimmed, size: size) + ellipsis > width {
            trimmed.removeLast()
        }
        return trimmed + "..."
    }

    /// The PDF resource name this font is registered under.
    var resourceName: String {
        switch self {
        case .helvetica: return "F1"
        case .helveticaBold: return "F2"
        case .courier: return "F3"
        }
    }

    // MARK: Metrics

    private static let helveticaWidths: [Int: Int] = [
        32: 278, 33: 278, 34: 355, 35: 556, 36: 556, 37: 889, 38: 667, 39: 191,
        40: 333, 41: 333, 42: 389, 43: 584, 44: 278, 45: 333, 46: 278, 47: 278,
        48: 556, 49: 556, 50: 556, 51: 556, 52: 556, 53: 556, 54: 556, 55: 556,
        56: 556, 57: 556, 58: 278, 59: 278, 60: 584, 61: 584, 62: 584, 63: 556,
        64: 1015, 65: 667, 66: 667, 67: 722, 68: 722, 69: 667, 70: 611, 71: 778,
        72: 722, 73: 278, 74: 500, 75: 667, 76: 556, 77: 833, 78: 722, 79: 778,
        80: 667, 81: 778, 82: 722, 83: 667, 84: 611, 85: 722, 86: 667, 87: 944,
        88: 667, 89: 667, 90: 611, 91: 278, 92: 278, 93: 278, 94: 469, 95: 556,
        96: 333, 97: 556, 98: 556, 99: 500, 100: 556, 101: 556, 102: 278, 103: 556,
        104: 556, 105: 222, 106: 222, 107: 500, 108: 222, 109: 833, 110: 556, 111: 556,
        112: 556, 113: 556, 114: 333, 115: 500, 116: 278, 117: 556, 118: 500, 119: 722,
        120: 500, 121: 500, 122: 500, 123: 334, 124: 260, 125: 334, 126: 584,
    ]

    private static let helveticaBoldWidths: [Int: Int] = [
        32: 278, 33: 333, 34: 474, 35: 556, 36: 556, 37: 889, 38: 722, 39: 238,
        40: 333, 41: 333, 42: 389, 43: 584, 44: 278, 45: 333, 46: 278, 47: 278,
        48: 556, 49: 556, 50: 556, 51: 556, 52: 556, 53: 556, 54: 556, 55: 556,
        56: 556, 57: 556, 58: 333, 59: 333, 60: 584, 61: 584, 62: 584, 63: 611,
        64: 975, 65: 722, 66: 722, 67: 722, 68: 722, 69: 667, 70: 611, 71: 778,
        72: 722, 73: 278, 74: 556, 75: 722, 76: 611, 77: 833, 78: 722, 79: 778,
        80: 667, 81: 778, 82: 722, 83: 667, 84: 611, 85: 722, 86: 667, 87: 944,
        88: 667, 89: 667, 90: 611, 91: 333, 92: 278, 93: 333, 94: 584, 95: 556,
        96: 333, 97: 556, 98: 611, 99: 556, 100: 611, 101: 556, 102: 333, 103: 611,
        104: 611, 105: 278, 106: 278, 107: 556, 108: 278, 109: 889, 110: 611, 111: 611,
        112: 611, 113: 611, 114: 389, 115: 556, 116: 333, 117: 611, 118: 556, 119: 778,
        120: 556, 121: 556, 122: 500, 123: 389, 124: 280, 125: 389, 126: 584,
    ]
}
