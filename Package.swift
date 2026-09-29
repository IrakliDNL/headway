// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Headway",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure decision logic: models, filters, the focus engine. No camera, no AppKit — fully testable.
        .target(name: "HeadwayCore"),
        // The menu-bar app: camera, Vision, Accessibility, windows and settings UI.
        .executableTarget(
            name: "Headway",
            dependencies: ["HeadwayCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "HeadwayCoreTests", dependencies: ["HeadwayCore"]),
    ]
)
