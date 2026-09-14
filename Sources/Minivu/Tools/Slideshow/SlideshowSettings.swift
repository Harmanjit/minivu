import Foundation
import Combine
import MinivuRender

/// Settings > Slideshow.
///
/// One `Codable` value rather than a key per setting, so a slideshow reads a
/// consistent set at once. Decoding fills any missing or unreadable field
/// with its default, and clamps numbers into range, so settings saved by an
/// older version (or edited with `defaults write`) always load.
nonisolated struct SlideshowSettings: Codable, Equatable, Sendable {
    /// A particular transition, or a different one for every slide.
    enum TransitionChoice: Hashable, Sendable, Codable {
        case random
        case fixed(SlideshowTransition)

        /// Stored as "random" or the transition's name.
        var rawValue: String {
            switch self {
            case .random: "random"
            case .fixed(let transition): transition.rawValue
            }
        }

        init(rawValue: String) {
            self = rawValue == "random" ? .random : .fixed(SlideshowTransition(rawValue: rawValue) ?? .crossFade)
        }

        init(from decoder: Decoder) throws {
            self.init(rawValue: try String(from: decoder))
        }

        func encode(to encoder: Encoder) throws {
            try rawValue.encode(to: encoder)
        }
    }

    enum Order: String, Codable, CaseIterable, Identifiable, Sendable {
        case inOrder, shuffle
        var id: String { rawValue }
        var title: String { self == .inOrder ? "In order" : "Shuffled" }
    }

    enum Caption: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, name, nameAndDate, exif
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .name: "File name"
            case .nameAndDate: "File name and date"
            case .exif: "Camera and exposure"
            }
        }
    }

    /// A song or a folder of songs the user chose, kept as a security-scoped
    /// bookmark: under the sandbox a remembered path couldn't be opened next
    /// time. The name is kept too, so Settings can list the playlist without
    /// resolving every bookmark.
    struct PlaylistItem: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var isFolder: Bool
        var bookmark: Data
    }

    static let intervalRange: ClosedRange<Double> = 1...60
    static let transitionDurationRange: ClosedRange<Double> = 0.3...3

    /// Seconds each slide stays up once its transition has finished.
    var interval: Double = 4
    var transition: TransitionChoice = .fixed(.crossFade)
    /// Seconds a transition takes (the arrow keys use a quicker one).
    var transitionDuration: Double = 1
    var order: Order = .inOrder
    /// Start again after the last slide; otherwise the show ends there.
    var loop = true
    var caption: Caption = .none
    var musicEnabled = false
    var playlist: [PlaylistItem] = []
    var shuffleMusic = false
    /// 0...1.
    var volume: Double = 0.8

    init() {}

    private enum CodingKeys: String, CodingKey {
        case interval, transition, transitionDuration, order, loop, caption, musicEnabled, playlist, shuffleMusic, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SlideshowSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` per field: one unreadable value (a transition from a
            // later version) mustn't lose the rest.
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        interval = value(.interval, defaults.interval)
        transition = value(.transition, defaults.transition)
        transitionDuration = value(.transitionDuration, defaults.transitionDuration)
        order = value(.order, defaults.order)
        loop = value(.loop, defaults.loop)
        caption = value(.caption, defaults.caption)
        musicEnabled = value(.musicEnabled, defaults.musicEnabled)
        playlist = value(.playlist, defaults.playlist)
        shuffleMusic = value(.shuffleMusic, defaults.shuffleMusic)
        volume = value(.volume, defaults.volume)
        self = clamped()
    }

    /// Numbers pulled into their ranges (a NaN becomes the default).
    func clamped() -> SlideshowSettings {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var copy = self
        copy.interval = clamp(interval, Self.intervalRange, 4)
        copy.transitionDuration = clamp(transitionDuration, Self.transitionDurationRange, 1)
        copy.volume = clamp(volume, 0...1, 0.8)
        return copy
    }

    /// Whether there is music to play.
    var playsMusic: Bool { musicEnabled && !playlist.isEmpty }
}

/// Where slideshow settings live: one key in a defaults store of their own
/// choosing, so tests pass a scratch suite and never touch the user's.
final class SlideshowSettingsStore: ObservableObject {
    static let shared = SlideshowSettingsStore(defaults: .standard)
    nonisolated static let key = "slideshowSettings"

    private let defaults: UserDefaults

    @Published var settings: SlideshowSettings {
        didSet {
            // A slider past its end, or a value set in code, is stored in range.
            let clamped = settings.clamped()
            if clamped != settings { settings = clamped }
            if let data = try? JSONEncoder().encode(clamped) { defaults.set(data, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SlideshowSettings.self, from: $0) } ?? SlideshowSettings()
    }
}
