//
//  Fixtures.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Test images, made rather than committed.
//
//  These used to be read out of a scratch directory on one machine, with an
//  `XCTSkipUnless` past their absence everywhere else — so on a fresh clone,
//  and on anybody else's laptop, every image test silently passed by not
//  running. A skipped test is a test you do not have, and the image path is
//  the newest and least exercised part of this writer.
//
//  Drawn with ImageIO, which the decoder under test already depends on, and
//  written once per run.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Fixtures {

    /// A 400×211 landscape photograph, as JPEG. Opaque.
    static let jpeg = write("portrait.jpg", as: .jpeg, alpha: false) { context, width, height in
        bands(in: context, width: width, height: height)
    }

    /// The same picture as PNG, so the two can be compared and mixed.
    static let png = write("portrait.png", as: .png, alpha: false) { context, width, height in
        bands(in: context, width: width, height: height)
    }

    /// A red disc on transparency, for the soft mask.
    ///
    /// Round on purpose: drawn without its mask it arrives as a filled square,
    /// which is a difference a test can measure in ink rather than in bytes.
    static let dot = write("dot.png", as: .png, alpha: true, width: 200, height: 200) { context, width, height in
        context.setFillColor(CGColor(red: 0.85, green: 0.16, blue: 0.16, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))
    }

    // MARK: Drawing

    /// Two bands and a disc — enough to tell right way up from upside down,
    /// and cropped from squashed, by eye.
    private static func bands(in context: CGContext, width: Int, height: Int) {
        context.setFillColor(CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))

        context.setFillColor(CGColor(red: 0.15, green: 0.23, blue: 0.37, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height) * 0.28))

        context.setFillColor(CGColor(red: 0.93, green: 0.78, blue: 0.66, alpha: 1))
        context.fillEllipse(in: CGRect(x: Double(width) * 0.36, y: Double(height) * 0.34,
                                       width: Double(height) * 0.42, height: Double(height) * 0.42))
    }

    private static func write(
        _ name: String,
        as type: UTType,
        alpha: Bool,
        width: Int = 400,
        height: Int = 211,
        _ draw: (CGContext, Int, Int) -> Void
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("text-pdf-fixtures", isDirectory: true)
            .appendingPathComponent(name)

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ) else { return url }

        draw(context, width, height)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, type.identifier as CFString, 1, nil
              )
        else { return url }

        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)

        return url
    }
}
