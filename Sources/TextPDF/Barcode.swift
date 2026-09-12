//
//  Barcode.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A linear barcode as vector bars.
//
//  The companion to ``Document/qr(_:x:y:size:correction:color:quiet:)`` and drawn the same
//  way: CoreImage produces one pixel per module, each dark run becomes a filled rectangle in
//  the content stream, and the result is sharp at any zoom and on any printer.
//
//  THAT SHARPNESS IS THE POINT, not a nicety. A rasterised barcode scaled to print size lands
//  its bars on fractional pixels and arrives soft-edged; a scanner reading it at an angle, in
//  shop lighting, through a shrink-wrapped jar, then has to work for it. Vector bars land on
//  exact coordinates at whatever size the label is.
//
//  WHAT COREIMAGE DOES NOT GIVE YOU, and what this adds:
//
//  - The human-readable line. CoreImage draws bars and nothing else. A retail EAN-13 without
//    its digits printed beneath it is not a valid retail barcode, and the digits go in a
//    particular place — see ``Document/barcode(_:symbology:x:y:width:height:caption:color:)``.
//  - Check digits as an answer rather than console noise. Handed a wrong one, CoreImage logs
//    "Invalid check digit. Expected 0 but got 1" to the console and returns nil, so a caller
//    learns only that something failed. ``Barcode/checkDigit(for:)`` computes it up front.
//  - UPC-A, which is an EAN-13 with a leading zero and no generator of its own.
//

import CoreImage
import Foundation

/// Linear barcodes.
public enum Barcode {

    /// The symbologies this can draw.
    ///
    /// Linear only. QR is ``Document/qr(_:x:y:size:correction:color:quiet:)``; the other
    /// two-dimensional families — PDF417, Aztec — have CoreImage generators but produce
    /// non-square matrices, so they need the grid reader rather than the scanline one and are
    /// not here yet.
    public enum Symbology: String, Codable, Sendable, CaseIterable {

        /// 13 digits, the retail barcode outside North America. Pass 12 and the check digit
        /// is computed; pass 13 and it is validated.
        case ean13

        /// 12 digits, North American retail. Encoded as an EAN-13 with a leading zero, which
        /// is what it is.
        case upcA

        /// Any ASCII, variable length. The general-purpose one: asset tags, shipping
        /// references, anything that is not a retail product.
        case code128

        /// Digits, capitals and `- . $ / + % space`. Older and less dense than Code 128, but
        /// what a lot of warehouse equipment still expects.
        case code39

        /// Interleaved 2 of 5 — digits only, in pairs, and compact. Cartons and logistics.
        case itf

        /// Codabar — digits and `- $ : / . +`. Libraries and blood banks, mostly.
        case codabar

        /// The CoreImage filter behind it.
        var filterName: String {
            switch self {
            case .ean13, .upcA: return "CIEAN13BarcodeGenerator"
            case .code128:      return "CICode128BarcodeGenerator"
            case .code39:       return "CICode39BarcodeGenerator"
            case .itf:          return "CIInterleaved2of5BarcodeGenerator"
            case .codabar:      return "CICodabarBarcodeGenerator"
            }
        }

        /// Whether the payload must be digits only.
        public var isNumeric: Bool {
            switch self {
            case .ean13, .upcA, .itf: return true
            case .code128, .code39, .codabar: return false
            }
        }

        /// How many digits the payload must have, once any check digit is included.
        public var fixedLength: Int? {
            switch self {
            case .ean13: return 13
            case .upcA:  return 12
            default:     return nil
            }
        }

        /// A name a person recognises.
        public var displayName: String {
            switch self {
            case .ean13:   return "EAN-13"
            case .upcA:    return "UPC-A"
            case .code128: return "Code 128"
            case .code39:  return "Code 39"
            case .itf:     return "ITF"
            case .codabar: return "Codabar"
            }
        }
    }

    /// Why a barcode could not be drawn.
    public enum Failure: Error, Equatable, Sendable {

        /// The payload was empty.
        case empty

        /// A numeric symbology was handed something that is not digits.
        case notNumeric(Symbology)

        /// The wrong number of digits.
        case wrongLength(Symbology, expected: Int, got: Int)

        /// The check digit supplied disagrees with the one the digits imply.
        ///
        /// The failure CoreImage reports only to the console. Carrying the expected digit
        /// makes it fixable rather than merely reported.
        case badCheckDigit(expected: Int, got: Int)

        /// CoreImage refused the payload for a reason it did not give.
        case refused(Symbology)

        /// The box was too small to draw anything readable in.
        case tooSmall
    }

    // MARK: - Check digits

