import Testing
import Foundation
import CoreGraphics
@testable import MinivuRender
@testable import MinivuCore

/// The operation list, undo and redo, and what operations say about
/// themselves.
@MainActor @Suite struct EditDocumentTests {
    func document() -> EditDocument {
        let url = URL(fileURLWithPath: "/tmp/minivu-edit-document-test.jpg")
        let entry = FolderEntry(url: url, name: url.lastPathComponent, isDirectory: false, kind: .raster, fileSize: 0,
                                modified: .distantPast, created: .distantPast)
        return EditDocument(entry: entry)
    }

    static let brighter = EditOperation.lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0)

    @Test func applyUndoRedo() {
        let doc = document()
        var changes = 0
        doc.onChange = { changes += 1 }
        #expect(!doc.canUndo && !doc.canRedo && doc.undoTitle == nil)

        doc.apply(.rotate90(turns: 1))
        doc.apply(.crop(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(doc.operations.count == 2 && changes == 2)
        #expect(doc.undoTitle == "Crop" && doc.redoTitle == nil)

        doc.undo()
        #expect(doc.operations == [.rotate90(turns: 1)])
        #expect(doc.undoTitle == "Rotate Right" && doc.redoTitle == "Crop")
        doc.redo()
        #expect(doc.operations.count == 2 && !doc.canRedo)

        // A new operation after an undo drops what was undone.
        doc.undo()
        doc.apply(.flip(horizontal: true))
        #expect(doc.operations == [.rotate90(turns: 1), .flip(horizontal: true)])
        #expect(!doc.canRedo)

        doc.undo(); doc.undo()
        #expect(doc.operations.isEmpty && !doc.canUndo)
        doc.undo()   // no-op
        #expect(changes == 8)
    }

    @Test func identityOperationsAreIgnoredButClearThePreview() {
        let doc = document()
        var changes = 0
        doc.onChange = { changes += 1 }
        doc.apply(.lighting(brightness: 0, contrast: 0, gamma: 1, shadows: 0, highlights: 0))
        #expect(doc.operations.isEmpty && changes == 0)

        doc.preview = Self.brighter
        #expect(changes == 1)
        doc.preview = Self.brighter   // unchanged: no notification
        #expect(changes == 1)
        doc.apply(.blur(radius: 0))
        #expect(doc.preview == nil && doc.operations.isEmpty && changes == 2)

        doc.preview = Self.brighter
        doc.apply(Self.brighter)
        #expect(doc.preview == nil && doc.operations == [Self.brighter] && changes == 4)
    }

    @Test func undoIsCappedAtFiftyStepsButOlderOperationsStay() {
        let doc = document()
        for i in 0..<60 { doc.apply(.blur(radius: Double(i + 1))) }
        var undone = 0
        while doc.canUndo { doc.undo(); undone += 1 }
        #expect(undone == EditDocument.maximumUndoSteps)
        #expect(doc.operations.count == 10)
        #expect(doc.operations.first == .blur(radius: 1))
        while doc.canRedo { doc.redo() }
        #expect(doc.operations.count == 60)
    }

    @Test func dirtyStateFollowsTheSavedOperations() {
        let doc = document()
        #expect(!doc.isDirty)
        doc.apply(.grayscale)
        #expect(doc.isDirty)
        doc.undo()
        #expect(!doc.isDirty)
        doc.redo()
        doc.markSaved()
        #expect(!doc.isDirty)
        doc.apply(.negative)
        #expect(doc.isDirty)
        doc.undo()
        #expect(!doc.isDirty)
        // A preview is not a change to the document.
        doc.preview = .sepia(intensity: 1)
        #expect(!doc.isDirty)
    }

    @Test func outputSizeIncludesThePreview() {
        let doc = document()
        #expect(doc.outputSize == nil)
        doc.sourceSize = CGSize(width: 6000, height: 4000)
        doc.apply(.rotate90(turns: 1))
        #expect(doc.outputSize == CGSize(width: 4000, height: 6000))
        doc.preview = .crop(CGRect(x: 0, y: 0, width: 0.5, height: 0.25))
        #expect(doc.outputSize == CGSize(width: 2000, height: 1500))
        doc.preview = .resize(width: 800, height: 600, filter: .lanczos3)
        #expect(doc.outputSize == CGSize(width: 800, height: 600))
        #expect(doc.snapshot().operations == [.rotate90(turns: 1)])
    }

    @Test func revisionAdvancesWithEveryVisibleChange() {
        let doc = document()
        var last = doc.revision
        func advanced() -> Bool { defer { last = doc.revision }; return doc.revision > last }
        doc.apply(.grayscale); #expect(advanced())
        doc.preview = .negative; #expect(advanced())
        doc.undo(); #expect(advanced())
        doc.redo(); #expect(advanced())
        doc.markSaved(); #expect(!advanced())
    }

    // MARK: - Operations

    @Test func titlesAndIdentity() {
        #expect(EditOperation.rotate90(turns: 1).title == "Rotate Right")
        #expect(EditOperation.rotate90(turns: 3).title == "Rotate Left")
        #expect(EditOperation.rotate90(turns: -1).title == "Rotate Left")
        #expect(EditOperation.rotate90(turns: 2).title == "Rotate 180°")
        #expect(EditOperation.flip(horizontal: false).title == "Flip Vertical")
        #expect(EditOperation.curves(.identity).title == "Curves")

        let identities: [EditOperation] = [
            .rotate90(turns: 0), .rotate90(turns: 8), .rotate(degrees: 0, autoCrop: true), .rotate(degrees: -720, autoCrop: false),
            .crop(CGRect(x: 0, y: 0, width: 1, height: 1)), .crop(CGRect(x: 2, y: 2, width: 1, height: 1)), .crop(.zero),
            .sharpen(amount: 1, radius: 0), .blur(radius: 0), .blur(radius: .nan),
            .lighting(brightness: 0, contrast: 0, gamma: 1, shadows: 0, highlights: 0),
            .colors(hue: 360, saturation: 0, lightness: 0, temperature: 0, tint: 0), .rgbAdjust(red: 0, green: 0, blue: 0),
            .curves(.identity), .curves(ToneCurves(master: [])), .levels(.identity), .sepia(intensity: 0),
            .resize(width: 0, height: 100, filter: .box),
        ]
        for op in identities { #expect(op.isIdentity, "\(op)") }
        let changes: [EditOperation] = [
            .rotate90(turns: 1), .rotate(degrees: 0.5, autoCrop: false), .flip(horizontal: true),
            .crop(CGRect(x: 0.1, y: 0, width: 0.9, height: 1)), .sharpen(amount: 0.5, radius: 1), .blur(radius: 0.5),
            .lighting(brightness: 0, contrast: 0, gamma: 1.1, shadows: 0, highlights: 0),
            .colors(hue: 10, saturation: 0, lightness: 0, temperature: 0, tint: 0), .rgbAdjust(red: 0, green: 0.1, blue: 0),
            .curves(ToneCurves(master: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])),
            .curves(ToneCurves(master: [CurvePoint(x: 0.2, y: 0.2), CurvePoint(x: 1, y: 1)])),   // clips below 0.2
            .levels(Levels(master: LevelsChannel(inputBlack: 0.1, inputWhite: 1, gamma: 1, outputBlack: 0, outputWhite: 1))),
            .grayscale, .sepia(intensity: 0.3), .negative, .resize(width: 100, height: 100, filter: .box),
        ]
        for op in changes { #expect(!op.isIdentity, "\(op)") }
    }

    @Test func operationsRoundTripThroughJSON() throws {
        let ops: [EditOperation] = [
            .resize(width: 1200, height: 800, filter: .lanczos8), .rotate90(turns: 3), .rotate(degrees: -2.5, autoCrop: true),
            .flip(horizontal: false), .crop(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)), .sharpen(amount: 0.7, radius: 1.5),
            .blur(radius: 3), .lighting(brightness: 0.1, contrast: -0.2, gamma: 1.3, shadows: 0.4, highlights: -0.5),
            .colors(hue: -30, saturation: 0.2, lightness: -0.1, temperature: 0.3, tint: -0.2),
            .rgbAdjust(red: 0.1, green: 0, blue: -0.1),
            .curves(ToneCurves(red: [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)])),
            .levels(Levels(blue: LevelsChannel(inputBlack: 0.02, inputWhite: 0.95, gamma: 0.9, outputBlack: 0, outputWhite: 1))),
            .grayscale, .sepia(intensity: 0.8), .negative,
        ]
        let data = try JSONEncoder().encode(ops)
        #expect(try JSONDecoder().decode([EditOperation].self, from: data) == ops)
    }

    // MARK: - Curves and levels maths

    @Test func monotoneCurvePassesThroughItsPointsWithoutOvershoot() {
        let points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.1), CurvePoint(x: 0.35, y: 0.9), CurvePoint(x: 1, y: 1)]
        let curve = MonotoneCurve(points)
        for p in points { #expect(abs(curve.value(at: p.x) - p.y) < 1e-12) }
        var previous = -1.0
        for i in 0...1000 {
            let v = curve.value(at: Double(i) / 1000)
            #expect(v >= previous - 1e-12 && v >= 0 && v <= 1, "at \(i): \(v)")
            previous = v
        }
        // Flat beyond the end points; unsorted input is sorted.
        let inner = MonotoneCurve([CurvePoint(x: 0.8, y: 0.9), CurvePoint(x: 0.2, y: 0.1)])
        #expect(inner.value(at: 0.05) == 0.1 && inner.value(at: 0.95) == 0.9)
        #expect(abs(inner.value(at: 0.5) - 0.5) < 1e-12)
    }

    @Test func lookupTableSamplesEveryCurve() {
        let curves = ToneCurves(master: ToneCurves.diagonal, red: [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)])
        let table = curves.lookupTable(size: 5)
        #expect(table.count == 4 && table.allSatisfy { $0.count == 5 })
        #expect(table[0] == [0, 0.25, 0.5, 0.75, 1])
        #expect(table[1] == [1, 0.75, 0.5, 0.25, 0])
        #expect(ToneCurves.identity.lookupTable(size: 3)[3] == [0, 0.5, 1])
    }

    @Test func levelsChannelMapping() {
        let c = LevelsChannel(inputBlack: 0.2, inputWhite: 0.6, gamma: 2, outputBlack: 0.1, outputWhite: 0.9)
        #expect(c.map(0.1) == 0.1)          // below black: clipped
        #expect(abs(c.map(0.3) - (0.1 + 0.8 * pow(0.25, 0.5))) < 1e-12)
        #expect(c.map(0.9) == 0.9)          // above white: clipped
        #expect(LevelsChannel.identity.map(0.42) == 0.42)
    }

    @Test func toneTableExtendsWithEndSlopes() {
        let table = ToneCurves.identity.toneTable(size: 1024)
        #expect(abs(table.apply(2, channel: 0) - 2) < 1e-4)
        #expect(abs(table.apply(-0.5, channel: 2) + 0.5) < 1e-4)
        #expect(abs(table.apply(0.3337, channel: 1) - 0.3337) < 1e-5)
        let inverted = ToneCurves(master: [CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 0)]).toneTable(size: 64)
        #expect(inverted.apply(3, channel: 0) == 0)   // never sent below black
    }
}
