import Foundation
import Metal
import CoreGraphics
import Synchronization
import MinivuCore

/// Plays an animated GIF, APNG, WebP or HEICS by handing the canvas one
/// texture per frame, on the file's own timing.
///
/// Three rules keep a looping animation cheap enough to leave running:
///
/// - **Textures are made once.** All frame textures are views into one
///   shared-memory buffer allocated for the frame size; a frame is decoded
///   straight into its slot's memory, which the GPU then reads in place.
///   Nothing is allocated per frame or per loop.
/// - **Small animations are decoded once.** When every frame fits in
///   `preloadBudgetBytes`, each frame gets its own slot, and after the
///   first loop playback costs no decoding at all. Larger ones keep a few
///   slots and decode just ahead of the frame on screen, reusing the slot
///   shown longest ago.
/// - **Nothing runs unless a frame is due.** One work item is scheduled for
///   the moment the next frame is due; there is no repeating timer. Paused,
///   finished or suspended (the window can't be seen), nothing is scheduled
///   and no decode is started, so the CPU stays idle.
///
/// Decoding happens on a serial queue, in frame order, which is what ImageIO
/// composites fastest. Everything else is main-actor state, so it needs no
/// locks; only the "is this work still wanted" generation is shared.
@MainActor public final class AnimationPlayer {
    /// Frames of an animation whose decoded frames fit in this are all kept.
    nonisolated public static let preloadBudgetBytes = 64 << 20
    /// Slots kept for larger animations: the frame on screen and at least two
    /// decoded ahead, so one late decode doesn't stall playback.
    nonisolated static let minimumSlots = 3
    nonisolated static let maximumSlots = 8
    /// Decodes queued at once. More would keep the CPU busy after a pause.
    static let maximumPendingDecodes = 2
    /// A frame arriving later than this after it was due restarts the clock
    /// from now, rather than rushing through the frames after it to catch up.
    static let catchUpLimit: TimeInterval = 0.1

    public let url: URL

    /// Called with each frame to show. The texture's `imageSize` is the
    /// animation's full size, so the canvas can keep its zoom and pan.
    public var onFrame: ((ImageTexture) -> Void)?
    /// Called when playback starts, pauses or reaches the end of its loops.
    public var onStateChange: (() -> Void)?

