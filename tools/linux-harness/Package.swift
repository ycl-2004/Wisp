// swift-tools-version: 5.9
import PackageDescription

// Linux verification scaffold for Wisp's Foundation-only core.
// NOT part of the shipped app: not referenced by project.yml, never
// built by Xcode or CI's macOS jobs. See README.md.
let package = Package(
    name: "WispLinuxHarness",
    targets: [
        .target(name: "WispCore"),
        .testTarget(name: "WispCoreTests", dependencies: ["WispCore"]),
    ]
)
