// swift-tools-version: 6.2
import PackageDescription

// minivu: a lightweight image browser, viewer and editor for macOS.
// GPLv3. No third-party dependencies: everything below the app is Apple's
// own frameworks (ImageIO, Metal, Core Image, PDFKit, SQLite3, AppKit).

let package = Package(
    name: "minivu",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "minivu", targets: ["Minivu"]),
    ],
    targets: [
        // Decoding, metadata, folders, the catalog and the thumbnail cache.
        // No AppKit windows and no Metal, so it's quick to test.
        .target(
            name: "MinivuCore",
            path: "Sources/MinivuCore"
        ),
        // Everything that touches the GPU: textures, the canvas presenter,
        // histogram, edit kernels, slideshow transitions.
        .target(
            name: "MinivuRender",
            dependencies: ["MinivuCore"],
            path: "Sources/MinivuRender",
            resources: [.copy("Shaders")]
        ),
        // The AppKit application. UI code runs on the main actor by default,
        // so only background work needs explicit isolation.
        .executableTarget(
            name: "Minivu",
            dependencies: ["MinivuCore", "MinivuRender"],
            path: "Sources/Minivu",
            // Help > minivu Help: Markdown pages, rendered in the app.
            resources: [.copy("Help/HelpPages")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Started when the test bundle loads, on a thread of its own: ends a
        // run whose cooperative pool is starved instead of letting it hang
        // (docs/feature-notes/coop-starvation.md). C, for the load-time
        // constructor Swift can't declare. Test-only; never in the app.
        .target(
            name: "MinivuTestWatchdog",
            path: "Tests/MinivuTestWatchdog"
        ),
        .testTarget(
            name: "MinivuCoreTests",
            dependencies: ["MinivuCore", "MinivuTestWatchdog"],
            path: "Tests/MinivuCoreTests",
            // A catalog written by the minivu that had schema version 2,
            // for the upgrade test.
            resources: [.copy("Fixtures")]
        ),
        // The app's own logic (menus, launch, snapshot harness). SwiftPM
        // lets tests import an executable target.
        .testTarget(
            name: "MinivuTests",
            dependencies: ["Minivu", "MinivuTestWatchdog"],
            path: "Tests/MinivuTests"
        ),
        .testTarget(
            name: "MinivuRenderTests",
            dependencies: ["MinivuRender", "MinivuCore", "MinivuTestWatchdog"],
            path: "Tests/MinivuRenderTests"
        ),
    ]
)
