// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftDocxTemplate",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        // Single public library product for SPM / Xcode consumers.
        .library(
            name: "SwiftDocxTemplate",
            targets: ["SwiftDocxTemplate"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/tadija/AEXML.git", from: "4.6.0"),
    ],
    targets: [
        .target(
            name: "SwiftDocxTemplate",
            dependencies: [
                "ZIPFoundation",
                "AEXML",
            ]
        ),
        // Local sample only — not a package product, so it does not appear in
        // "Add Package Dependencies…" product pickers. Run with:
        //   swift run QuickstartExample
        .executableTarget(
            name: "QuickstartExample",
            dependencies: [
                "SwiftDocxTemplate",
            ],
            path: "Examples/Quickstart",
            exclude: [
                "README.md",
                "Output",
            ],
            resources: [
                .copy("ReportTemplate.docx"),
                .copy("logo.png"),
            ]
        ),
        .testTarget(
            name: "SwiftDocxTemplateTests",
            dependencies: [
                "SwiftDocxTemplate",
                "AEXML",
            ]
        ),
    ]
)
