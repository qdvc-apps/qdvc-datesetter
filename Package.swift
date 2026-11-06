// swift-tools-version: 5.10
//
// QDVC Datesetter for macOS: drop JPEG and HEIC photos onto the window and set
// their EXIF dates in bulk. Only the EXIF data changes; the image data is
// never re-encoded. The app never touches the network (docs/MAINTENANCE.md).
//
// Build:   swift build            (or open this folder in Xcode)
// Test:    swift test
// Bundle:  scripts/build-app.sh   (sandboxed, ad-hoc signed .app, no Apple account needed)
//
// No dependencies, on purpose: nothing is ever fetched to build the app.

import PackageDescription

var products: [Product] = [
    .library(name: "DatesetterCore", targets: ["DatesetterCore"]),
]
var targets: [Target] = [
    // Pure model layer: Foundation only, no AppKit/SwiftUI, unit-testable.
    // Reads and writes the EXIF dates of JPEG and HEIC files.
    .target(name: "DatesetterCore"),
    .testTarget(
        name: "DatesetterCoreTests",
        dependencies: ["DatesetterCore"]
    ),
]

#if os(macOS)
// The SwiftUI/AppKit front-end. Declared on macOS only, so the core and its
// tests also build with a Linux Swift toolchain (docs/MAINTENANCE.md).
products.insert(.executable(name: "QDVCDatesetter", targets: ["QDVCDatesetter"]), at: 0)
targets.insert(.executableTarget(name: "QDVCDatesetter", dependencies: ["DatesetterCore"]), at: 1)
#endif

let package = Package(
    name: "QDVCDatesetter",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
