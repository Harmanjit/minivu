import Foundation

/// Which slide plays when: the order of a run, where it is, and where it
/// goes next.
///
/// Plain values with no AppKit, so every rule is unit tested:
///
/// - **Shuffle** puts the starting image first and the rest in a random
///   order fixed for the run, so each image shows once per pass and a loop
///   repeats the same order.
/// - **The ends**: with looping, the last slide is followed by the first
///   (and the first preceded by the last); without, there is nothing next
///   and the show ends there.
/// - **Failures**: an image that won't load is marked and skipped from then
///   on, in both directions.
nonisolated struct SlideshowSequence: Equatable {
    /// Image indices in playing order.
    private(set) var order: [Int]
    /// Where in `order` the show is.
    private(set) var position: Int
    var loops: Bool
    /// Images that failed to load.
    private(set) var failed: Set<Int> = []

    init(count: Int, start: Int, shuffled: Bool, loops: Bool, generator: inout some RandomNumberGenerator) {
        let first = count == 0 ? 0 : min(max(start, 0), count - 1)
        if shuffled, count > 1 {
            let rest = (0..<count).filter { $0 != first }.shuffled(using: &generator)
            order = [first] + rest
            position = 0
        } else {
            order = Array(0..<count)
            position = first
        }
        self.loops = loops
    }

    init(count: Int, start: Int, shuffled: Bool, loops: Bool) {
        var generator = SystemRandomNumberGenerator()
        self.init(count: count, start: start, shuffled: shuffled, loops: loops, generator: &generator)
    }

    /// The image on screen (or about to be).
    var current: Int? { order.indices.contains(position) ? order[position] : nil }

    /// The image the show moves to next, skipping failures; nil at the end
    /// of a show that doesn't loop, or when no other image can play.
    var next: Int? { step(1).map { order[$0] } }
    var previous: Int? { step(-1).map { order[$0] } }

    /// Whether any image may still play.
    var hasPlayable: Bool { failed.count < order.count }

    /// Whether the show is over once the slide on screen has had its time:
    /// nothing comes next and it doesn't loop, or nothing can play at all.
    /// A looping show whose only playable slide is on screen isn't over; it
    /// keeps showing that slide.
    var isOverAfterCurrent: Bool {
        next == nil && (!loops || !hasPlayable || current.map(failed.contains) != false)
    }

    /// Moves to `next`; false when there is none.
    @discardableResult
    mutating func advance() -> Bool {
        guard let target = step(1) else { return false }
        position = target
        return true
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard let target = step(-1) else { return false }
        position = target
        return true
    }

    mutating func markFailed(_ index: Int) {
        failed.insert(index)
    }

    /// The position `direction` steps lead to, past failed images. Never the
    /// current position itself: a single image doesn't transition into itself.
    private func step(_ direction: Int) -> Int? {
        guard !order.isEmpty else { return nil }
        var candidate = position
        for _ in 0..<order.count {
            candidate += direction
            if candidate >= order.count {
                guard loops else { return nil }
                candidate = 0
            } else if candidate < 0 {
                guard loops else { return nil }
                candidate = order.count - 1
            }
            if candidate == position { return nil }
            if !failed.contains(order[candidate]) { return candidate }
        }
        return nil
    }
}