    /// 0 until the file's header has been read.
    public private(set) var frameCount = 0
    /// The frame on screen (or about to be).
    public private(set) var currentFrame = 0
    /// What the user wants: true while playing, false when paused or when
    /// the animation has played all its loops.
    public private(set) var isPlaying: Bool
    /// True while nobody can see the animation (its window is hidden or
    /// covered). The clock stops without changing `isPlaying`.
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                cancelTick()
            } else {
                resumeClock()
            }
        }
    }

    /// The animation's pixel size, once known.
    public var imageSize: CGSize? { frames?.pixelSize }
    /// True when frames are decoded at the animation's own size.
    public var isFullResolution: Bool { store?.isFullResolution ?? false }

    private let gpu: GPU
    private var maxPixelSize: Int
    private let budgetBytes: Int
    private var frames: AnimationFrames?
    private var store: FrameStore?
    private let queue = DispatchQueue(label: "minivu.animation", qos: .userInitiated)

    /// Bumped whenever the frame store is replaced or playback stops, so
    /// decodes for the old one are skipped or ignored.
    private var generation = 0
    private let liveGeneration = Generation()

    /// Which frame each slot holds and which slot holds each frame, kept in
    /// step so both lookups are instant (they run on every frame), and when
    /// each slot was last shown (for picking the slot to overwrite).
    private var slotFrame: [Int?] = []
    private var frameSlot: [Int?] = []
    private var filledSlots = 0
    private var slotLastShown: [Int] = []
    private var showCount = 0
    /// Frames being decoded, and the slot each is going into.
    private var pending: [Int: Int] = [:]
    private var unreadableFrames: Set<Int> = []
    /// A frame that is due but not decoded yet, and when it was due.
    private var waiting: (frame: Int, due: TimeInterval)?
    /// When the frame on screen was due: its delay counts from here.
    private var currentStart: TimeInterval = 0
    private var tick: DispatchWorkItem?
    private var loopsCompleted = 0
    private var isStopped = false

    /// - Parameters:
    ///   - pixelSize: long edge to decode frames at (the canvas's size);
    ///     never more than the animation's own.
    ///   - playing: start playing once the first frame is shown.
    public convenience init(url: URL, pixelSize: Int, playing: Bool = true, gpu: GPU = .shared) {
        self.init(url: url, pixelSize: pixelSize, playing: playing, budgetBytes: Self.preloadBudgetBytes, gpu: gpu)
    }

    /// With a different preload budget, for tests of the decode-ahead path.
    init(url: URL, pixelSize: Int, playing: Bool, budgetBytes: Int, gpu: GPU) {
        self.url = url
        self.maxPixelSize = pixelSize
        self.isPlaying = playing
        self.budgetBytes = budgetBytes
        self.gpu = gpu
        open()
    }

    // MARK: - Control

    public func play() {
        guard !isStopped, !isPlaying else { return }
        isPlaying = true
        if let frames, frames.loopCount > 0, loopsCompleted >= frames.loopCount {
            // Finished: start over from the first frame, now.
            loopsCompleted = 0
            cancelTick()
            let now = ProcessInfo.processInfo.systemUptime
            if slot(holding: 0) != nil {
                show(0, due: now)
            } else {
                waiting = (0, now)
            }
            fill()
        } else {
            resumeClock()
        }
        onStateChange?()
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        cancelTick()
        // Keep waiting only for a frame that has never been shown.
        if let waiting, waiting.frame != currentFrame { self.waiting = nil }
        onStateChange?()
    }

    public func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    /// Stops for good: no more frames or callbacks. The last texture handed
    /// out stays valid for as long as someone holds it.
    public func stop() {
        isStopped = true
        isPlaying = false
        cancelTick()
        invalidateWork()
        onFrame = nil
        onStateChange = nil
        store = nil
        pending = [:]
        waiting = nil
    }

    /// Decodes frames for a different size from the next frame on: larger
    /// when the user zooms in, smaller when the window shrinks.
    public func setPixelSize(_ pixelSize: Int) {
        guard pixelSize != maxPixelSize else { return }
        maxPixelSize = pixelSize
        guard let frames, let store, !isStopped else { return }
        let size = Self.frameSize(imageSize: frames.pixelSize, maxPixelSize: pixelSize)
        guard size.width != store.width || size.height != store.height else { return }
        makeStore()
    }

    // MARK: - Sizes

    /// Frame dimensions for a long edge of `maxPixelSize`, never larger than
    /// the animation itself or Metal's texture limit.
    nonisolated static func frameSize(imageSize: CGSize, maxPixelSize: Int) -> (width: Int, height: Int) {
        let long = max(imageSize.width, imageSize.height, 1)
        let edge = min(CGFloat(max(maxPixelSize, 1)), long, CGFloat(TextureUploader.maximumDimension))
        let scale = edge / long
        return (max(1, Int((imageSize.width * scale).rounded())), max(1, Int((imageSize.height * scale).rounded())))
    }

    /// Every frame when they all fit in the budget; otherwise a few slots to
    /// decode ahead into.
    nonisolated static func slotCount(frameCount: Int, bytesPerFrame: Int, budget: Int = preloadBudgetBytes) -> Int {
        guard frameCount > 0 else { return 0 }
        if frameCount * bytesPerFrame <= budget { return frameCount }
        return min(frameCount, max(minimumSlots, min(maximumSlots, budget / max(bytesPerFrame, 1))))
    }

    // MARK: - Opening

    private func open() {
        let url = url, token = generation, live = liveGeneration
        queue.async { [weak self] in
            guard live.value == token else { return }
            let frames = AnimationFrames(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.opened(frames, generation: token) }
            }
        }
    }

    private func opened(_ frames: AnimationFrames?, generation token: Int) {
        guard token == generation, !isStopped, let frames else { return }
        self.frames = frames
        frameCount = frames.frameCount
        currentFrame = 0
        makeStore()
    }

    /// A new set of frame textures for the current size. The frame on screen
    /// is decoded again first, then playback carries on from it.
    private func makeStore() {
        guard let frames else { return }
        invalidateWork()
        cancelTick()
        let size = Self.frameSize(imageSize: frames.pixelSize, maxPixelSize: maxPixelSize)
        let bytes = FrameStore.bytesPerFrame(width: size.width, height: size.height, gpu: gpu)
        let slots = Self.slotCount(frameCount: frames.frameCount, bytesPerFrame: bytes, budget: budgetBytes)
        // Allocating is cheap: the buffer's pages are only touched as frames
        // are decoded into them, on the decode queue.
        store = FrameStore(width: size.width, height: size.height, slots: slots, imageSize: frames.pixelSize, gpu: gpu)
        slotFrame = Array(repeating: nil, count: slots)
        frameSlot = Array(repeating: nil, count: frames.frameCount)
        filledSlots = 0
        slotLastShown = Array(repeating: 0, count: slots)
        pending = [:]
        waiting = (currentFrame, ProcessInfo.processInfo.systemUptime)
        fill()
    }

    private func invalidateWork() {
        generation += 1
        liveGeneration.value = generation
    }

    // MARK: - Decoding

    /// Queues decodes for the frame being waited for and, while playing, the
    /// frames after the one on screen, as many as there are spare slots.
    private func fill() {
        guard let frames, let store, !isStopped else { return }
        let count = frames.frameCount
        // Every frame kept and decoded: the usual case once a small animation
        // has played through, and the one that must cost nothing per frame.
        if store.slotCount == count, filledSlots + unreadableFrames.count >= count { return }
        let window = isPlaying && !isSuspended ? store.slotCount : 0
        var step = -1
        while pending.count < Self.maximumPendingDecodes {
            // The frame waited for first (step -1), then the ones ahead.
            let frame: Int
            if step < 0 {
                step = 0
                guard let waiting else { continue }
                frame = waiting.frame
            } else if step < window {
                frame = (currentFrame + step) % count
                step += 1
            } else {
                break
            }
            guard frameSlot[frame] == nil, pending[frame] == nil, !unreadableFrames.contains(frame) else { continue }
            guard let slot = reusableSlot(window: window, count: count) else { break }
            clear(slot)
            pending[frame] = slot
            decode(frame, into: slot, frames: frames, store: store)
        }
    }

    private func slot(holding frame: Int) -> Int? {
        frameSlot.indices.contains(frame) ? frameSlot[frame] : nil
    }

    private func assign(_ frame: Int, to slot: Int) {
        clear(slot)
        slotFrame[slot] = frame
        frameSlot[frame] = slot
        filledSlots += 1
    }

    private func clear(_ slot: Int) {
        guard let old = slotFrame[slot] else { return }
        frameSlot[old] = nil
        slotFrame[slot] = nil
        filledSlots -= 1
    }

    /// An empty slot, else the one shown longest ago whose frame isn't
    /// wanted soon (the `window` frames from the current one, or the frame
    /// being waited for). Never one being decoded into.
    private func reusableSlot(window: Int, count: Int) -> Int? {
        let busy = Set(pending.values)
        var best: Int?
        for slot in slotFrame.indices where !busy.contains(slot) {
            guard let frame = slotFrame[slot] else { return slot }
            let ahead = (frame - currentFrame + count) % count
            let wanted = ahead < max(window, 1) || frame == waiting?.frame
            if !wanted, best.map({ slotLastShown[slot] < slotLastShown[$0] }) ?? true { best = slot }
        }
        return best
    }

    private func decode(_ frame: Int, into slot: Int, frames: AnimationFrames, store: FrameStore) {
        let token = generation, live = liveGeneration
        let edge = max(store.width, store.height)
        queue.async { [weak self] in
            guard live.value == token else { return }
            let drawn = frames.frame(at: frame, maxPixelSize: edge).map { store.draw($0, into: slot) } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.decoded(frame, slot: slot, ok: drawn, generation: token) }
            }
        }
    }

    private func decoded(_ frame: Int, slot: Int, ok: Bool, generation token: Int) {
        guard token == generation, !isStopped else { return }
        pending[frame] = nil
        if ok {
            assign(frame, to: slot)
        } else {
            unreadableFrames.insert(frame)
        }
        if let waiting, waiting.frame == frame {
            self.waiting = nil
            show(frame, due: waiting.due)
        }
        fill()
    }

    // MARK: - Clock

    /// Puts `frame` on screen and schedules the next one. `due` is when the
    /// frame should have appeared; its delay counts from then, so small
    /// lateness doesn't accumulate over a loop.
    private func show(_ frame: Int, due: TimeInterval) {
        guard let store else { return }
        let now = ProcessInfo.processInfo.systemUptime
        currentFrame = frame
        currentStart = now - due > Self.catchUpLimit ? now : due
        if let slot = slot(holding: frame) {
            showCount += 1
            slotLastShown[slot] = showCount
            onFrame?(store.textures[slot])
        }
        // An unreadable frame just holds the previous picture for its delay.
        scheduleTick()
    }

    private func scheduleTick() {
        cancelTick()
        guard isPlaying, !isSuspended, !isStopped, let frames, frames.frameCount > 1 else { return }
        let due = currentStart + frames.delays[currentFrame]
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.advance(due: due) }
        }
        tick = work
        let wait = max(0, due - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func cancelTick() {
        tick?.cancel()
        tick = nil
    }

    /// Playing again after a pause or suspension: the frame on screen gets
    /// its full delay from now.
    private func resumeClock() {
        guard isPlaying, !isSuspended, !isStopped, store != nil else { return }
        if waiting == nil {
            currentStart = ProcessInfo.processInfo.systemUptime
            scheduleTick()
        }
        fill()
    }

    private func advance(due: TimeInterval) {
        tick = nil
        guard isPlaying, !isSuspended, !isStopped, let frames else { return }
        var next = currentFrame + 1
        if next >= frames.frameCount {
            loopsCompleted += 1
            if frames.loopCount > 0, loopsCompleted >= frames.loopCount {
                isPlaying = false
                onStateChange?()
                return
            }
            next = 0
        }
        if slot(holding: next) != nil || unreadableFrames.contains(next) {
            show(next, due: due)
            fill()
        } else {
            // Not decoded yet (a large animation on a busy machine): show it
            // the moment it is.
            waiting = (next, due)
            fill()
        }
    }
}

