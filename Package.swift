// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Perlustra",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perlustra", targets: ["Perlustra"])
    ],
    targets: [
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        .systemLibrary(name: "CDuckDB", path: "Sources/CDuckDB"),
        .target(name: "PerlustraObjC", path: "Sources/PerlustraObjC"),
        .target(
            name: "PerlustraCore",
            dependencies: ["CArchive", "CDuckDB"],
            path: "Sources/PerlustraCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PerlustraApp",
            dependencies: ["PerlustraCore", "PerlustraObjC"],
            path: "Sources/PerlustraApp",
            exclude: ["Resources", "Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("PDFKit"),
                .linkedFramework("AVKit"), .linkedFramework("AVFoundation"), .linkedFramework("WebKit"),
                .linkedFramework("CoreText"), .linkedFramework("OpenGL"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("QuickLookThumbnailing"), .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "Perlustra",
            dependencies: ["PerlustraApp"],
            path: "Sources/Perlustra"
        ),
        .testTarget(
            name: "PerlustraAppTests",
            dependencies: ["PerlustraApp", "PerlustraCore"],
            path: "Tests/PerlustraAppTests"
        ),
        .testTarget(
            name: "PerlustraCoreTests",
            dependencies: ["PerlustraCore"],
            path: "Tests/PerlustraCoreTests"
        ),
    ]
)
