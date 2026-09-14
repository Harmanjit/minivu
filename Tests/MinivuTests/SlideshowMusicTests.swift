import Testing
import Foundation
@testable import Minivu

/// Records what the music asks of its player, and never makes a sound.
@MainActor final class FakeSlideshowAudioPlayer: SlideshowAudioPlaying {
    enum Call: Equatable {
        case play(String, Float)
        case pause, resume, stop
        case volume(Float, TimeInterval)
    }

    var onFinish: (() -> Void)?
    var calls: [Call] = []
    /// File names that refuse to open.
    var unplayable: Set<String> = []
    /// Awaited while a file opens, so a test can act part way.
    var openGate: (() async -> Void)?
    private(set) var opened: String?
    private(set) var playing: String?

    func open(_ url: URL) async -> Bool {
        opened = nil
        await openGate?()
        guard !unplayable.contains(url.lastPathComponent) else { return false }
        opened = url.lastPathComponent
        return true
    }

    func play(volume: Float) -> Bool {
        guard let opened else { return false }
        calls.append(.play(opened, volume))
        playing = opened
        return true
    }

    func pause() { calls.append(.pause) }
    func resume() { calls.append(.resume) }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { calls.append(.volume(volume, fadeDuration)) }

    func stop() {
        calls.append(.stop)
        playing = nil
    }

    /// The song playing reaches its end.
    func finishTrack() {
        playing = nil
        onFinish?()
    }

    var played: [String] {
        calls.compactMap { if case .play(let name, _) = $0, !unplayable.contains(name) { name } else { nil } }
    }
}

@MainActor @Suite struct SlideshowMusicTests {
    static func tracks(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/Music").appendingPathComponent($0) }
    }

    /// Music whose playlist resolves to `names` at once, with the fade-out's
    /// stop run straight away and releases recorded.
    func music(_ names: [String], shuffle: Bool = false, volume: Double = 0.5,
               player: FakeSlideshowAudioPlayer, released: Box<[URL]>) async -> SlideshowMusic {
        let urls = Self.tracks(names)
        let scoped = [URL(fileURLWithPath: "/Music")]
        let music = SlideshowMusic(items: [], shuffle: shuffle, volume: volume, player: player,
                                   resolve: { _ in ResolvedPlaylist(tracks: urls, scopedURLs: scoped) },
                                   release: { released.value += $0 },
                                   schedule: { _, work in work() })
        await music.startTask?.value
        return music
    }

    /// A song ends, and the next has opened.
    func finishTrack(_ player: FakeSlideshowAudioPlayer, _ music: SlideshowMusic) async {
        player.finishTrack()
        await music.playTask?.value
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test func playsInOrderFadingInAndMovesOnWhenASongEnds() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let music = await music(["1.mp3", "2.m4a", "3.wav"], player: player, released: released)
        #expect(music.state == .playing)
        #expect(player.calls == [.play("1.mp3", 0), .volume(0.5, SlideshowMusic.fadeInDuration)])
        await finishTrack(player, music)
        #expect(player.calls.last == .play("2.m4a", 0.5))   // no fade between songs
        await finishTrack(player, music)
        await finishTrack(player, music)
        #expect(player.played == ["1.mp3", "2.m4a", "3.wav", "1.mp3"])   // round again
        #expect(released.value.isEmpty)
    }

    @Test func pausesWithTheShowAndFadesOutAtTheEnd() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let music = await music(["1.mp3"], player: player, released: released)
        music.pause()
        music.pause()   // once is enough
        music.resume()
        #expect(player.calls.suffix(2) == [.pause, .resume])
        music.setMuted(true)
        #expect(player.calls.last == .volume(0, SlideshowMusic.muteFadeDuration))
        music.setMuted(false)
        #expect(player.calls.last == .volume(0.5, SlideshowMusic.muteFadeDuration))

