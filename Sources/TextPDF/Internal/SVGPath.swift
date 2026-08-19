//
//  SVGPath.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Turns an SVG `path` d-attribute into PDF path operators.
//
//  A logo exported from any vector editor is a path exactly like this, so a
//  mark stays sharp at any zoom and costs a few hundred bytes rather than an
//  embedded bitmap.
//

import Foundation

enum SVGPath {

    private static let limit = 32767.0

    /// Converts path data to PDF operators, or an empty string when the input
    /// is not a path.
    static func toPDF(_ pathData: String, scale: Double = 1, svgHeight: Double = 100) -> String {
        let commands = tokenize(pathData)
        guard let first = commands.first else { return "" }

        // Every valid path begins with a moveto. Without this check, prose
        // containing an `a`, `h`, `t` or `c` tokenizes into commands and draws
        // arbitrary vectors — "not a path" would produce curve operators
        // rather than nothing.
        guard first.letter.uppercased() == "M", first.arguments.count >= 2 else { return "" }

        var out = ""
        var x = 0.0, y = 0.0
        var startX = 0.0, startY = 0.0
        var lastControlX = 0.0, lastControlY = 0.0
        var previous = ""

        // Coordinates are clamped on the way out: a path carrying `1e400`, or
        // simply thirty digits, overflows to infinity, and a formatted `INF`
        // is not a PDF number — a reader meeting one drops the page.
        func px(_ value: Double) -> Double { clamp(value * scale) }
        func py(_ value: Double) -> Double { clamp((svgHeight - value) * scale) }

        for command in commands {
            let relative = command.letter == command.letter.lowercased()
            var mode = command.letter.uppercased()
            let args = command.arguments
            var index = 0

            // A drawing command with no numbers is malformed — running it
            // anyway would read zeroes and draw a stray line to the origin.
            // Only `Z` legitimately arrives bare.
            if args.isEmpty, mode != "Z" { continue }

            repeat {
                func next() -> Double {
                    defer { index += 1 }
                    return index < args.count ? args[index] : 0
                }
                func nextX() -> Double { relative ? x + next() : next() }
                func nextY() -> Double { relative ? y + next() : next() }

                switch mode {
                case "M":
                    x = nextX(); y = nextY()
                    out += String(format: "%.3F %.3F m\n", px(x), py(y))
                    startX = x; startY = y
                    mode = "L"   // Subsequent pairs in the same command are lines.

                case "L":
                    x = nextX(); y = nextY()
                    out += String(format: "%.3F %.3F l\n", px(x), py(y))

                case "H":
                    x = nextX()
                    out += String(format: "%.3F %.3F l\n", px(x), py(y))

                case "V":
                    y = nextY()
                    out += String(format: "%.3F %.3F l\n", px(x), py(y))

                case "C":
                    let x1 = nextX(), y1 = nextY()
                    let x2 = nextX(), y2 = nextY()
                    x = nextX(); y = nextY()
                    out += String(format: "%.3F %.3F %.3F %.3F %.3F %.3F c\n",
                                  px(x1), py(y1), px(x2), py(y2), px(x), py(y))
                    lastControlX = x2; lastControlY = y2

                case "S":
                    // Reflect the previous control point, per spec.
                    let reflect = ["C", "S"].contains(previous.uppercased())
                    let x1 = reflect ? 2 * x - lastControlX : x
                    let y1 = reflect ? 2 * y - lastControlY : y
                    let x2 = nextX(), y2 = nextY()
                    x = nextX(); y = nextY()
                    out += String(format: "%.3F %.3F %.3F %.3F %.3F %.3F c\n",
                                  px(x1), py(y1), px(x2), py(y2), px(x), py(y))
                    lastControlX = x2; lastControlY = y2

                case "Q", "T":
                    let qx: Double, qy: Double
                    if mode == "Q" {
                        qx = nextX(); qy = nextY()
                    } else {
                        let reflect = ["Q", "T"].contains(previous.uppercased())
                        qx = reflect ? 2 * x - lastControlX : x
                        qy = reflect ? 2 * y - lastControlY : y
                    }
                    let ex = nextX(), ey = nextY()

                    // Exact quadratic-to-cubic elevation.
                    let c1x = x + (2.0 / 3.0) * (qx - x)
                    let c1y = y + (2.0 / 3.0) * (qy - y)
                    let c2x = ex + (2.0 / 3.0) * (qx - ex)
                    let c2y = ey + (2.0 / 3.0) * (qy - ey)

                    out += String(format: "%.3F %.3F %.3F %.3F %.3F %.3F c\n",
                                  px(c1x), py(c1y), px(c2x), py(c2y), px(ex), py(ey))
                    lastControlX = qx; lastControlY = qy
                    x = ex; y = ey

                case "Z":
                    out += "h\n"
                    x = startX; y = startY
                    index = args.count            // done with this command

                default:
                    // Unsupported (arcs) — skip rather than guess at a shape.
                    index = args.count
                }
                previous = command.letter
            } while index < args.count
        }
        return out
    }

    private static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, -limit), limit)
    }

    private struct Command {
        let letter: String
        let arguments: [Double]
    }

    /// Splits path data into commands and their numeric arguments.
    private static func tokenize(_ pathData: String) -> [Command] {
        let letters = CharacterSet(charactersIn: "MmLlHhVvCcSsQqTtAaZz")
        var commands: [Command] = []
        var current: Character?
        var buffer = ""

        func flush() {
            guard let letter = current else { return }
            commands.append(Command(letter: String(letter), arguments: numbers(in: buffer)))
            buffer = ""
        }

        for character in pathData {
            if character.unicodeScalars.count == 1,
               letters.contains(character.unicodeScalars.first!) {
                flush()
                current = character
            } else {
                buffer.append(character)
            }
        }
        flush()
        return commands
    }

    /// Pulls signed decimals, including exponent forms, out of an argument run.
    private static func numbers(in text: String) -> [Double] {
        let pattern = "-?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            return Double(text[found])
        }
    }
}
