//
//  TableLayout.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Deciding how wide each column should be, and what to do when the honest
//  answer is "wider than the page".
//
//  Most exporters answer that by cutting. Ask for fifty columns and eight
//  arrive, with nothing said about the other forty-two — and a truncated
//  column looks exactly like a column of short values, so the loss is
//  invisible in the document itself. The rules here never lose a character:
//  columns narrow to their content, then the type steps down, and only when
//  both are exhausted does the table split into sequential tables that repeat
//  the columns identifying each row.
//
//  Pure arithmetic, no drawing, so it can be tested without rendering a page.
//

import Foundation

/// Column width arithmetic for ``Table``.
enum TableLayout {

    /// The result of fitting a table to a page.
    struct Plan {
        /// One entry per table to draw. Each holds the column indices that
        /// table carries, in order.
        let groups: [[Int]]

        /// Point widths for every column, indexed as the original table.
        let widths: [Double]

        /// The font size the table should be drawn at.
        let size: Double

        /// Whether the table had to be split to fit.
        var isSplit: Bool { groups.count > 1 }
    }

    /// How narrow a column may be squeezed before it stops being readable.
    ///
    /// Four characters of the size in use — enough for a short heading's
    /// first word and a number, and not so wide that a table of short values
    /// refuses to fit for no reason.
    static func floorWidth(size: Double) -> Double { size * 2.4 }

    /// Sizes to try, largest first, before giving up and splitting.
    ///
    /// Half-point steps down to six: below that a printed table is not
    /// something anyone reads, and splitting is the better answer.
    static func sizeLadder(from size: Double, floor: Double = 6) -> [Double] {
        var sizes: [Double] = []
        var candidate = size
        while candidate >= floor {
            sizes.append(candidate)
            candidate -= 0.5
        }
        return sizes
    }

    /// Fits columns to the available width, narrowing, then scaling, then
    /// splitting.
    ///
    /// - Parameters:
    ///   - natural: What each column would like to be, at `size`.
    ///   - minimum: What each column will not go below, at `size`.
    ///   - available: The content width of the page.
    ///   - size: The font size asked for.
    ///   - repeated: How many leading columns to repeat on each table when a
    ///     split is needed, so every row stays identifiable.
    ///   - measure: Recomputes natural and minimum widths at another size.
    static func plan(
        natural: [Double],
        minimum: [Double],
        available: Double,
        size: Double,
        repeated: Int,
        measure: (Double) -> (natural: [Double], minimum: [Double])
    ) -> Plan {
        let columns = Array(natural.indices)
        guard !columns.isEmpty, available > 0 else {
            return Plan(groups: [], widths: [], size: size)
        }

        for candidate in sizeLadder(from: size) {
            let (naturalAt, minimumAt) = candidate == size
                ? (natural, minimum)
                : measure(candidate)

            if naturalAt.reduce(0, +) <= available {
                return Plan(
                    groups: [columns],
                    widths: grow(naturalAt, to: available),
                    size: candidate
                )
            }
            if minimumAt.reduce(0, +) <= available {
                return Plan(
                    groups: [columns],
                    widths: squeeze(natural: naturalAt, minimum: minimumAt, to: available),
                    size: candidate
                )
            }
        }

        // Nothing fits at any readable size: split, at the smallest size, so
        // the fewest tables are needed.
        let smallest = sizeLadder(from: size).last ?? size
        let (naturalAt, minimumAt) = smallest == size ? (natural, minimum) : measure(smallest)
        let groups = split(
            minimum: minimumAt, available: available, repeated: repeated
        )
        return Plan(
            groups: groups,
            widths: squeeze(natural: naturalAt, minimum: minimumAt, to: available, clampToAvailable: false),
            size: smallest
        )
    }

    /// Distributes slack so the table meets the right margin.
    ///
    /// Proportionally, so a column that wanted to be twice as wide as another
    /// stays twice as wide — widening every column by the same number of
    /// points makes narrow columns look padded and wide ones look unchanged.
    static func grow(_ widths: [Double], to available: Double) -> [Double] {
        let total = widths.reduce(0, +)
        guard total > 0, available > total else { return widths }
        let scale = available / total
        return widths.map { $0 * scale }
    }

    /// Takes width from the columns that have most to spare.
    ///
    /// A column is squeezed in proportion to its *slack* — the distance
    /// between what it wants and what it will accept — so a narrow date column
    /// is left alone and a long path column gives up the room. Squeezing every
    /// column by the same fraction instead makes the dates wrap first, which
    /// is the wrong column to break.
    static func squeeze(
        natural: [Double],
        minimum: [Double],
        to available: Double,
        clampToAvailable: Bool = true
    ) -> [Double] {
        let total = natural.reduce(0, +)
        guard total > available else { return natural }

        let slack = zip(natural, minimum).map { max($0 - $1, 0) }
        let totalSlack = slack.reduce(0, +)
        let excess = total - available

        guard totalSlack > 0 else {
            return clampToAvailable ? grow(minimum, to: available) : minimum
        }
        if excess >= totalSlack {
            return clampToAvailable ? minimum : minimum
        }
        return zip(natural, slack).map { width, spare in
            width - (spare / totalSlack) * excess
        }
    }

    /// Divides columns into groups that each fit the page.
    ///
    /// The identifying columns lead every group. Without them the second table
    /// is a block of values with nothing saying which row each belongs to,
    /// which is worse than truncation because it looks complete.
    static func split(minimum: [Double], available: Double, repeated: Int) -> [[Int]] {
        let columns = Array(minimum.indices)
        guard !columns.isEmpty else { return [] }

        let keyCount = max(0, min(repeated, columns.count))
        let keys = Array(columns.prefix(keyCount))
        let keyWidth = keys.reduce(0) { $0 + minimum[$1] }
        guard keyCount < columns.count else { return [columns] }

        // If repeating the identifying columns would leave no room beside
        // them, they are not repeated: a group carrying only keys says
        // nothing, and a run of them never terminates.
        //
        // They then flow like any other column rather than being dropped —
        // losing the name column entirely is a worse answer than not
        // repeating it.
        let repeatKeys = keyCount > 0 && keyWidth < available * 0.6
        let opener: [Int] = repeatKeys ? keys : []
        let openerWidth = repeatKeys ? keyWidth : 0
        let rest = repeatKeys ? Array(columns.dropFirst(keyCount)) : columns

        var groups: [[Int]] = []
        var current = opener
        var width = openerWidth

        for column in rest {
            let next = minimum[column]
            // A group that holds nothing but the repeated keys has to take
            // this column whether it fits or not — otherwise no group ever
            // would, and the loop makes no progress.
            let holdsOnlyKeys = current.count == opener.count
            if width + next > available, !holdsOnlyKeys {
                groups.append(current)
                current = opener
                width = openerWidth
            }
            current.append(column)
            width += next
        }
        if current.count > opener.count { groups.append(current) }
        return groups.isEmpty ? [columns] : groups
    }
}
