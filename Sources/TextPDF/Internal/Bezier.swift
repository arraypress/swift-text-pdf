//
//  Bezier.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Curves, for the shapes a straight-edged writer cannot otherwise draw.
//
//  PDF has no circle and no rounded rectangle. It has cubic Béziers, and every
//  round thing here is built from them — which is the same thing a font does,
//  so the results are as sharp as the type beside them.
//

import Foundation

enum Bezier {

    /// How far a control point sits from its anchor to approximate a quarter
    /// circle: 4/3 · tan(π/8).
    ///
    /// The classic constant. A quarter circle drawn this way is wrong by about
    /// one part in two thousand of the radius, which at any size a document
    /// uses is far below the resolution of anything that will print it.
    static let kappa = 0.5522847498307936

    /// A closed circle as PDF path operators.
    static func circle(x: Double, y: Double, radius: Double) -> String {
        let k = radius * kappa
        var path = String(format: "%.3F %.3F m\n", n(x + radius), n(y))
        path += curve(x + radius, y + k, x + k, y + radius, x, y + radius)
        path += curve(x - k, y + radius, x - radius, y + k, x - radius, y)
        path += curve(x - radius, y - k, x - k, y - radius, x, y - radius)
        path += curve(x + k, y - radius, x + radius, y - k, x + radius, y)
        path += "h\n"
        return path
    }

    /// An arc, from `start` to `end` in radians, measured anticlockwise from
    /// three o'clock.
    ///
    /// Split into segments of at most a quarter turn: one Bézier stretched
    /// across a half circle bulges visibly, and across a full one collapses
    /// to nothing.
    static func arc(x: Double, y: Double, radius: Double, start: Double, end: Double) -> String {
        let sweep = end - start
        guard abs(sweep) > 1e-9, radius > 0 else { return "" }

        let segments = max(1, Int(ceil(abs(sweep) / (.pi / 2))))
        let step = sweep / Double(segments)
        // 4/3 · tan(Δ/4), which reduces to kappa at a quarter turn.
        let alpha = (4.0 / 3.0) * tan(step / 4)

        var angle = start
        var path = String(format: "%.3F %.3F m\n", n(x + radius * cos(angle)), n(y + radius * sin(angle)))

        for _ in 0..<segments {
            let next = angle + step

            let x0 = x + radius * cos(angle), y0 = y + radius * sin(angle)
            let x3 = x + radius * cos(next), y3 = y + radius * sin(next)

            let x1 = x0 - alpha * radius * sin(angle)
            let y1 = y0 + alpha * radius * cos(angle)
            let x2 = x3 + alpha * radius * sin(next)
            let y2 = y3 - alpha * radius * cos(next)

            path += curve(x1, y1, x2, y2, x3, y3)
            angle = next
        }
        return path
    }

    /// A rectangle with rounded corners.
    ///
    /// The radius is clamped to half the shorter side. Beyond that the corners
    /// overlap and the shape turns inside out — a pill asked for a radius
    /// larger than itself should become a pill, not a knot.
    static func roundedRect(
        x: Double, y: Double, width: Double, height: Double, radius: Double
    ) -> String {
        let r = min(radius, min(width, height) / 2)
        guard r > 0 else {
            return String(format: "%.3F %.3F %.3F %.3F re\n", n(x), n(y), n(width), n(height))
        }

        let k = r * kappa
        let right = x + width, top = y + height

        var path = String(format: "%.3F %.3F m\n", n(x + r), n(y))
        path += String(format: "%.3F %.3F l\n", n(right - r), n(y))
        path += curve(right - r + k, y, right, y + r - k, right, y + r)
        path += String(format: "%.3F %.3F l\n", n(right), n(top - r))
        path += curve(right, top - r + k, right - r + k, top, right - r, top)
        path += String(format: "%.3F %.3F l\n", n(x + r), n(top))
        path += curve(x + r - k, top, x, top - r + k, x, top - r)
        path += String(format: "%.3F %.3F l\n", n(x), n(y + r))
        path += curve(x, y + r - k, x + r - k, y, x + r, y)
        path += "h\n"
        return path
    }

    private static func curve(
        _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double
    ) -> String {
        String(format: "%.3F %.3F %.3F %.3F %.3F %.3F c\n",
               n(x1), n(y1), n(x2), n(y2), n(x3), n(y3))
    }

    private static func n(_ value: Double) -> Double { PDFEncoding.number(value) }
}
