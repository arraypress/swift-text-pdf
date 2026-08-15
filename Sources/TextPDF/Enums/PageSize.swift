//
//  PageSize.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Paper size, in PostScript points.
public enum PageSize: String, Sendable, CaseIterable, Codable {
    case a4 = "A4"
    case a5 = "A5"
    case letter = "Letter"
    case legal = "Legal"

    /// Width and height in points, portrait.
    public var dimensions: (width: Double, height: Double) {
        switch self {
        case .a4: return (595.28, 841.89)
        case .a5: return (419.53, 595.28)
        case .letter: return (612.0, 792.0)
        case .legal: return (612.0, 1008.0)
        }
    }
}

/// Which way round the page is.
public enum Orientation: String, Sendable, CaseIterable, Codable {
    case portrait
    case landscape
}

/// Horizontal alignment within a box.
public enum Align: String, Sendable, CaseIterable, Codable {
    case left
    case center
    case right
}
