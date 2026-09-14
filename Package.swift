// swift-tools-version: 6.2
import PackageDescription

// Agate: a lightweight image browser, viewer and editor for macOS.
// GPLv3. No third-party dependencies: everything below the app is Apple's
// own frameworks (ImageIO, Metal, Core Image, PDFKit, SQLite3, AppKit).

let package = Package(
    name: "agate",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "agate", targets: ["Agate"]),
    ],
    targets: [
        // Decoding, metadata, folders, the catalog and the thumbnail cache.
        // No AppKit windows and no Metal, so it's quick to test.
        .target(
            name: "AgateCore",
            path: "Sources/AgateCore"
        ),
        // Everything that touches the GPU: textures, the canvas presenter,
        // histogram, edit kernels, slideshow transitions.
        .target(
            name: "AgateRender",
            dependencies: ["AgateCore"],
            path: "Sources/AgateRender",
            resources: [.copy("Shaders")]
        ),
        // The AppKit application. UI code runs on the main actor by default,
        // so only background work needs explicit isolation.
        .executableTarget(
            name: "Agate",
            dependencies: ["AgateCore", "AgateRender"],
            path: "Sources/Agate",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "AgateCoreTests",
            dependencies: ["AgateCore"],
            path: "Tests/AgateCoreTests"
        ),
        .testTarget(
            name: "AgateRenderTests",
            dependencies: ["AgateRender", "AgateCore"],
            path: "Tests/AgateRenderTests"
        ),
    ]
)