    /// The check digit for an EAN-13 or UPC-A payload, computed from its leading digits.
    ///
    /// The modulo-10 scheme both use: digits weighted alternately 1 and 3 from the left, the
    /// total taken up to the next ten. Pure arithmetic, so a wrong one is catchable before
    /// anything is rendered.
    ///
    /// - Parameter digits: 12 digits for EAN-13, 11 for UPC-A — the payload without its
    ///   check digit.
    public static func checkDigit(for digits: String) -> Int? {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, !values.isEmpty else { return nil }
        // Weighting runs 1,3,1,3… from the LEFT for a 12-digit EAN payload. An 11-digit UPC
        // payload has odd length, so the same rule from the left would weight it wrongly —
        // hence the parity being taken from the end instead, which is how the standard
        // actually states it.
        let sum = values.reversed().enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// The payload with its check digit appended.
    public static func withCheckDigit(_ digits: String) -> String? {
        guard let digit = checkDigit(for: digits) else { return nil }
        return digits + String(digit)
    }

    /// Check a payload and return what should be sent to the generator.
    ///
    /// Normalises UPC-A to the EAN-13 the generator wants, and completes or validates a check
    /// digit so the caller gets a named failure instead of a console log.
    static func normalise(_ text: String, symbology: Symbology) -> Result<String, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        if symbology.isNumeric, trimmed.contains(where: { !$0.isNumber }) {
            return .failure(.notNumeric(symbology))
        }

        switch symbology {
        case .ean13, .upcA:
            // UPC-A is an EAN-13 whose first digit is zero, so both become 13 digits here and
            // the caption puts back whichever the caller asked for.
            let full = symbology == .upcA ? "0" + trimmed : trimmed
            let want = 13
            switch full.count {
            case want - 1:
                guard let completed = withCheckDigit(full) else { return .failure(.refused(symbology)) }
                return .success(completed)
            case want:
                let body = String(full.dropLast())
                guard let expected = checkDigit(for: body),
                      let got = full.last?.wholeNumberValue else {
                    return .failure(.refused(symbology))
                }
                guard expected == got else {
                    return .failure(.badCheckDigit(expected: expected, got: got))
                }
                return .success(full)
            default:
                let expected = symbology == .upcA ? 12 : 13
                return .failure(.wrongLength(symbology, expected: expected, got: trimmed.count))
            }
        default:
            return .success(trimmed)
        }
    }

    // MARK: - The modules

    /// One context for every code drawn, for the reason ``QRMatrix`` keeps one: creating it
    /// is the expensive part, and a statement carrying a barcode per page paid it per page.
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// The dark modules of a linear code, left to right, with the generator's own quiet zone
    /// trimmed off.
    ///
    /// One scanline rather than a grid: a linear barcode is the same column repeated down its
    /// height, so reading a single row of pixels is the whole of it.
    static func modules(_ text: String, symbology: Symbology) -> [Bool]? {
        guard let filter = CIFilter(name: symbology.filterName) else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        if filter.inputKeys.contains("inputQuietSpace") {
            // Asked for the minimum the filter allows; the real quiet zone is the caller's
            // `quiet`, in points, and two of them would shrink the modules.
            filter.setValue(Float(1), forKey: "inputQuietSpace")
        }
        if filter.inputKeys.contains("inputBarcodeHeight") {
            // One row is all that is read. The filter has its own floor and may hand back
            // more; only the first row is looked at either way.
            filter.setValue(Float(1), forKey: "inputBarcodeHeight")
        }

        guard let image = filter.outputImage else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        guard let raster = context.createCGImage(image, from: extent) else { return nil }

        let width = Int(extent.width)
        let height = Int(extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let bitmap = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        bitmap.interpolationQuality = .none
        bitmap.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The middle row, not the first: a filter that draws a border would give a solid
        // first row, and the middle is bars everywhere in every symbology here.
        let row = height / 2
        let scanline = (0 ..< width).map { pixels[row * width + $0] < 128 }
        return trimmingQuietZone(scanline)
    }

    /// The same scanline with any light run at either end removed.
    static func trimmingQuietZone(_ modules: [Bool]) -> [Bool] {
        guard let first = modules.firstIndex(of: true),
              let last = modules.lastIndex(of: true) else { return [] }
        return Array(modules[first ... last])
    }
}

// MARK: - Drawing

public extension Document {

