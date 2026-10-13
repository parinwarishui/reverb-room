// swift-tools-version:5.9
//
// Lets VS Code (Swift extension / sourcekit-lsp) understand the project:
// autocomplete, cross-file errors, jump-to-definition. `swift build` compiles it;
// ./build.sh wraps the result into a runnable .app.

import PackageDescription

let package = Package(
    name: "SSH",
    platforms: [.macOS("14.2")],
    targets: [
        // C11 atomics for state the real-time audio thread shares with the UI.
        .target(
            name: "SSHAtomics",
            path: "Sources/SSHAtomics"
        ),
        .executableTarget(
            name: "SSH",
            dependencies: ["SSHAtomics"],
            path: "Sources/SSH"
        )
    ]
)
