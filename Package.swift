// swift-tools-version:5.9
//
// `swift build` compiles everything; ./build.sh wraps the app into "Reverb Room.app".

import PackageDescription

let package = Package(
    name: "ReverbRoom",
    platforms: [.macOS("14.2")],
    targets: [
        // C11 atomics for values shared between the UI and the real-time audio thread.
        .target(name: "RRAtomics", path: "Sources/RRAtomics"),
        // The reverb itself: impulse-response generator, FFT convolver, processor.
        .target(name: "ReverbDSP", dependencies: ["RRAtomics"], path: "Sources/ReverbDSP"),
        // The macOS app: Apple Music tap, audio pipeline, SwiftUI window and menu bar.
        .executableTarget(name: "ReverbRoom", dependencies: ["ReverbDSP"], path: "Sources/ReverbRoom"),
        // `swift run -c release dsp-check`: verifies the convolver and measures CPU cost.
        .executableTarget(name: "dsp-check", dependencies: ["ReverbDSP"], path: "Sources/dsp-check")
    ]
)
