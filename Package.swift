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
        // C11 atomics for ReverbDSP's lock-free handoff with the real-time thread.
        // Ported from the reverb-room sibling project (same source, unchanged).
        .target(
            name: "RRAtomics",
            path: "Sources/RRAtomics"
        ),
        // AVM's own convolution reverb engine, ported from reverb-room: synthesized
        // stereo room impulse responses (early reflections + a decorrelated tail
        // with real RT60 decay and air/wall absorption), a partitioned-FFT
        // convolver (Accelerate/vDSP), a reverb-return EQ baked into the response,
        // true stereo crossfeed, a de-ess/transient-soften send conditioner, BS.1770
        // loudness matching and a lookahead true-peak limiter. Replaces both the
        // stock AVAudioUnitReverb and the avm-supermassive branch's hosted plugin —
        // see Decisions.md.
        .target(
            name: "ReverbDSP",
            dependencies: ["RRAtomics"],
            path: "Sources/ReverbDSP"
        ),
        .executableTarget(
            name: "AppleVisualizedMusic",
            dependencies: ["AVMAtomics", "ReverbDSP"],
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
