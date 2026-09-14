import Testing
import Foundation
import MinivuCore
import MinivuRender
@testable import Minivu

/// A deterministic generator (SplitMix64), so shuffles are repeatable.
struct SlideshowTestGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// The slideshow's plain rules: playing order, settings, captions.
@MainActor @Suite struct SlideshowLogicTests {
    func sequence(_ count: Int, start: Int = 0, shuffled: Bool = false, loops: Bool = true,
                  seed: UInt64 = 1) -> SlideshowSequence {
        var generator = SlideshowTestGenerator(state: seed)
        return SlideshowSequence(count: count, start: start, shuffled: shuffled, loops: loops, generator: &generator)
    }

    // MARK: - Sequence

    @Test func stepsForwardAndBackWithLooping() {
        var s = sequence(3, start: 1)
        #expect(s.current == 1 && s.next == 2 && s.previous == 0)
        do { let moved = s.advance(); #expect(moved) }
        #expect(s.current == 2 && s.next == 0)   // round to the first
        do { let moved = s.advance(); #expect(moved) }
        #expect(s.current == 0 && s.previous == 2)
        do { let movedBack = s.goBack(); #expect(movedBack) }
        #expect(s.current == 2)
    }

    @Test func withoutLoopingTheEndsStop() {
        var s = sequence(3, start: 0, loops: false)
        #expect(s.previous == nil)
        do { let movedBack = s.goBack(); #expect(!movedBack) }
        s.advance()
        s.advance()
        #expect(s.current == 2)
        #expect(s.next == nil)
        do { let moved = s.advance(); #expect(!moved) }
        #expect(s.current == 2)
        // Looping turned on later (Settings) applies at once.
        s.loops = true
        #expect(s.next == 0)
    }

    @Test func aSingleImageNeverTransitionsIntoItself() {
        var s = sequence(1, loops: true)
        #expect(s.current == 0)
        #expect(s.next == nil && s.previous == nil)
        do { let moved = s.advance(); #expect(!moved) }
        #expect(sequence(0).current == nil)
        #expect(sequence(5, start: 99).current == 4)
    }

    @Test func shuffleStartsWithTheChosenImageAndShowsEachOnce() {
        for seed in 1...20 {
            var s = sequence(12, start: 5, shuffled: true, seed: UInt64(seed))
            var seen = [s.current!]
            for _ in 1..<12 {
                s.advance()
                seen.append(s.current!)
            }
            #expect(seen.first == 5)
            #expect(Set(seen).count == 12, "seed \(seed): \(seen)")
            // The loop repeats the same order: the order is fixed for the run.
            s.advance()
            #expect(s.current == 5)
            #expect(s.order == sequence(12, start: 5, shuffled: true, seed: UInt64(seed)).order)
        }
        // Different runs shuffle differently.
        #expect(sequence(12, start: 5, shuffled: true, seed: 1).order != sequence(12, start: 5, shuffled: true, seed: 2).order)
    }

    @Test func failedImagesAreSkippedBothWays() {
        var s = sequence(5, start: 1)
        s.markFailed(2)
        s.markFailed(3)
        #expect(s.next == 4)
        do { let moved = s.advance(); #expect(moved) }
        #expect(s.current == 4)
        #expect(s.previous == 1)
        s.markFailed(0)
        #expect(s.next == 1)   // round past 0
        #expect(s.hasPlayable)
        s.markFailed(1)
        #expect(s.next == nil)   // only the image on screen is left
        s.markFailed(4)
        #expect(!s.hasPlayable)
    }

    @Test func failuresAtTheEndOfAShowThatDoesNotLoop() {
        var s = sequence(3, start: 0, loops: false)
        s.markFailed(1)
        s.markFailed(2)
        #expect(s.next == nil)
        #expect(s.isOverAfterCurrent)
    }

    @Test func whenTheShowIsOver() {
        // A looping show goes on, even when its slide on screen is the only one left to play.
        #expect(!sequence(3).isOverAfterCurrent)
        #expect(!sequence(1, loops: true).isOverAfterCurrent)
        var lastPlayable = sequence(3, start: 1)
        lastPlayable.markFailed(0)
        lastPlayable.markFailed(2)
        #expect(lastPlayable.next == nil && !lastPlayable.isOverAfterCurrent)
        // Without looping it ends after the last slide, or a lone one.
        #expect(!sequence(3, start: 1, loops: false).isOverAfterCurrent)
        #expect(sequence(3, start: 2, loops: false).isOverAfterCurrent)
        #expect(sequence(1, loops: false).isOverAfterCurrent)
        // Nothing left that can play is over whatever the setting.
        var broken = sequence(2, loops: true)
        broken.markFailed(0)
        broken.markFailed(1)
        #expect(broken.isOverAfterCurrent)
    }

    // MARK: - Settings

    @Test func settingsDecodeDefaultsForMissingOrUnreadableKeys() throws {
        let empty = try JSONDecoder().decode(SlideshowSettings.self, from: Data("{}".utf8))
        #expect(empty == SlideshowSettings())
        #expect(empty.interval == 4 && empty.transition == .fixed(.crossFade) && empty.transitionDuration == 1)
        #expect(empty.order == .inOrder && empty.loop && empty.caption == .none)
        #expect(!empty.musicEnabled && empty.playlist.isEmpty && !empty.shuffleMusic)

        let partial = try JSONDecoder().decode(SlideshowSettings.self, from: Data("""
            {"interval": 120, "transition": "random", "caption": "sparkles", "loop": false,
             "transitionDuration": 0.01, "order": "shuffle", "volume": "loud"}
            """.utf8))
        #expect(partial.interval == 60)                 // clamped
        #expect(partial.transitionDuration == 0.3)      // clamped
        #expect(partial.transition == .random)
        #expect(partial.caption == .none)               // unknown value: the default
        #expect(partial.volume == 0.8)                  // wrong type: the default
        #expect(!partial.loop && partial.order == .shuffle)

        let unknownTransition = try JSONDecoder().decode(SlideshowSettings.self,
                                                         from: Data(#"{"transition": "spin"}"#.utf8))
        #expect(unknownTransition.transition == .fixed(.crossFade))
    }

    @Test func settingsRoundTripAndStoreInTheirOwnSuite() throws {
        var settings = SlideshowSettings()
        settings.interval = 9
        settings.transition = .fixed(.iris)
        settings.caption = .exif
        settings.musicEnabled = true
        settings.playlist = [.init(name: "Song.mp3", isFolder: false, bookmark: Data([1, 2, 3]))]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SlideshowSettings.self, from: data) == settings)
        #expect(String(decoding: data, as: UTF8.self).contains(#""transition":"iris""#))
        #expect(settings.playsMusic)

        let suite = "minivu-slideshow-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SlideshowSettingsStore(defaults: defaults)
        #expect(store.settings == SlideshowSettings())
        store.settings = settings
        store.settings.volume = 7   // clamped as it is stored
        #expect(store.settings.volume == 1)
        #expect(SlideshowSettingsStore(defaults: defaults).settings.interval == 9)
        #expect(SlideshowSettingsStore(defaults: defaults).settings.volume == 1)
    }

    // MARK: - Captions

    @Test func captionTexts() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        let photo = MetadataSummary(camera: "NIKON D750", lens: "50mm f/1.4", exposure: "1/400 s  f/5  ISO 200",
                                    dateTaken: taken, formatName: "JPEG")
        let drawing = MetadataSummary(formatName: "PNG")
        func text(_ style: SlideshowSettings.Caption, _ summary: MetadataSummary?) -> String? {
            SlideshowCaptionText.text(style: style, name: "a.jpg", modified: modified, summary: summary)
        }
        #expect(text(.none, photo) == nil)
        #expect(text(.name, nil) == "a.jpg")
        #expect(text(.nameAndDate, photo) == "a.jpg  ·  \(taken.formatted(date: .long, time: .shortened))")
        #expect(text(.nameAndDate, drawing) == "a.jpg  ·  \(modified.formatted(date: .long, time: .shortened))")
        #expect(text(.exif, photo) == "NIKON D750  ·  50mm f/1.4  ·  1/400 s  f/5  ISO 200")
        #expect(text(.exif, drawing) == "a.jpg")
        #expect(SlideshowCaptionText.needsMetadata(.exif) && SlideshowCaptionText.needsMetadata(.nameAndDate))
        #expect(!SlideshowCaptionText.needsMetadata(.name) && !SlideshowCaptionText.needsMetadata(.none))
    }
}

