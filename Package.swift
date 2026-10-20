// swift-tools-version:5.9
//
// Lets VS Code (Swift extension / sourcekit-lsp) understand the project:
// autocomplete, cross-file errors, jump-to-definition. `swift build` compiles it;
// ./build.sh wraps the result into a runnable .app.

import PackageDescription

let package = Package(
    name: "AppleVisualizedMusic",
    platforms: [.macOS("14.2")],
    targets: [
        // C11 atomics for state the real-time audio thread shares with the UI.
        .target(
            name: "AVMAtomics",
            path: "Sources/AVMAtomics"
        ),
        .executableTarget(
            name: "AppleVisualizedMusic",
            dependencies: ["AVMAtomics"],
            path: "Sources/AVM"
        ),
        // Pure logic only (palette, loudness tone). Swift Testing; XCTest isn't
        // part of the Command Line Tools.
        .testTarget(
            name: "AVMTests",
            dependencies: ["AppleVisualizedMusic"],
            path: "Tests/AVMTests"
        )
    ]
)
