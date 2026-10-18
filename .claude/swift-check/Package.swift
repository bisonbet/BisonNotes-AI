// swift-tools-version:5.10
// Linux-only check package assembled by swift-check.sh; not part of the app.
import PackageDescription

let package = Package(
    name: "BisonNotesSwiftCheck",
    targets: [
        .target(name: "BisonNotes_AI", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .testTarget(name: "BisonNotes_AITests", dependencies: ["BisonNotes_AI"]),
    ]
)
