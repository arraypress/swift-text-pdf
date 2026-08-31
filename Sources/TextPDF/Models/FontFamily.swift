//
//  FontFamily.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  A set of embedded faces that stands in for the base-14 fonts.
//
//  ``EmbeddedFont`` on its own is an escape hatch: it exists so a Cyrillic
//  name renders instead of printing as question marks, and it is reached for
//  only when Windows-1252 cannot hold the text. That is the right behaviour
//  for a document whose typography is Helvetica by choice.
//
//  It is the wrong behaviour for a document whose typography is the point. A
//  family is attached to the document instead, and then it sets everything —
//  the base-14 fonts become the fallback rather than the default.
//
//  Weights are addressed by name and resolved to the nearest face actually
//  loaded, so a layout asking for semibold in a family carrying only regular
//  and bold gets bold rather than nothing.
//

import Foundation

/// A typeface in several weights, embedded in the document.
public struct FontFamily: Sendable {

    /// A weight, numbered as CSS and OS/2 number them.
    public enum Weight: Int, Sendable, CaseIterable, Comparable {

        case thin = 100
        case extraLight = 200
        case light = 300
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700
        case extraBold = 800
        case black = 900

        public static func < (lhs: Weight, rhs: Weight) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The family name, for diagnostics.
    public let name: String

    private var upright: [Weight: EmbeddedFont] = [:]
    private var italics: [Weight: EmbeddedFont] = [:]

    /// A monospaced face, for anything set in code.
    public var mono: EmbeddedFont?

    /// An empty family, ready for faces to be added.
    public init(name: String = "") {
        self.name = name
    }

    // MARK: Building

    /// Adds a face at a weight.
    public mutating func add(_ face: EmbeddedFont, weight: Weight, italic: Bool = false) {
        if italic { italics[weight] = face } else { upright[weight] = face }
    }

    /// The same, chainable.
    public func adding(_ face: EmbeddedFont, weight: Weight, italic: Bool = false) -> FontFamily {
        var copy = self
        copy.add(face, weight: weight, italic: italic)
        return copy
    }

    /// Adds a face at the weight and slope it declares for itself.
    ///
    /// Convenient when loading a directory of files whose names cannot be
    /// trusted — `Inter-Regular.ttf` is a convention, not a guarantee, and the
    /// OS/2 table is what the renderer will believe either way.
    public mutating func add(_ face: EmbeddedFont) {
        let declared = Weight(rawValue: (face.weightClass / 100) * 100) ?? .regular
        add(face, weight: declared, italic: face.isItalic)
    }

    /// Loads a family from files, each at a stated weight.
    public static func load(
        name: String = "",
        _ faces: [(url: URL, weight: Weight, italic: Bool)]
    ) throws -> FontFamily {
        var family = FontFamily(name: name)
        for face in faces {
            family.add(try EmbeddedFont.load(face.url), weight: face.weight, italic: face.italic)
        }
        return family
    }

    // MARK: Resolving

    /// The face for a weight, or the nearest one loaded.
    ///
    /// Nearest rather than exact, because a layout should not have to know
    /// which files the caller happened to supply. Ties resolve to the heavier
    /// face: a heading asking for semibold reads better set in bold than in
    /// regular, and the request was for emphasis.
    ///
    /// An italic request falls back to the upright of the same weight when the
    /// family has no italics. The alternative is drawing nothing, and a
    /// missing line is worse than an unslanted one.
    public func face(_ weight: Weight = .regular, italic: Bool = false) -> EmbeddedFont? {
        if italic, let exact = italics[weight] { return exact }
        if !italic, let exact = upright[weight] { return exact }

        if italic, let nearest = nearest(to: weight, in: italics) { return nearest }
        return nearest(to: weight, in: upright)
    }

    private func nearest(to weight: Weight, in faces: [Weight: EmbeddedFont]) -> EmbeddedFont? {
        WeightResolution.nearest(to: weight, among: Array(faces.keys)).flatMap { faces[$0] }
    }

    /// The face standing in for one of the base-14 fonts.
    ///
    /// This is what upgrades existing layout code without touching it: a
    /// template that asks for `.helveticaBold` gets the family's bold, and one
    /// written before families existed keeps working unchanged.
    func face(for font: Font) -> EmbeddedFont? {
        switch font {
        case .helvetica: return face(.regular)
        case .helveticaBold: return face(.bold)
        case .courier: return mono
        }
    }

    /// Every face the family holds, in a stable order.
    ///
    /// Stable because the PDF resource names are assigned from it, and a
    /// dictionary's order is not — two renders of the same document would
    /// otherwise differ byte for byte.
    var faces: [EmbeddedFont] {
        let sortedUpright = upright.sorted { $0.key < $1.key }.map(\.value)
        let sortedItalics = italics.sorted { $0.key < $1.key }.map(\.value)
        return sortedUpright + sortedItalics + (mono.map { [$0] } ?? [])
    }

    /// Whether any face has been loaded.
    public var isEmpty: Bool { upright.isEmpty && italics.isEmpty && mono == nil }
}
