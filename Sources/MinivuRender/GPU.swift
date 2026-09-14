import Foundation
import Metal

public enum GPUError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case shadersNotFound
    case missingFunction(String)
    case allocationFailed(String)

    public var description: String {
        switch self {
        case .noDevice: "No Metal device (unreachable on Apple Silicon)."
        case .noCommandQueue: "Could not create a Metal command queue."
        case .shadersNotFound: "No Metal shader sources or library found in the MinivuRender bundle."
        case .missingFunction(let name): "Metal function '\(name)' is missing from the shader library."
        case .allocationFailed(let what): "Could not allocate \(what)."
        }
    }
}

/// The one Metal device, command queue and shader library for the app.
///
/// Created once at launch. Pipeline states are built on first use and kept,
/// so nothing Metal-related is created per frame or per image.
///
/// `@unchecked Sendable` is safe because the Metal objects are documented
/// as thread-safe and the only mutable state (the pipeline cache) is behind
/// a lock.
public final class GPU: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary

    private let lock = NSLock()
    private var computePipelines: [String: MTLComputePipelineState] = [:]
    private var renderPipelines: [String: MTLRenderPipelineState] = [:]

    /// The shared instance. Creating it compiles the shaders, so touch it
    /// early (at launch) rather than on the first image.
    public static let shared: GPU = {
        do { return try GPU() } catch { fatalError("Metal setup failed: \(error)") }
    }()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw GPUError.noCommandQueue }
        self.device = device
        self.queue = queue
        self.library = try Self.loadLibrary(device: device)
    }

    // MARK: - Pipelines

    /// A compute pipeline for a kernel function, built once and cached.
    public func computePipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let cached = computePipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else { throw GPUError.missingFunction(name) }
        let pipeline = try device.makeComputePipelineState(function: function)
        computePipelines[name] = pipeline
        return pipeline
    }

    /// A render pipeline, built once per key by `make` and cached.
    public func renderPipeline(_ key: String,
                               make: (MTLDevice, MTLLibrary) throws -> MTLRenderPipelineState)
        rethrows -> MTLRenderPipelineState {
        lock.lock(); defer { lock.unlock() }
        if let cached = renderPipelines[key] { return cached }
        let pipeline = try make(device, library)
        renderPipelines[key] = pipeline
        return pipeline
    }

    /// Runs a compute kernel over `size`, choosing threadgroup sizes from
    /// the pipeline. The caller sets textures and buffers in `bind`.
    public func dispatch(_ pipeline: MTLComputePipelineState, size: MTLSize,
                         encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    // MARK: - Shader library

    /// Prefers a precompiled `default.metallib` (built by make_app.sh when
    /// the Metal toolchain is installed). Otherwise compiles the bundled
    /// `.metal` sources at launch, which takes a fraction of a second.
    ///
    /// Runtime compilation has no include paths, so `Common.h` is pasted in
    /// once at the top and `#include "Common.h"` lines are dropped. Every
    /// `.metal` file in the folder is picked up; there is no list to keep
    /// in sync.
    static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        let bundle = Bundle.minivuRender
        if let url = bundle.url(forResource: "default", withExtension: "metallib", subdirectory: "Shaders")
            ?? bundle.url(forResource: "default", withExtension: "metallib"),
           let library = try? device.makeLibrary(URL: url) {
            return library
        }
        guard let shaderDir = bundle.url(forResource: "Shaders", withExtension: nil) else {
            throw GPUError.shadersNotFound
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: shaderDir, includingPropertiesForKeys: nil)) ?? []
        let sources = files.filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sources.isEmpty else { throw GPUError.shadersNotFound }

        var combined = ""
        let header = shaderDir.appendingPathComponent("Common.h")
        if let text = try? String(contentsOf: header, encoding: .utf8) { combined += text + "\n" }
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            combined += text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("#include \"Common.h\"") }
                .joined(separator: "\n") + "\n"
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        options.mathMode = .fast
        return try device.makeLibrary(source: combined, options: options)
    }
}

extension Bundle {
    /// MinivuRender's resource bundle, found where a shipped app keeps it.
    ///
    /// SwiftPM's generated `Bundle.module` looks beside the executable and
    /// in the build folder, but an .app keeps resources in
    /// Contents/Resources. Look there first so the bundled app works after
    /// the build folder is gone (a crash Latent hit).
    public static let minivuRender: Bundle = {
        let name = "minivu_MinivuRender.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
