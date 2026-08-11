// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TextPDF",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "TextPDF",
            targets: ["TextPDF"]
        ),
    ],
    targets: [
        // No dependencies, deliberately. Writing the PDF directly is the
        // whole point: no HTML engine, no font embedding, no image codecs.
        .target(name: "TextPDF"),
        .testTarget(name: "TextPDFTests", dependencies: ["TextPDF"]),
    ]
)
