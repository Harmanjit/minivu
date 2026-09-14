import Foundation
import UniformTypeIdentifiers
import MinivuCore

/// The songs a playlist resolves to, and the security-scoped URLs being
/// accessed to play them (released when the music stops).
nonisolated struct ResolvedPlaylist: Sendable, Equatable {
    var tracks: [URL]
    var scopedURLs: [URL]
    /// New bookmark data for playlist items whose bookmarks resolved stale
    /// (the file or folder was moved or renamed), by item id. Saved back to
    /// Settings, so the next launch still finds them.
    var refreshedBookmarks: [UUID: Data] = [:]
}

/// Turns the bookmarks in Settings into files to play.
nonisolated enum SlideshowPlaylistResolver {
    /// MP3, AAC/M4A, WAV and AIFF: what `AVAudioPlayer` plays everywhere.
    static let audioTypes: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff, UTType("public.aac-audio")].compactMap { $0 }

    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return audioTypes.contains { type.conforms(to: $0) }
    }

    /// Resolves each bookmark and starts accessing what it names; a folder
    /// contributes the songs directly inside it, by name. Items that have
    /// gone are left out. Reads the disk: call it off the main thread.
    static func resolve(_ items: [SlideshowSettings.PlaylistItem]) -> ResolvedPlaylist {
        var result = ResolvedPlaylist(tracks: [], scopedURLs: [])
        for item in items {
            var stale = false
            let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
            // A bookmark made outside the sandbox (tests, a --dev build) has
            // no security scope; it still resolves without one.
            guard let url = (try? URL(resolvingBookmarkData: item.bookmark, options: quiet.union(.withSecurityScope),
                                      relativeTo: nil, bookmarkDataIsStale: &stale))
                    ?? (try? URL(resolvingBookmarkData: item.bookmark, options: quiet, relativeTo: nil,
                                 bookmarkDataIsStale: &stale))
            else { continue }
            if url.startAccessingSecurityScopedResource() { result.scopedURLs.append(url) }
            // Made while access is held, as a bookmark must be.
            if stale, let data = bookmarkData(for: url) { result.refreshedBookmarks[item.id] = data }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                result.tracks += files.filter(isAudio)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if FileManager.default.fileExists(atPath: url.path) {
                result.tracks.append(url)
            }
        }
        return result
    }

    static func release(_ urls: [URL]) {
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }

    /// A bookmark for a file or folder the user just chose in an open panel
    /// (whose URL carries the permission); plain when the app isn't sandboxed.
    static func item(for url: URL) -> SlideshowSettings.PlaylistItem? {
        guard let data = bookmarkData(for: url) else { return nil }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return SlideshowSettings.PlaylistItem(name: FileManager.default.displayName(atPath: url.path),
                                              isFolder: isFolder, bookmark: data)
    }

    private static func bookmarkData(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }
}

/// The order songs play in: as listed, or shuffled once; round and round.
nonisolated struct SlideshowPlaylist: Equatable {
    private(set) var tracks: [URL]
    private(set) var position = 0

    init() { tracks = [] }

    init(tracks: [URL], shuffled: Bool, generator: inout some RandomNumberGenerator) {
        self.tracks = shuffled ? tracks.shuffled(using: &generator) : tracks
    }

    var current: URL? { tracks.indices.contains(position) ? tracks[position] : nil }

    /// The next song, back to the first after the last.
    mutating func advance() {
        guard !tracks.isEmpty else { return }
        position = (position + 1) % tracks.count
    }

    /// Drops the current song (it wouldn't play); the next takes its place.
    mutating func removeCurrent() {
        guard tracks.indices.contains(position) else { return }
        tracks.remove(at: position)
        if position >= tracks.count { position = 0 }
    }
}

