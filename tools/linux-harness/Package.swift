// swift-tools-version: 5.9
import PackageDescription

// Verification scaffold for Wisp's Foundation-only core, for machines without
// Xcode (the Linux cloud agents) and for running the core tests on a Mac without
// launching the app as a test host. NOT part of the shipped app: not referenced
// by project.yml, never built by Xcode. See README.md.
//
// The module is named `Wisp` so the test files copied from ../../WispTests
// compile verbatim (`@testable import Wisp`). Both target directories are
// filled by sync-sources.sh.
let package = Package(
    name: "WispHarness",
    targets: [
        .target(name: "Wisp"),
        .testTarget(name: "WispTests", dependencies: ["Wisp"]),
    ]
)