        music.finish()
        #expect(player.calls.suffix(2) == [.volume(0, SlideshowMusic.fadeOutDuration), .stop])
        #expect(SlideshowMusic.fadeOutDuration == 1.5)
        #expect(music.state == .finished)
        #expect(released.value == [URL(fileURLWithPath: "/Music")])
        // A song ending after the show did plays nothing more.
        player.finishTrack()
        #expect(player.played == ["1.mp3"])
        music.finish()
        #expect(released.value.count == 1)
    }

    @Test func pausedMusicStopsWithoutAFade() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let music = await music(["1.mp3"], player: player, released: released)
        music.pause()
        music.finish()
        #expect(player.calls.suffix(2) == [.pause, .stop])
        #expect(released.value.count == 1)
    }

    @Test func songsThatWontPlayAreSkipped() async {
        let player = FakeSlideshowAudioPlayer()
        player.unplayable = ["broken.mp3"]
        let released = Box<[URL]>([])
        let music = await music(["broken.mp3", "2.mp3", "3.mp3"], player: player, released: released)
        #expect(player.playing == "2.mp3")
        await finishTrack(player, music)
        await finishTrack(player, music)
        #expect(player.played == ["2.mp3", "3.mp3", "2.mp3"])
        #expect(music.playlist.tracks.map(\.lastPathComponent) == ["2.mp3", "3.mp3"])
    }

    @Test func nothingPlayableEndsTheMusicAndLetsTheFilesGo() async {
        let player = FakeSlideshowAudioPlayer()
        player.unplayable = ["a.mp3", "b.mp3"]
        let released = Box<[URL]>([])
        let music = await music(["a.mp3", "b.mp3"], player: player, released: released)
        #expect(music.state == .finished)
        #expect(released.value.count == 1)
    }

    @Test func aShowPausedBeforeTheMusicResolvedStartsItOnResume() async {
        let player = FakeSlideshowAudioPlayer()
        let urls = Self.tracks(["1.mp3"])
        let music = SlideshowMusic(items: [], shuffle: false, volume: 1, player: player,
                                   resolve: { _ in ResolvedPlaylist(tracks: urls, scopedURLs: []) },
                                   release: { _ in }, schedule: { _, work in work() })
        music.pause()
        await music.startTask?.value
        #expect(player.calls.isEmpty)
        music.resume()
        await music.playTask?.value
        #expect(player.calls == [.play("1.mp3", 0), .volume(1, SlideshowMusic.fadeInDuration)])
    }

    @Test func aShowEndedBeforeTheMusicResolvedReleasesIt() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let urls = Self.tracks(["1.mp3"])
        let music = SlideshowMusic(items: [], shuffle: false, volume: 1, player: player,
                                   resolve: { _ in ResolvedPlaylist(tracks: urls, scopedURLs: [URL(fileURLWithPath: "/M")]) },
                                   release: { released.value += $0 }, schedule: { _, work in work() })
        music.finish()
        await music.startTask?.value
        #expect(player.calls.isEmpty)
        #expect(released.value == [URL(fileURLWithPath: "/M")])
    }

    /// The slideshow window lets go of its music as soon as the show ends; if
    /// the bookmarks were still resolving, the files they opened are released
    /// all the same (security-scoped access must always be paired).
    @Test func musicLetGoOfWhileResolvingStillReleasesTheFiles() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let gate = DispatchSemaphore(value: 0)
        let urls = Self.tracks(["1.mp3"])
        var music: SlideshowMusic? = SlideshowMusic(
            items: [], shuffle: false, volume: 1, player: player,
            resolve: { _ in
                gate.wait()
                return ResolvedPlaylist(tracks: urls, scopedURLs: [URL(fileURLWithPath: "/M")])
            },
            release: { released.value += $0 }, schedule: { _, work in work() })
        let task = music?.startTask
        music?.finish()
        weak let gone = music
        music = nil
        #expect(gone == nil)
        gate.signal()
        await task?.value
        #expect(player.calls.isEmpty)
        #expect(released.value == [URL(fileURLWithPath: "/M")])
    }

    /// Settings' Volume and Play Music reach a show that is running; a
    /// muted show stays silent until unmuted, at the new volume.
    @Test func volumeAndPlayMusicApplyToARunningShow() async {
        let player = FakeSlideshowAudioPlayer()
        let released = Box<[URL]>([])
        let music = await music(["1.mp3"], player: player, released: released)
        music.setVolume(0.3)
        #expect(player.calls.last == .volume(0.3, SlideshowMusic.volumeFadeDuration))
        music.setVolume(0.3)
        music.setVolume(7)   // clamped
        #expect(player.calls.last == .volume(1, SlideshowMusic.volumeFadeDuration))
        let count = player.calls.count

        music.setMuted(true)
        music.setVolume(0.6)
        #expect(player.calls.count == count + 1, "muted: only the mute's own ramp")
        music.setMuted(false)
        #expect(player.calls.last == .volume(0.6, SlideshowMusic.muteFadeDuration))

        music.setEnabled(false)
        #expect(player.calls.last == .volume(0, SlideshowMusic.muteFadeDuration))
        music.setEnabled(true)
        #expect(player.calls.last == .volume(0.6, SlideshowMusic.muteFadeDuration))
        music.finish()
    }

    /// Songs open off the main thread. A show paused while one opens starts
    /// it on resume; one muted meanwhile starts it silent; one that ends
    /// meanwhile never plays it and lets the files go.
    @Test func whatHappensWhileASongOpens() async {
        final class Gate {
            var continuation: CheckedContinuation<Void, Never>?
            func open() {
                continuation?.resume()
                continuation = nil
            }
        }
        let urls = Self.tracks(["1.mp3", "2.mp3"])
        func makeMusic(_ player: FakeSlideshowAudioPlayer, _ released: Box<[URL]>) -> SlideshowMusic {
            SlideshowMusic(items: [], shuffle: false, volume: 0.5, player: player,
                           resolve: { _ in ResolvedPlaylist(tracks: urls, scopedURLs: [URL(fileURLWithPath: "/M")]) },
                           release: { released.value += $0 }, schedule: { _, work in work() })
        }
        func waitForOpening(_ music: SlideshowMusic, _ gate: Gate) async {
            // Polled with a sleep, not Task.yield: yielding would spin on the
            // main actor, taking turns from every other test waiting there.
            while gate.continuation == nil { try? await Task.sleep(for: .milliseconds(2)) }
            #expect(music.track == .opening)
        }

        // Paused, then resumed.
        var gate = Gate()
        var player = FakeSlideshowAudioPlayer()
        player.openGate = { [gate] in await withCheckedContinuation { gate.continuation = $0 } }
        var released = Box<[URL]>([])
        var music = makeMusic(player, released)
        await waitForOpening(music, gate)
        music.pause()
        gate.open()
        await music.startTask?.value
        #expect(player.calls.isEmpty && music.track == .ready)
        music.resume()
        #expect(player.calls == [.play("1.mp3", 0), .volume(0.5, SlideshowMusic.fadeInDuration)])
        music.finish()

        // Muted.
        gate = Gate()
        player = FakeSlideshowAudioPlayer()
        player.openGate = { [gate] in await withCheckedContinuation { gate.continuation = $0 } }
        music = makeMusic(player, released)
        await waitForOpening(music, gate)
        music.setMuted(true)
        gate.open()
        await music.startTask?.value
        #expect(player.calls == [.play("1.mp3", 0)], "no fade in to silence")
        music.finish()

        // Ended.
        gate = Gate()
        player = FakeSlideshowAudioPlayer()
        player.openGate = { [gate] in await withCheckedContinuation { gate.continuation = $0 } }
        released = Box<[URL]>([])
        music = makeMusic(player, released)
        await waitForOpening(music, gate)
        music.finish()
        #expect(music.state == .finished && released.value.count == 1, "nothing sounding: stopped at once")
        gate.open()
        await music.startTask?.value
        #expect(!player.calls.contains { if case .play = $0 { true } else { false } })
    }

    @Test func shuffleKeepsEverySongOnce() {
        let urls = Self.tracks((1...10).map { "\($0).mp3" })
        var generator = SlideshowTestGenerator(state: 3)
        var playlist = SlideshowPlaylist(tracks: urls, shuffled: true, generator: &generator)
        #expect(Set(playlist.tracks) == Set(urls))
        #expect(playlist.tracks != urls)
        var heard: [URL] = []
        for _ in 0..<10 {
            heard.append(playlist.current!)
            playlist.advance()
        }
        #expect(Set(heard).count == 10)
        #expect(playlist.current == heard.first)
    }

    /// Real bookmarks of real files: songs and a folder of them resolve, in
    /// name order, leaving out what isn't audio and what has gone.
    @Test func bookmarksResolveToSongs() throws {
        let folder = try ScratchFolder()
        let album = try folder.folder("Album")
        try folder.file("b.m4a", in: album)
        try folder.file("a.mp3", in: album)
        try folder.file("cover.jpg", in: album)
        let single = try folder.file("single.aiff")
        let gone = try folder.file("gone.wav")
        let items = try [album, single, gone].map { try #require(SlideshowPlaylistResolver.item(for: $0)) }
        #expect(items.map(\.isFolder) == [true, false, false])
        #expect(items.map(\.name) == ["Album", "single.aiff", "gone.wav"])
        try FileManager.default.removeItem(at: gone)

        let resolved = SlideshowPlaylistResolver.resolve(items)
        defer { SlideshowPlaylistResolver.release(resolved.scopedURLs) }
        #expect(resolved.tracks.map(\.lastPathComponent) == ["a.mp3", "b.m4a", "single.aiff"])
        #expect(SlideshowPlaylistResolver.isAudio(URL(fileURLWithPath: "/x/song.MP3")))
        #expect(!SlideshowPlaylistResolver.isAudio(URL(fileURLWithPath: "/x/notes.txt")))
        #expect(resolved.refreshedBookmarks.isEmpty)
    }

    /// A song renamed after it was chosen still plays, and its bookmark is
    /// refreshed in Settings (a scratch suite) so it keeps resolving.
    @Test func staleBookmarksAreRefreshedInSettings() async throws {
        let folder = try ScratchFolder()
        let song = try folder.file("before.mp3")
        let item = try #require(SlideshowPlaylistResolver.item(for: song))
        let renamed = song.deletingLastPathComponent().appendingPathComponent("after.mp3")
        try FileManager.default.moveItem(at: song, to: renamed)

        let resolved = SlideshowPlaylistResolver.resolve([item])
        SlideshowPlaylistResolver.release(resolved.scopedURLs)
        #expect(resolved.tracks.map(\.lastPathComponent) == ["after.mp3"])
        let fresh = try #require(resolved.refreshedBookmarks[item.id])

        let scratchDefaults = ScratchDefaults("minivu-slideshow-music-tests")
        defer { scratchDefaults.remove() }
        let defaults = scratchDefaults.defaults
        let store = SlideshowSettingsStore(defaults: defaults)
        let other = SlideshowSettings.PlaylistItem(name: "Other", isFolder: true, bookmark: Data([9]))
        store.settings.playlist = [item, other]
        let player = FakeSlideshowAudioPlayer()
        let music = SlideshowMusic(items: [item], shuffle: false, volume: 1, player: player,
                                   resolve: { _ in resolved }, release: { _ in },
                                   refreshBookmarks: { store.refreshPlaylistBookmarks($0) },
                                   schedule: { _, work in work() })
        await music.startTask?.value
        #expect(store.settings.playlist.map(\.bookmark) == [fresh, Data([9])])
        #expect(SlideshowSettingsStore(defaults: defaults).settings.playlist.first?.bookmark == fresh)
        music.finish()
    }
}
