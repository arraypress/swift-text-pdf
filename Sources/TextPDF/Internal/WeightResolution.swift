//
//  WeightResolution.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  Which loaded weight answers for a requested one. Nearest by distance;
//  ties resolve to the heavier face, because the request was for emphasis
//  and semibold set in bold reads better than semibold set in regular.
//

import Foundation

enum WeightResolution {

    /// The nearest weight among those loaded, or nil for none at all.
    static func nearest(to weight: FontFamily.Weight, among loaded: [FontFamily.Weight]) -> FontFamily.Weight? {
        loaded.min { left, right in
            let a = abs(left.rawValue - weight.rawValue)
            let b = abs(right.rawValue - weight.rawValue)
            return a == b ? left > right : a < b
        }
    }
}
