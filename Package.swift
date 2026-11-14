// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftDocxTemplate",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SwiftDocxTemplate",
            targets: ["SwiftDocxTemplate"]
        ),
        .executable(
            name: "QuickstartExample",
            targets: ["QuickstartExample"]
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
