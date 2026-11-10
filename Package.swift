// swift-tools-version: 6.2
import PackageDescription

// Swift 6.2's upcoming features, on for every target so the package builds
// the same under a host that enables them.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "GhosttyKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "ShellCraftKit", targets: ["ShellCraftKit"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "DisplayLink"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
                .process("Resources/Localization"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ShellCraftKit",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/ShellCraftKit",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"],
            swiftSettings: swiftSettings
        ),
        .binaryTarget(
            name: "libghostty",
            // Upstream's upstream.042b16b6146a build, post-processed by
            // Script/localize-runtime-symbols.sh so it links next to a Rust
            // static library (duplicate ___isPlatformVersionAtLeast).
            url: "https://github.com/Maatskappy/libghostty-spm/releases/download/inby.2.2.2026110702/GhosttyKit.xcframework.zip",
            checksum: "b77d59b93ff2d380651da8bbaeb499a3699d9e7ad33b8560452901a09544cc6a",
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
