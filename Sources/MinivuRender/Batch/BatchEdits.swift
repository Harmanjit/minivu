import Foundation
import CoreGraphics

/// Which steps of an edit can be carried to other photos as a batch preset
/// (G6), and which can't.
///
/// A document's operations are plain values, so a preset is just a list of
/// them. But not every value means the same thing on another photo. A step
/// travels when its parameters are amounts (tone, colour, curves, levels,
/// effects), lengths in full-resolution pixels that suit any photo (sharpen
/// and blur radii, noise reduction), fractions of the photo (the vignette,
/// the watermark, frames and shadows) or normalised positions (crop,
/// perspective, the lens). It stays behind when it was made for this photo's
/// content or size: brush strokes, drawn objects and red-eye spots sit on
/// things that are elsewhere in another photo, the subject mask was found
/// in this photo, and a resize or a canvas size is a number of pixels that
/// would squash every other photo into the same shape.
///
/// Steps left out are listed with the reason, never dropped silently, so the
/// "Save Edits as Preset" sheet can say what the preset will and won't do.
public enum BatchEdits {
    /// A step that won't travel, and why, for the sheet.
    public struct LeftOut: Hashable, Sendable {
        public var title: String
        public var reason: String

        public init(title: String, reason: String) {
            self.title = title
            self.reason = reason
        }
    }

    /// What a list of operations becomes as a preset.
    public struct Portable: Hashable, Sendable {
        /// The steps the preset applies, in their order.
        public var operations: [EditOperation]
        /// The steps that stay behind.
        public var leftOut: [LeftOut]

        /// Nothing to save: every step stayed behind, or there were none.
        public var isEmpty: Bool { operations.isEmpty }
    }

    /// `operations` sorted into those a preset carries and those it leaves
    /// out. Auto Enhance is carried with its measured values cleared: a batch
    /// measures each photo again (`BatchConverter`), since the curve and
    /// balance suggested for one photo suit no other. Steps that change
    /// nothing are dropped without a word, as the document never records
    /// them either.
    ///
    /// A crop or perspective is a fraction of the picture as it is at that
    /// point in the list. After a Canvas Size that stays behind, that picture
    /// is no longer the one the fractions were measured on (a crop back to
    /// the photo inside a border would cut into the bare photo), so such a
    /// step stays behind too, with the reason. A resize left out doesn't
    /// matter: scaling each side keeps every fraction where it was.
    public static func portable(_ operations: [EditOperation]) -> Portable {
        var result = Portable(operations: [], leftOut: [])
        var frameLeftOut = false
        for operation in operations where !operation.isIdentity || isAutoEnhance(operation) {
            if let reason = reasonLeftOut(operation) {
                result.leftOut.append(LeftOut(title: operation.title, reason: reason))
                if case .canvasSize = operation { frameLeftOut = true }
            } else if frameLeftOut && isPlacedOnTheFrame(operation) {
                result.leftOut.append(LeftOut(title: operation.title, reason: Self.afterCanvasSize))
            } else if isAutoEnhance(operation) {
                result.operations.append(.autoEnhance(AutoEnhance()))
            } else {
                result.operations.append(operation)
            }
        }
        return result
    }

    /// Why `operation` can't go into a preset, or nil when it can.
    public static func reasonLeftOut(_ operation: EditOperation) -> String? {
        switch operation {
        case .resize:
            localized("It is a size in pixels for this photo. Use Batch Convert’s Resize, which works from each photo’s own size.")
        case .canvasSize:
            localized("It is a size in pixels, which would give every photo the same canvas.")
        case .annotations:
            localized("Text and shapes are placed on this photo’s content.")
        case .retouch:
            localized("Brush strokes are painted on this photo’s content.")
        case .redEye:
            localized("The spots are placed on the eyes in this photo.")
        case .removeBackground:
            localized("The subject’s outline was found in this photo and fits no other.")
        default:
            nil
        }
    }

    /// What a carried step does differently on other photos, for the sheet
    /// and the batch's list of edits; nil when it does the same everywhere.
    public static func note(for operation: EditOperation) -> String? {
        switch operation {
        case .autoEnhance: localized("Measured again on each photo.")
        case .crop: localized("The same part of each photo, as a fraction of its size.")
        case .perspective: localized("The same corners on each photo, as fractions of its size.")
        case .rawDevelop: localized("RAW files only; other photos ignore it.")
        default: nil
        }
    }

    /// Why a crop or perspective after a Canvas Size left out stays behind.
    public static var afterCanvasSize: String {
        localized("It was placed on the canvas Canvas Size made, which stays behind, so on another photo it would land elsewhere.")
    }

    /// Steps measured as fractions of the picture they are given.
    static func isPlacedOnTheFrame(_ operation: EditOperation) -> Bool {
        switch operation {
        case .crop, .perspective: true
        default: false
        }
    }

    static func isAutoEnhance(_ operation: EditOperation) -> Bool {
        if case .autoEnhance = operation { return true }
        return false
    }
}
