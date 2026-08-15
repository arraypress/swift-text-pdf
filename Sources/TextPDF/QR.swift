//
//  QR.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A QR code as vector squares.
//
//  Business documents increasingly carry one and increasingly must: the Swiss
//  QR-bill is mandatory there, the EPC code is how a SEPA credit transfer is
//  scanned across much of Europe, and several tax authorities require one on
//  the face of an invoice.
//
//  Drawn rather than embedded. CoreImage produces the matrix, and each dark
//  module becomes a filled rectangle in the content stream — so the code is
//  sharp at any zoom and on any printer, where a bitmap at the wrong scale
//  arrives soft-edged and a scanner has to work for it. The whole thing is a
//  few kilobytes of path operators.
//

import CoreImage
import Foundation

extension Document {

    /// How much damage a code can take and still be read.
    ///
    /// The cost is capacity: the same text at `.high` needs a denser grid than
    /// at `.low`. Printed documents get folded, stapled and photocopied, so
    /// `.medium` is the default rather than `.low`.
    public enum QRCorrection: String, Sendable, CaseIterable {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    /// Draws a QR code with its bottom-left corner at `x`, `y`.
    ///
    /// - Parameters:
    ///   - size: The width and height of the finished square, in points. A
    ///     code is scanned from a phone at arm's length; below about 70 points
    ///     that stops being reliable on a printed page.
    ///   - quiet: The clear margin around the code, in modules. The
    ///     specification asks for four, and scanners really do fail without
    ///     it — this is drawn inside `size`, so the square you asked for is
    ///     the square it occupies.
    /// - Returns: Whether the code could be made. A string too long for the
    ///   densest grid is the only real failure, and it is reported rather than
    ///   drawn as an unreadable smudge.
    @discardableResult
    public func qr(
        _ text: String,
        x: Double,
        y: Double,
        size: Double,
        correction: QRCorrection = .medium,
        color: Color? = nil,
        quiet: Int = 4
    ) -> Bool {
        guard let matrix = QRMatrix.make(text, correction: correction) else { return false }

        let margin = max(0, quiet)
        let across = matrix.width + margin * 2
        let module = size / Double(across)
        let ink = color ?? .black()

        // One path, one fill: a code is a few hundred squares, and a fill
        // apiece would be a few hundred graphics state changes for a shape
        // that is one colour throughout.
        var path = ""
        for row in 0..<matrix.width {
            for column in 0..<matrix.width where matrix[column, row] {
                // The matrix reads top-down; the page counts up from the
                // bottom, so a code written straight out arrives mirrored.
                let left = x + Double(column + margin) * module
                let bottom = y + size - Double(row + margin + 1) * module
                path += String(
                    format: "%.3F %.3F %.3F %.3F re\n",
                    PDFEncoding.number(left), PDFEncoding.number(bottom),
                    PDFEncoding.number(module), PDFEncoding.number(module)
                )
            }
        }

        guard !path.isEmpty else { return false }
        current += "q\n\(ink.operands) rg\n\(path)f\nQ\n"
        return true
    }
}

// MARK: - The matrix

/// The dark modules of a QR code, as a square grid.
enum QRMatrix {

    struct Grid {
        let width: Int
        private let modules: [Bool]

        init(width: Int, modules: [Bool]) {
            self.width = width
            self.modules = modules
        }

        subscript(column: Int, row: Int) -> Bool {
            guard column >= 0, column < width, row >= 0, row < width else { return false }
            return modules[row * width + column]
        }
    }

    /// Builds the grid, or nothing when the text will not fit one.
    static func make(_ text: String, correction: Document.QRCorrection) -> Grid? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(trimmed.utf8), forKey: "inputMessage")
        filter.setValue(correction.rawValue, forKey: "inputCorrectionLevel")

        guard let image = filter.outputImage else { return nil }

        // CoreImage hands back one pixel per module, with its own quiet zone
        // already around it — which has to come off, or the code is drawn with
        // two margins and the modules end up too small to scan.
        let extent = image.extent
        guard extent.width > 0, extent.width == extent.height else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let raster = context.createCGImage(image, from: extent) else { return nil }

        let width = Int(extent.width)
        var pixels = [UInt8](repeating: 0, count: width * width)
        guard let bitmap = CGContext(
            data: &pixels, width: width, height: width,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        bitmap.interpolationQuality = .none
        bitmap.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: width))

        // Trim the quiet zone CoreImage added, so `quiet:` means what it says.
        var modules = [Bool](repeating: false, count: width * width)
        for row in 0..<width {
            for column in 0..<width {
                // The bitmap counts rows from the bottom; the grid from the top.
                modules[row * width + column] = pixels[(width - 1 - row) * width + column] < 128
            }
        }

        return withoutQuietZone(Grid(width: width, modules: modules))
    }

    /// The same grid with any all-light border removed.
    private static func withoutQuietZone(_ grid: Grid) -> Grid {
        var inset = 0
        while inset < grid.width / 2 {
            let edge = (inset..<(grid.width - inset)).contains { column in
                grid[column, inset] || grid[column, grid.width - 1 - inset]
                    || grid[inset, column] || grid[grid.width - 1 - inset, column]
            }
            if edge { break }
            inset += 1
        }

        guard inset > 0 else { return grid }

        let width = grid.width - inset * 2
        var modules = [Bool](repeating: false, count: width * width)
        for row in 0..<width {
            for column in 0..<width {
                modules[row * width + column] = grid[column + inset, row + inset]
            }
        }
        return Grid(width: width, modules: modules)
    }
}
