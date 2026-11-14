import CoreGraphics

extension Int {
    /// `value` rounded toward zero, as `Int(_:)` would, but clamped to
    /// `Int`'s range rather than trapping: infinity becomes `Int.max` (or
    /// `Int.min`) and NaN becomes 0.
    ///
    /// For sizes that come from a file. A header or an SVG can declare any
    /// number, and `Int(_:)` stops the app on one past `Int.max`, so a
    /// conversion that never sees anything but our own arithmetic can keep
    /// `Int(_:)`, while one that may see what a file said goes through here.
    public init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Int.max) {
            // Double(Int.max) rounds up to 2^63, one past Int.max, so the
            // comparison has to include it.
            self = .max
        } else if value <= Double(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }

    public init(saturating value: CGFloat) {
        self.init(saturating: Double(value))
    }
}
