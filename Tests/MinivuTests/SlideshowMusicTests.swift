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
    /// File names that refuse to play.
    var unplayable: Set<String> = []
    private(set) var playing: String?

    func play(_ url: URL, volume: Float) -> Bool {
        calls.append(.play(url.lastPathComponent, volume))
        guard !unplayable.contains(url.lastPathComponent) else { return false }
        playing = url.lastPathComponent
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
    func finishTrack() { onFinish?() }

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
        player.finishTrack()
        #expect(player.calls.last == .play("2.m4a", 0.5))   // no fade between songs
        player.finishTrack()
        player.finishTrack()
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
        player.finishTrack()
        player.finishTrack()
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
    }
}
