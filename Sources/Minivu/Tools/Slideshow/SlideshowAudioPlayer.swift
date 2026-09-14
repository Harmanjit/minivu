import AVFoundation
import MinivuCore

/// Plays one audio file at a time for the slideshow's music.
///
/// `SlideshowMusic` decides what plays and when, through this protocol, so
/// its tests run against a fake that records calls and never makes a sound.
/// This file is the only one that touches AVFoundation.
protocol SlideshowAudioPlaying: AnyObject {
    /// Called when the file playing reaches its end (or can't go on).
    var onFinish: (() -> Void)? { get set }
    /// Opens `url` off the main thread, ready to play from the beginning,
    /// replacing whatever was open. False when the file can't be played, or
    /// when `stop()` was called before it finished opening.
    func open(_ url: URL) async -> Bool
    /// Starts the file just opened at `volume` (0...1). False when it can't.
    func play(volume: Float) -> Bool
    func pause()
    func resume()
    /// Ramps the volume to `volume` over `fadeDuration` seconds (0: at once).
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
    func stop()
}

/// `SlideshowAudioPlaying` on `AVAudioPlayer`: plays MP3, AAC/M4A, WAV and
/// AIFF, fades with the player's own volume ramp, and needs no audio engine
/// or session set up.
final class SlideshowAudioPlayer: NSObject, SlideshowAudioPlaying, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    private var player: AVAudioPlayer?
    /// Bumped by `stop()`, so a file still opening when the music stops (or
    /// moves on) is dropped rather than left open.
    private var generation = 0

    /// An opened player handed from the opening thread to the main actor,
    /// which is the only place it is used from then on.
    private nonisolated struct Opened: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    func open(_ url: URL) async -> Bool {
        stop()
        let generation = self.generation
        // Opening reads and parses the file (for an MP3, enough of it to
        // find its frames), which can take a moment on a slow or sleeping
        // disk: never on the main thread. The audio then decodes on
        // AVFoundation's own thread as it plays.
        let opened = await BlockingWork.run(qos: .userInitiated) { () -> Opened? in
            guard let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() else { return nil }
            return Opened(player: player)
        }
        guard generation == self.generation, let player = opened?.player else { return false }
        player.delegate = self
        self.player = player
        return true
    }

    func play(volume: Float) -> Bool {
        guard let player else { return false }
        player.volume = volume
        guard player.play() else {
            stop()
            return false
        }
        return true
    }

    func pause() { player?.pause() }

    func resume() { player?.play() }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        player?.setVolume(volume, fadeDuration: fadeDuration)
    }

    func stop() {
        generation += 1
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    // The delegate may be called off the main thread; the player it names is
    // compared by identity on the main actor, so a file that finished just
    // as another started can't skip the new one.

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finished(ObjectIdentifier(player))
    }

    nonisolated private func finished(_ id: ObjectIdentifier) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let player = self.player, ObjectIdentifier(player) == id else { return }
                self.player = nil
                self.onFinish?()
            }
        }
    }
}
