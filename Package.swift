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
        // C interface to Signalsmith Stretch (vendored, MIT), the pitch shifter.
        .target(
            name: "RRStretch",
            path: "Sources/RRStretch",
            exclude: ["vendor/README.md", "vendor/signalsmith-stretch/LICENSE.txt",
                      "vendor/signalsmith-linear/LICENSE.txt"],
            cxxSettings: [
                .headerSearchPath("vendor/signalsmith-linear/include"),
                .define("SIGNALSMITH_USE_ACCELERATE"),
                .unsafeFlags(["-O3"])
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // The DSP: impulse-response generator, FFT convolver, pitch shifter, processor.
        .target(name: "ReverbDSP", dependencies: ["RRAtomics", "RRStretch"], path: "Sources/ReverbDSP"),
        // The macOS app: app discovery, audio tap and pipeline, SwiftUI window and menu bar.
        .executableTarget(name: "ReverbRoom", dependencies: ["ReverbDSP"], path: "Sources/ReverbRoom"),
        // `swift run -c release dsp-check`: verifies the DSP and measures CPU cost.
        .executableTarget(name: "dsp-check", dependencies: ["ReverbDSP"], path: "Sources/dsp-check")
    ],
    cxxLanguageStandard: .cxx17
)