/// The decode queue's view of whether its work is still wanted.
private final class Generation: Sendable {
    private let atomic = Atomic<Int>(0)
    var value: Int {
        get { atomic.load(ordering: .relaxed) }
        set { atomic.store(newValue, ordering: .relaxed) }
    }
}

/// One shared-memory buffer holding every frame slot, and a texture over
/// each slot. The decode queue draws into a slot's memory; the canvas
/// samples the same pages, with no copy and no upload.
///
/// `@unchecked Sendable`: the player never lets the queue draw into a slot
/// that is on screen, and slots are only read by the GPU.
final class FrameStore: @unchecked Sendable {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    let width: Int
    let height: Int
    let slotCount: Int
    let isFullResolution: Bool
    let textures: [ImageTexture]
    private let bytesPerRow: Int
    private let slotLength: Int
    private let buffer: MTLBuffer

    /// Bytes one slot takes: rows padded to the GPU's alignment, the whole
    /// padded to a page so every slot starts on a page boundary (which any
    /// alignment Metal asks of a texture's offset divides).
    static func bytesPerFrame(width: Int, height: Int, gpu: GPU) -> Int {
        let row = TextureUploader.roundUp(width * 4, to: gpu.device.minimumLinearTextureAlignment(for: pixelFormat))
        return TextureUploader.roundUp(row * height, to: Int(getpagesize()))
    }

