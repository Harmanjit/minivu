import AVFoundation

/// Plays one audio file at a time for the slideshow's music.
///
/// `SlideshowMusic` decides what plays and when, through this protocol, so
/// its tests run against a fake that records calls and never makes a sound.
/// This file is the only one that touches AVFoundation.
protocol SlideshowAudioPlaying: AnyObject {
    /// Called when the file playing reaches its end (or can't go on).
    var onFinish: (() -> Void)? { get set }
    /// Starts `url` from the beginning at `volume` (0...1), replacing
    /// whatever was playing. False when the file can't be played.
    func play(_ url: URL, volume: Float) -> Bool
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

    func play(_ url: URL, volume: Float) -> Bool {
        stop()
        // Opening reads the file's header only; the audio decodes on
        // AVFoundation's own thread as it plays.
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        player.volume = volume
        guard player.play() else { return false }
        self.player = player
        return true
    }

    func pause() { player?.pause() }

    func resume() { player?.play() }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        player?.setVolume(volume, fadeDuration: fadeDuration)
    }

    func stop() {
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
