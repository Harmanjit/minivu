import CoreGraphics
import Foundation

/// Sizes and file names for what the Tools write into the Pictures folder:
/// montages and desktop picture copies (minivu Wallpapers), and captures
/// (minivu Captures).
public enum MontageOutput {
    /// Folder inside Pictures for montages and desktop picture copies.
    public static let wallpapersFolderName = "minivu Wallpapers"

    /// A display's size in pixels: its frame in points times its backing
    /// scale, rounded (a scaled "looks like" mode reports fractional points).
    public static func pixelSize(points: CGSize, backingScale: CGFloat) -> CGSize {
        CGSize(width: max(1, (points.width * backingScale).rounded()),
               height: max(1, (points.height * backingScale).rounded()))
    }

    /// "Montage 2026-09-14 at 10.30.05.jpg"; with several displays at once,
    /// "Montage 2026-09-14 at 10.30.05 (2).jpg" for the second, so each
    /// display gets a file of its own. The timestamp sorts by name and uses
    /// dots, as the system's own screenshots do (a colon is a slash in Finder).
    public static func montageFileName(date: Date, display: Int? = nil, timeZone: TimeZone = .current) -> String {
        let suffix = display.map { " (\($0))" } ?? ""
        return "Montage \(timestamp(date, timeZone: timeZone))\(suffix).jpg"
    }

    /// "2026-09-14 at 10.30.05", in a fixed format whatever the user's
    /// locale, so names sort and can be recognised again.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return String(format: "%04d", c.year ?? 0) + "-\(two(c.month))-\(two(c.day)) at \(two(c.hour)).\(two(c.minute)).\(two(c.second))"
    }
}