    init?(width: Int, height: Int, slots: Int, imageSize: CGSize, gpu: GPU) {
        guard slots > 0 else { return nil }
        self.width = width
        self.height = height
        slotCount = slots
        bytesPerRow = TextureUploader.roundUp(width * 4, to: gpu.device.minimumLinearTextureAlignment(for: Self.pixelFormat))
        slotLength = Self.bytesPerFrame(width: width, height: height, gpu: gpu)
        guard let buffer = gpu.device.makeBuffer(length: slotLength * slots, options: .storageModeShared) else {
            return nil
        }
        self.buffer = buffer
        isFullResolution = max(width, height) >= Int(max(imageSize.width, imageSize.height).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        var textures: [ImageTexture] = []
        for slot in 0..<slots {
            guard let texture = buffer.makeTexture(descriptor: descriptor, offset: slot * slotLength,
                                                   bytesPerRow: bytesPerRow) else { return nil }
            textures.append(ImageTexture(texture: texture, imageSize: imageSize, isFullResolution: isFullResolution,
                                         isHDR: false, contentHeadroom: 1))
        }
        self.textures = textures
    }

    /// Draws a frame into a slot, converting it to Display P3 (the canvas's
    /// SDR working space). Rows are stored top first, as the texture wants.
    func draw(_ image: CGImage, into slot: Int) -> Bool {
        guard (0..<slotCount).contains(slot),
              let context = CGContext(data: buffer.contents() + slot * slotLength, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        // Copy replaces every pixel, transparent ones included, so the
        // previous frame in this slot never shows through.
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
}