    /// Draw a linear barcode as vector bars, with its digits beneath.
    ///
    /// - Parameters:
    ///   - text: the payload. For EAN-13 pass 12 digits and the check digit is computed, or
    ///     13 and it is validated; for UPC-A, 11 or 12.
    ///   - symbology: which barcode. See ``Barcode/Symbology``.
    ///   - x: left edge, in points.
    ///   - y: bottom edge of the BARS. The caption, when there is one, is drawn below this,
    ///     so the box a caller reserves should allow for it — ``Barcode/captionHeight(for:)``
    ///     says how much.
    ///   - width: total width of the bars.
    ///   - height: height of the bars, not counting the caption.
    ///   - caption: print the payload beneath. On by default, and it should stay on for
    ///     retail: an EAN-13 without its digits is not a valid retail barcode.
    ///   - color: the bars. Black by default, and black is the only colour a scanner is
    ///     entitled to read — see the discussion.
    /// - Returns: nothing on success, or why it could not be drawn.
    ///
    /// **THE BARS MUST BE DARK ON LIGHT.** A scanner reads contrast, not colour, and red
    /// bars in particular vanish under the red laser most of them use. The parameter is here
    /// because a brand sometimes wants a very dark navy or brown; it is not here so a barcode
    /// can be printed in a pastel.
    ///
    /// **THE DIGIT LAYOUT IS NOT DECORATION.** On an EAN-13 the first digit sits outside the
    /// bars to the left, then six under the left half and six under the right, split by the
    /// centre guard. That is the layout the standard specifies and the one people read
    /// without thinking; centring all thirteen under the bars would scan identically and look
    /// wrong to anybody who handles retail stock.
    @discardableResult
    func barcode(_ text: String,
                 symbology: Barcode.Symbology = .code128,
                 x: Double,
                 y: Double,
                 width: Double,
                 height: Double,
                 caption: Bool = true,
                 color: Color? = nil) -> Barcode.Failure? {

        guard width > 4, height > 4 else { return .tooSmall }

        let payload: String
        switch Barcode.normalise(text, symbology: symbology) {
        case .success(let normalised): payload = normalised
        case .failure(let failure): return failure
        }

        guard let modules = Barcode.modules(payload, symbology: symbology), !modules.isEmpty else {
            return .refused(symbology)
        }

        let moduleWidth = width / Double(modules.count)
        let ink = color ?? .black()

        // One path for every bar, filled once. A barcode is a hundred-odd rectangles, and a
        // fill apiece would be a hundred graphics state changes for a shape that is one
        // colour throughout — the same reason the QR drawer builds a single path.
        var path = ""
        var index = 0
        while index < modules.count {
            guard modules[index] else { index += 1; continue }
            var run = 1
            while index + run < modules.count, modules[index + run] { run += 1 }
            path += String(format: "%.3F %.3F %.3F %.3F re\n",
                           PDFEncoding.number(x + Double(index) * moduleWidth),
                           PDFEncoding.number(y),
                           PDFEncoding.number(Double(run) * moduleWidth),
                           PDFEncoding.number(height))
            index += run
        }
        guard !path.isEmpty else { return .refused(symbology) }
        current += "q\n\(ink.operands) rg\n\(path)f\nQ\n"

        if caption {
            drawCaption(for: payload, symbology: symbology, x: x, y: y,
                        width: width, moduleWidth: moduleWidth, color: ink)
        }
        return nil
    }

    /// The digits beneath the bars.
    private func drawCaption(for payload: String, symbology: Barcode.Symbology,
                             x: Double, y: Double, width: Double,
                             moduleWidth: Double, color: Color) {
        // Sized to the bars rather than fixed: a 20 mm barcode on a jar and a 60 mm one on a
        // carton want different type, and both want it to look deliberate.
        let size = max(5, min(9, width / 14))
        let baseline = y - size - 1

        switch symbology {
        case .ean13, .upcA:
            // 95 modules: 3 guard, 42 left digits, 5 centre guard, 42 right, 3 guard.
            let shown = symbology == .upcA ? String(payload.dropFirst()) : payload
            let digits = Array(shown)
            guard digits.count >= 12 else {
                _ = textAt(shown, x: x, y: baseline, size: size, color: color,
                           align: .center, boxWidth: width)
                return
            }
            let lead = String(digits[0])
            let left = String(digits[1 ... 6])
            let right = String(digits[7...])

            // The lead digit sits OUTSIDE the bars, to the left of the start guard.
            // `self.` because the `width` parameter shadows the measuring method.
            _ = textAt(lead, x: x - moduleWidth * 2 - self.width(of: lead, size: size),
                       y: baseline, size: size, color: color)
            _ = textAt(left, x: x + moduleWidth * 3, y: baseline, size: size, color: color,
                       align: .center, boxWidth: moduleWidth * 42)
            _ = textAt(right, x: x + moduleWidth * 50, y: baseline, size: size, color: color,
                       align: .center, boxWidth: moduleWidth * 42)
        default:
            _ = textAt(payload, x: x, y: baseline, size: size, color: color,
                       align: .center, boxWidth: width)
        }
    }
}

public extension Barcode {

    /// How much room the caption needs beneath the bars, for a barcode of this width.
    ///
    /// So a caller can reserve the whole box before drawing into it, rather than discovering
    /// the digits have landed outside the label.
    static func captionHeight(for width: Double) -> Double {
        let size = max(5, min(9, width / 14))
        return size + 3
    }
}
