// swift-tools-version:5.9
//
// Lets VS Code (Swift extension / sourcekit-lsp) understand the project:
// autocomplete, cross-file errors, jump-to-definition. `swift build` compiles it;
// ./build.sh wraps the result into a runnable .app.

import PackageDescription

let package = Package(
    name: "ReverbRoom",
    platforms: [.macOS("14.2")],
    targets: [
        // C11 atomics for state the real-time audio thread shares with the UI.
        .target(
            name: "SSHAtomics",
            path: "Sources/SSHAtomics"
        ),
        .executableTarget(
            name: "ReverbRoom",
            dependencies: ["SSHAtomics"],
            path: "Sources/SSH"
        ),
        // Pure logic only (palette, loudness tone). Swift Testing; XCTest isn't
        // part of the Command Line Tools.
        .testTarget(
            name: "ReverbRoomTests",
            dependencies: ["ReverbRoom"],
            path: "Tests/ReverbRoomTests"
        )
    ]
)
