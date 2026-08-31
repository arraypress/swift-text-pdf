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

    /// Character widths across WinAnsiEncoding, in 1/1000 em.
    ///
    /// The full byte range, not just ASCII: a euro sign or an accented name
    /// measured as a fallback width throws every right-aligned column out by a
    /// few points, and the same table is published as the font's `/Widths` so
    /// the reader positions text exactly as this code measured it.
    var widths: [Int: Int] {
        switch self {
        case .courier:
            // Courier is monospaced; every WinAnsi character is 600.
            return Dictionary(uniqueKeysWithValues: Self.winAnsiBytes.map { ($0, 600) })
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
    /// Takes text as written and encodes it here, so callers cannot get the
    /// answer wrong by passing the raw or the escaped form: measuring `€` as
    /// three UTF-8 bytes rather than one CP1252 byte was exactly that mistake,
    /// and it threw every right-aligned column that contained one.
    public func widthOf(_ text: String, size: Double) -> Double {
        Measuring.width(of: text, table: widths, size: size)
    }

    /// How many characters of `text` fit in `width`, truncating with an
    /// ellipsis when it does not.
    public func truncate(_ text: String, size: Double, width: Double) -> String {
        Measuring.truncated(text, size: size, width: width, table: widths)
    }

    /// The PDF resource name this font is registered under.
    var resourceName: String {
        switch self {
        case .helvetica: return "F1"
        case .helveticaBold: return "F2"
        case .courier: return "F3"
        }
    }

    /// The byte values WinAnsiEncoding assigns a glyph to.
    ///
    /// 0x7F and the five unused slots in the 0x80–0x9F window have none.
    static let winAnsiBytes: [Int] =
        Array(32...126) + [128, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140,
                           142, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155,
                           156, 158, 159] + Array(160...255)

    // MARK: Metrics

    /// Adobe's AFM metrics, verified against Arial, which was drawn to match
    /// them character for character.
    ///
    /// One deliberate deviation: the euro is declared at 744 rather than
    /// Adobe's 556. The two Helveticas in circulation disagree about only this
    /// glyph — Apple's is 744 — and a declared width that is too narrow draws
    /// the next digit through the symbol, while one that is too wide leaves a
    /// thin space that reads as ordinary European practice.
    private static let helveticaWidths: [Int: Int] = [
        32: 278, 33: 278, 34: 355, 35: 556, 36: 556, 37: 889, 38: 667, 39: 191, 40: 333,
        41: 333, 42: 389, 43: 584, 44: 278, 45: 333, 46: 278, 47: 278, 48: 556, 49: 556,
        50: 556, 51: 556, 52: 556, 53: 556, 54: 556, 55: 556, 56: 556, 57: 556, 58: 278,
        59: 278, 60: 584, 61: 584, 62: 584, 63: 556, 64: 1015, 65: 667, 66: 667,
        67: 722, 68: 722, 69: 667, 70: 611, 71: 778, 72: 722, 73: 278, 74: 500, 75: 667,
        76: 556, 77: 833, 78: 722, 79: 778, 80: 667, 81: 778, 82: 722, 83: 667, 84: 611,
        85: 722, 86: 667, 87: 944, 88: 667, 89: 667, 90: 611, 91: 278, 92: 278, 93: 278,
        94: 469, 95: 556, 96: 333, 97: 556, 98: 556, 99: 500, 100: 556, 101: 556,
        102: 278, 103: 556, 104: 556, 105: 222, 106: 222, 107: 500, 108: 222, 109: 833,
        110: 556, 111: 556, 112: 556, 113: 556, 114: 333, 115: 500, 116: 278, 117: 556,
        118: 500, 119: 722, 120: 500, 121: 500, 122: 500, 123: 334, 124: 260, 125: 334,
        126: 584, 128: 744, 130: 222, 131: 556, 132: 333, 133: 1000, 134: 556, 135: 556,
        136: 333, 137: 1000, 138: 667, 139: 333, 140: 1000, 142: 611, 145: 222, 146: 222,
        147: 333, 148: 333, 149: 350, 150: 556, 151: 1000, 152: 333, 153: 1000, 154: 500,
        155: 333, 156: 944, 158: 500, 159: 667, 160: 278, 161: 333, 162: 556, 163: 556,
        164: 556, 165: 556, 166: 260, 167: 556, 168: 333, 169: 737, 170: 370, 171: 556,
        172: 584, 173: 333, 174: 737, 175: 552, 176: 400, 177: 549, 178: 333, 179: 333,
        180: 333, 181: 576, 182: 537, 183: 333, 184: 333, 185: 333, 186: 365, 187: 556,
        188: 834, 189: 834, 190: 834, 191: 611, 192: 667, 193: 667, 194: 667, 195: 667,
        196: 667, 197: 667, 198: 1000, 199: 722, 200: 667, 201: 667, 202: 667, 203: 667,
        204: 278, 205: 278, 206: 278, 207: 278, 208: 722, 209: 722, 210: 778, 211: 778,
        212: 778, 213: 778, 214: 778, 215: 584, 216: 778, 217: 722, 218: 722, 219: 722,
        220: 722, 221: 667, 222: 667, 223: 611, 224: 556, 225: 556, 226: 556, 227: 556,
        228: 556, 229: 556, 230: 889, 231: 500, 232: 556, 233: 556, 234: 556, 235: 556,
        236: 278, 237: 278, 238: 278, 239: 278, 240: 556, 241: 556, 242: 556, 243: 556,
        244: 556, 245: 556, 246: 556, 247: 549, 248: 611, 249: 556, 250: 556, 251: 556,
        252: 556, 253: 500, 254: 556, 255: 500,
    ]

    /// As `helveticaWidths`, including the euro deviation.
    private static let helveticaBoldWidths: [Int: Int] = [
        32: 278, 33: 333, 34: 474, 35: 556, 36: 556, 37: 889, 38: 722, 39: 238, 40: 333,
        41: 333, 42: 389, 43: 584, 44: 278, 45: 333, 46: 278, 47: 278, 48: 556, 49: 556,
        50: 556, 51: 556, 52: 556, 53: 556, 54: 556, 55: 556, 56: 556, 57: 556, 58: 333,
        59: 333, 60: 584, 61: 584, 62: 584, 63: 611, 64: 975, 65: 722, 66: 722, 67: 722,
        68: 722, 69: 667, 70: 611, 71: 778, 72: 722, 73: 278, 74: 556, 75: 722, 76: 611,
        77: 833, 78: 722, 79: 778, 80: 667, 81: 778, 82: 722, 83: 667, 84: 611, 85: 722,
        86: 667, 87: 944, 88: 667, 89: 667, 90: 611, 91: 333, 92: 278, 93: 333, 94: 584,
        95: 556, 96: 333, 97: 556, 98: 611, 99: 556, 100: 611, 101: 556, 102: 333,
        103: 611, 104: 611, 105: 278, 106: 278, 107: 556, 108: 278, 109: 889, 110: 611,
        111: 611, 112: 611, 113: 611, 114: 389, 115: 556, 116: 333, 117: 611, 118: 556,
        119: 778, 120: 556, 121: 556, 122: 500, 123: 389, 124: 280, 125: 389, 126: 584,
        128: 744, 130: 278, 131: 556, 132: 500, 133: 1000, 134: 556, 135: 556, 136: 333,
        137: 1000, 138: 667, 139: 333, 140: 1000, 142: 611, 145: 278, 146: 278, 147: 500,
        148: 500, 149: 350, 150: 556, 151: 1000, 152: 333, 153: 1000, 154: 556, 155: 333,
        156: 944, 158: 500, 159: 667, 160: 278, 161: 333, 162: 556, 163: 556, 164: 556,
        165: 556, 166: 280, 167: 556, 168: 333, 169: 737, 170: 370, 171: 556, 172: 584,
        173: 333, 174: 737, 175: 552, 176: 400, 177: 549, 178: 333, 179: 333, 180: 333,
        181: 576, 182: 556, 183: 333, 184: 333, 185: 333, 186: 365, 187: 556, 188: 834,
        189: 834, 190: 834, 191: 611, 192: 722, 193: 722, 194: 722, 195: 722, 196: 722,
        197: 722, 198: 1000, 199: 722, 200: 667, 201: 667, 202: 667, 203: 667, 204: 278,
        205: 278, 206: 278, 207: 278, 208: 722, 209: 722, 210: 778, 211: 778, 212: 778,
        213: 778, 214: 778, 215: 584, 216: 778, 217: 722, 218: 722, 219: 722, 220: 722,
        221: 667, 222: 667, 223: 611, 224: 556, 225: 556, 226: 556, 227: 556, 228: 556,
        229: 556, 230: 889, 231: 556, 232: 556, 233: 556, 234: 556, 235: 556, 236: 278,
        237: 278, 238: 278, 239: 278, 240: 611, 241: 611, 242: 611, 243: 611, 244: 611,
        245: 611, 246: 611, 247: 549, 248: 611, 249: 611, 250: 611, 251: 611, 252: 611,
        253: 556, 254: 611, 255: 556,
    ]
}
