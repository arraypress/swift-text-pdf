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

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