/// The slideshow's music: the playlist from Settings, fading in when the
/// show starts, pausing with it, and fading out over 1.5 s when it ends.
///
/// Songs are opened off the main thread (`SlideshowAudioPlaying.open`), so
/// anything can happen while one opens: the show pauses (the song starts on
/// resume), ends (it is dropped), or is muted or turned down (it starts at
/// the volume of that moment).
final class SlideshowMusic {
    static let fadeInDuration: TimeInterval = 1
    static let fadeOutDuration: TimeInterval = 1.5
    static let muteFadeDuration: TimeInterval = 0.25
    /// A volume change from Settings during the show: quick, but without a click.
    static let volumeFadeDuration: TimeInterval = 0.1

    enum State: Equatable {
        /// Resolving the bookmarks off the main thread.
        case starting
        case playing
        /// Fading out; stops and releases the files when done.
        case finishing
        case finished
    }

    /// Where the current song is.
    enum Track: Equatable {
        /// Nothing open: before the first song, or between songs.
        case idle
        case opening
        /// Open, waiting for the show to resume.
        case ready
        /// Started (and possibly paused with the show).
        case playing
    }

    private(set) var state: State = .starting
    private(set) var track: Track = .idle
    private(set) var isPaused = false
    private(set) var isMuted = false
    /// False when Play Music is turned off in Settings during the show: the
    /// music goes quiet, as muted, until it is turned on again.
    private(set) var isEnabled = true
    private(set) var playlist = SlideshowPlaylist()
    /// The bookmark resolution and the first song's opening, for tests to await.
    private(set) var startTask: Task<Void, Never>?
    /// The song opening now, for tests to await.
    private(set) var playTask: Task<Void, Never>?

    private let player: SlideshowAudioPlaying
    private var volume: Float
    private let shuffle: Bool
    private let release: ([URL]) -> Void
    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private var scopedURLs: [URL] = []
    /// The first song hasn't started: it waits for the show to resume.
    private var waitingToStart = false
    /// Counts song openings, so one overtaken by another (or by the end of
    /// the show) is dropped.
    private var playGeneration = 0

    /// - Parameters:
    ///   - resolve: turns the playlist into files; runs off the main thread.
    ///   - release: stops accessing the security-scoped files afterwards.
    ///   - refreshBookmarks: saves bookmarks that resolved stale, by item id.
    ///   - schedule: runs the stop at the end of the fade-out; tests run it at once.
    init(items: [SlideshowSettings.PlaylistItem], shuffle: Bool, volume: Double, player: SlideshowAudioPlaying,
         resolve: @escaping @Sendable ([SlideshowSettings.PlaylistItem]) -> ResolvedPlaylist = SlideshowPlaylistResolver.resolve,
         release: @escaping ([URL]) -> Void = SlideshowPlaylistResolver.release,
         refreshBookmarks: @escaping ([UUID: Data]) -> Void = { _ in },
         schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         }) {
        self.player = player
        self.volume = Self.clamped(volume)
        self.shuffle = shuffle
        self.release = release
        self.schedule = schedule
        player.onFinish = { [weak self] in self?.trackFinished() }
        startTask = Task { [weak self, release, refreshBookmarks] in
            let resolved = await BlockingWork.run(qos: .userInitiated) { resolve(items) }
            if !resolved.refreshedBookmarks.isEmpty { refreshBookmarks(resolved.refreshedBookmarks) }
            let opening: Task<Void, Never>?
            do {
                guard let self else {
                    // The slideshow ended and let go of its music while the
                    // bookmarks resolved: nothing will play, but the files
                    // started being accessed and must be released.
                    release(resolved.scopedURLs)
                    return
                }
                self.begin(resolved)
                opening = self.playTask
            }
            await opening?.value
        }
    }

    private static func clamped(_ volume: Double) -> Float { Float(min(max(volume, 0), 1)) }

    private var targetVolume: Float { isMuted || !isEnabled ? 0 : volume }

    /// The files are known: play the first that opens, fading in.
    func begin(_ resolved: ResolvedPlaylist) {
        guard state == .starting else {
            // The show ended while the bookmarks resolved.
            release(resolved.scopedURLs)
            return
        }
        scopedURLs = resolved.scopedURLs
        var generator = SystemRandomNumberGenerator()
        playlist = SlideshowPlaylist(tracks: resolved.tracks, shuffled: shuffle, generator: &generator)
        state = .playing
        if isPaused {
            waitingToStart = true
        } else {
            playCurrent(fadeIn: true)
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if state == .playing, track == .playing { player.pause() }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard state == .playing else { return }
        switch track {
        case .playing:
            player.resume()
        case .ready:
            start(fadeIn: true)
        case .idle where waitingToStart:
            waitingToStart = false
            playCurrent(fadeIn: true)
        case .idle, .opening:
            break   // an opening song starts when it is open
        }
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        applyVolume(fadeDuration: Self.muteFadeDuration)
    }

    /// Settings' Volume, changed while the show runs.
    func setVolume(_ newVolume: Double) {
        let clamped = Self.clamped(newVolume)
        guard clamped != volume else { return }
        volume = clamped
        if !isMuted, isEnabled { applyVolume(fadeDuration: Self.volumeFadeDuration) }
    }

    /// Settings' Play Music, changed while the show runs: off silences the
    /// music (it keeps its place), on brings it back.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !isMuted { applyVolume(fadeDuration: Self.muteFadeDuration) }
    }

    /// Ramps a started song to the volume wanted now. A song not started yet
    /// picks the volume up when it starts.
    private func applyVolume(fadeDuration: TimeInterval) {
        if state == .playing, track == .playing { player.setVolume(targetVolume, fadeDuration: fadeDuration) }
    }

    /// The show is over: fade out, then stop and let the files go. Music that
    /// isn't sounding (paused, or a song still opening) stops at once.
    func finish() {
        switch state {
        case .starting:
            state = .finished   // `begin` releases what it resolved
        case .playing:
            if isPaused || track != .playing {
                stopAndRelease()
            } else {
                state = .finishing
                player.setVolume(0, fadeDuration: Self.fadeOutDuration)
                schedule(Self.fadeOutDuration) { [self] in stopAndRelease() }
            }
        case .finishing, .finished:
            break
        }
    }

    private func stopAndRelease() {
        guard state != .finished else { return }
        state = .finished
        track = .idle
        playGeneration += 1
        player.onFinish = nil
        player.stop()
        release(scopedURLs)
        scopedURLs = []
    }

    /// Opens the playlist's current song off the main thread, dropping songs
    /// that won't open; with none left the music is over. The song starts
    /// once open, unless the show was paused meanwhile.
    private func playCurrent(fadeIn: Bool) {
        playGeneration += 1
        let generation = playGeneration
        track = .opening
        playTask = Task { [weak self] in
            while let self, let url = self.playlist.current {
                let opened = await self.player.open(url)
                // Overtaken while opening: the show ended, or another song began.
                guard generation == self.playGeneration, self.state == .playing else { return }
                if opened {
                    if self.isPaused {
                        self.track = .ready
                        return
                    }
                    if self.start(fadeIn: fadeIn, retrying: false) { return }
                }
                self.playlist.removeCurrent()
            }
            self?.stopAndRelease()
        }
    }

    /// Starts the song that is open. One that won't start is dropped and
    /// the next opened (when `retrying`; the opening loop moves on itself).
    @discardableResult
    private func start(fadeIn: Bool, retrying: Bool = true) -> Bool {
        if player.play(volume: fadeIn ? 0 : targetVolume) {
            track = .playing
            if fadeIn, targetVolume > 0 { player.setVolume(targetVolume, fadeDuration: Self.fadeInDuration) }
            return true
        }
        track = .idle
        if retrying {
            playlist.removeCurrent()
            playCurrent(fadeIn: fadeIn)
        }
        return false
    }

    private func trackFinished() {
        guard state == .playing else { return }
        track = .idle
        playlist.advance()
        playCurrent(fadeIn: false)
    }
}
