import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// A document for a file that needn't exist: tool state only commits and
/// previews operations, which never touches pixels.
@MainActor private func document() -> EditDocument {
    let url = URL(fileURLWithPath: "/tmp/minivu-edit-tests/photo.jpg")
    return EditDocument(entry: FolderEntry(url: url, name: "photo.jpg", isDirectory: false, kind: .raster, fileSize: 1,
                                           modified: .distantPast, created: .distantPast))
}

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
        && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

@Suite struct EditCropTests {
    let size = CGSize(width: 6000, height: 4000)

    @Test func startsAsTheWholeImageWhichCropsNothing() {
        let selection = CropSelection(imageSize: size)
        #expect(selection.rect == CGRect(origin: .zero, size: size))
        #expect(selection.operation.isIdentity)
    }

    @Test func presetRatiosFollowOrientation() {
        #expect(CropAspect.free.ratio(imageSize: size, portrait: false) == nil)
        #expect(CropAspect.threeTwo.ratio(imageSize: size, portrait: false) == 1.5)
        #expect(CropAspect.threeTwo.ratio(imageSize: size, portrait: true) == 2.0 / 3)
        #expect(CropAspect.square.ratio(imageSize: size, portrait: true) == 1)
        #expect(CropAspect.original.ratio(imageSize: size, portrait: false) == 1.5)
        #expect(CropAspect.original.ratio(imageSize: size, portrait: true) == 2.0 / 3)
        // A portrait original's own ratio is its portrait orientation.
        let tall = CGSize(width: 3000, height: 4000)
        #expect(CropAspect.original.ratio(imageSize: tall, portrait: true) == 0.75)
        #expect(CropAspect.original.ratio(imageSize: tall, portrait: false) == 4.0 / 3)
        #expect(CropAspect.allCases.map(\.title) == ["Free", "Original", "1:1", "4:3", "3:2", "16:9", "5:4"])
    }

    /// A new ratio keeps the centre and about the area, shrinking to fit.
    @Test func settingAnAspectReshapesInsideTheImage() {
        var selection = CropSelection(imageSize: size)
        selection.setAspect(1)
        #expect(close(selection.rect, CGRect(x: 1000, y: 0, width: 4000, height: 4000)))
        selection.setAspect(16.0 / 9)
        #expect(abs(selection.rect.width / selection.rect.height - 16.0 / 9) < 1e-6)
        #expect(selection.bounds.contains(selection.rect))
        selection.setAspect(nil)
        #expect(selection.aspect == nil)
    }

    @Test func cornerDragsFollowThePointerAndStayInside() {
        var selection = CropSelection(imageSize: size)
        let start = selection.rect
        selection.drag(.topLeft, of: start, to: CGPoint(x: 1000, y: 500))
        #expect(close(selection.rect, CGRect(x: 1000, y: 500, width: 5000, height: 3500)))
        // Past the image's edge it stops at the edge.
        selection.drag(.bottomRight, of: selection.rect, to: CGPoint(x: 9000, y: 9000))
        #expect(close(selection.rect, CGRect(x: 1000, y: 500, width: 5000, height: 3500)))
        // Across the anchor it stops at the minimum size, not flipping over.
        let current = selection.rect
        selection.drag(.topLeft, of: current, to: CGPoint(x: 6500, y: 4500))
        #expect(selection.rect.width == CropSelection.minimumSide && selection.rect.height == CropSelection.minimumSide)
        #expect(selection.rect.maxX == current.maxX && selection.rect.maxY == current.maxY)
    }

    @Test func cornerDragsKeepTheAspect() {
        var selection = CropSelection(imageSize: size)
        selection.setAspect(1)
        let start = selection.rect   // 1000...5000 square
        selection.drag(.bottomRight, of: start, to: CGPoint(x: 3000, y: 2000))
        // The larger span (2000 wide) wins, limited by the 4000 px of height below the anchor.
        #expect(close(selection.rect, CGRect(x: 1000, y: 0, width: 2000, height: 2000)))
        selection.drag(.bottomRight, of: selection.rect, to: CGPoint(x: 6000, y: 6000))
        #expect(close(selection.rect, CGRect(x: 1000, y: 0, width: 4000, height: 4000)))
    }

    @Test func edgeDragsMoveOneSide() {
        var selection = CropSelection(imageSize: size)
        selection.drag(.left, of: selection.rect, to: CGPoint(x: 1500, y: 123))
        #expect(close(selection.rect, CGRect(x: 1500, y: 0, width: 4500, height: 4000)))
        selection.drag(.bottom, of: selection.rect, to: CGPoint(x: 0, y: 3000))
        #expect(close(selection.rect, CGRect(x: 1500, y: 0, width: 4500, height: 3000)))
        // With a ratio the other side follows about the middle, and the moved
        // side stops where that would leave the image.
        selection.setAspect(1)
        let square = selection.rect
        selection.drag(.right, of: square, to: CGPoint(x: 99999, y: 0))
        #expect(selection.rect.height == 4000 && selection.rect.width == 4000)
        #expect(selection.rect.minX == square.minX)
    }

    @Test func movesStayInsideAndNewRectanglesDrawFromAPress() {
        var selection = CropSelection(imageSize: size)
        selection.setRect(CGRect(x: 100, y: 100, width: 1000, height: 1000))
        let start = selection.rect
        selection.move(from: start, by: CGSize(width: -500, height: 99999))
        #expect(selection.rect == CGRect(x: 0, y: 3000, width: 1000, height: 1000))
        selection.draw(from: CGPoint(x: 3000, y: 2000), to: CGPoint(x: 2000, y: 1000))
        #expect(selection.rect == CGRect(x: 2000, y: 1000, width: 1000, height: 1000))
    }

    /// The crop lands on whole pixels, and the readout says what it produces.
    @Test func normalisedRectIsOnWholePixels() {
        var selection = CropSelection(imageSize: CGSize(width: 1000, height: 500))
        selection.setRect(CGRect(x: 10.4, y: 20.6, width: 300.3, height: 100.2))
        #expect(selection.pixelRect == CGRect(x: 10, y: 21, width: 301, height: 100))
        let op = selection.operation
        #expect(EditGraph.outputSize(source: CGSize(width: 1000, height: 500), operations: [op]) == CGSize(width: 301, height: 100))
    }

    @MainActor @Test func toolStateAppliesOneCropAndPresetsFollowTheImage() {
        let doc = document()
        let state = CropToolState(document: doc, imageSize: CGSize(width: 3000, height: 4000))
        #expect(state.portrait)
        #expect(!state.hasPendingChanges)
        var changes = 0
        state.onChange = { changes += 1 }
        state.setPreset(.threeTwo)
        #expect(abs(state.selection.rect.width / state.selection.rect.height - 2.0 / 3) < 1e-6)
        state.swapOrientation()
        #expect(!state.portrait)
        #expect(abs(state.selection.rect.width / state.selection.rect.height - 1.5) < 1e-6)
        #expect(changes == 2)
        #expect(state.hasPendingChanges)
        state.apply()
        #expect(doc.operations.count == 1)
        #expect(doc.undoTitle == "Crop")
        state.reset()
        #expect(state.preset == .free && !state.hasPendingChanges)
    }
}

@Suite struct EditCurveTests {
    @Test func pointsInsertBetweenNeighboursAndNotOnTopOfThem() {
        var points = ToneCurves.diagonal
        #expect(CurveEditing.insert(CurvePoint(x: 0.5, y: 0.7), into: &points) == 1)
        #expect(points.map(\.x) == [0, 0.5, 1])
        #expect(CurveEditing.insert(CurvePoint(x: 0.505, y: 0.2), into: &points) == nil)
        #expect(CurveEditing.insert(CurvePoint(x: 1.4, y: -1), into: &points) == nil)   // clamps onto the end point
        #expect(points.count == 3)
    }

    @Test func movesStayBetweenNeighbours() {
        var points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.3), CurvePoint(x: 0.6, y: 0.6), CurvePoint(x: 1, y: 1)]
        CurveEditing.move(1, to: CurvePoint(x: 0.9, y: 1.5), in: &points)
        #expect(abs(points[1].x - (0.6 - CurveEditing.minimumGap)) < 1e-9)
        #expect(points[1].y == 1)
        CurveEditing.move(0, to: CurvePoint(x: -0.5, y: 0.2), in: &points)
        #expect(points[0].x == 0 && points[0].y == 0.2)
    }

    @Test func endPointsStayWhenRemoving() {
        var points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        #expect(!CurveEditing.remove(0, from: &points))
        #expect(!CurveEditing.remove(2, from: &points))
        #expect(CurveEditing.remove(1, from: &points))
        #expect(points == ToneCurves.diagonal)
        #expect(CurveEditing.isDraggedOut(CurvePoint(x: 0.5, y: 1.2)))
        #expect(!CurveEditing.isDraggedOut(CurvePoint(x: 0.5, y: 1.05)))
    }

    @Test func hitTestingFindsTheNearestPoint() {
        let points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.53, y: 0.5), CurvePoint(x: 1, y: 1)]
        #expect(CurveEditing.hitIndex(points, at: CurvePoint(x: 0.52, y: 0.5), tolerance: 0.04) == 2)
        #expect(CurveEditing.hitIndex(points, at: CurvePoint(x: 0.25, y: 0.75), tolerance: 0.04) == nil)
    }

    @MainActor @Test func curvesPreviewEachChannelAsOneOperation() {
        let doc = document()
        let state = CurvesToolState(document: doc)
        state.channel = .red
        state.edit { _ = CurveEditing.insert(CurvePoint(x: 0.5, y: 0.7), into: &$0) }
        #expect(state.curves.red.count == 3 && state.curves.master == ToneCurves.diagonal)
        #expect(doc.preview == .curves(state.curves))
        #expect(state.hasPendingChanges)
        state.reset()
        #expect(doc.preview == nil)
        state.setCurves(.sCurve)
        state.apply()
        #expect(doc.preview == nil && doc.operations == [.curves(.sCurve)])
    }
}

@Suite struct EditLevelsTests {
    @Test func midtoneHandleAndGammaAgree() {
        var channel = LevelsChannel.identity
        #expect(LevelsMath.gammaPosition(channel) == 0.5)
        channel.gamma = 2
        #expect(LevelsMath.gammaPosition(channel) == 0.25)   // brightening moves it towards black
        channel.inputBlack = 0.2
        channel.inputWhite = 0.8
        let position = LevelsMath.gammaPosition(channel)
        #expect(abs(LevelsMath.gamma(forPosition: position, in: channel) - 2) < 1e-9)
        #expect(LevelsMath.gamma(forPosition: 0, in: channel) > 9.9)
        #expect(LevelsMath.gamma(forPosition: 1, in: channel) == LevelsMath.gammaRange.lowerBound)
    }

    @Test func inputHandlesNeverCross() {
        var channel = LevelsChannel.identity
        LevelsMath.setInputBlack(0.9, in: &channel)
        LevelsMath.setInputWhite(0.1, in: &channel)
        #expect(channel.inputWhite > channel.inputBlack)
        #expect(abs(channel.inputWhite - channel.inputBlack - LevelsMath.minimumSpan) < 1e-9)
        LevelsMath.setOutput(black: 1.5, white: -1, in: &channel)
        #expect(channel.outputBlack == 1 && channel.outputWhite == 0)
    }

    @MainActor @Test func levelsPreviewAndCancel() {
        let doc = document()
        let state = LevelsToolState(document: doc)
        state.channel = .blue
        state.edit { LevelsMath.setInputWhite(0.8, in: &$0) }
        #expect(state.levels.blue.inputWhite == 0.8 && state.levels.master == .identity)
        #expect(doc.preview == .levels(state.levels))
        state.cancel()
        #expect(doc.preview == nil && doc.operations.isEmpty)
    }
}

@Suite struct EditResizeTests {
    @Test func aspectLockAndPercent() {
        var model = ResizeModel(width: 6000, height: 4000)
        #expect(model.isUnchanged)
        model.setWidth(3000)
        #expect(model.height == 2000)
        model.setHeightPercent(25)
        #expect(model.width == 1500 && model.height == 1000)
        #expect(model.widthPercent == 25)
        model.setKeepsAspectRatio(false)
        model.setHeight(1200)
        #expect(model.width == 1500 && model.height == 1200)
        model.setKeepsAspectRatio(true)   // snaps back to the original's proportions
        #expect(model.width == 1500 && model.height == 1000)
        #expect(model.megapixels == 1.5)
        model.filter = .mitchell
        #expect(model.operation == .resize(width: 1500, height: 1000, filter: .mitchell))
    }

    @Test func sizesStayWithinLimits() {
        var model = ResizeModel(width: 100, height: 3)
        model.setWidth(0)
        #expect(model.width == 1 && model.height == 1)
        model.setWidth(1_000_000)
        #expect(model.width == ResizeModel.maximumSide)
        model.setWidthPercent(.nan)
        #expect(model.width == ResizeModel.maximumSide)
        #expect(ResizeModel.sizeText(width: 6000, height: 4000) == "6000 × 4000 px  ·  24.0 MP")
        #expect(ResampleFilter.allCases.count == 11)
    }
}

@Suite struct EditHistogramTests {
    @Test func countsChannelsAndLuminance() throws {
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let histogram = try #require(ImageHistogram.compute(from: image))
        #expect(histogram.red[255] == 1 && histogram.red[0] == 1)
        #expect(histogram.green[0] == 1 && histogram.green[255] == 0)
        #expect(histogram.luminance[54] == 1)   // 0.2126 of full red
        #expect(histogram.bins(for: .blue) == histogram.blue)
    }
}

@MainActor @Suite struct EditAdjustmentToolTests {
    @Test func lightingPreviewsAndAppliesOneStep() {
        let doc = document()
        let state = AdjustmentToolState(kind: .lighting, document: doc)
        #expect(doc.preview == nil && !state.hasPendingChanges)
        state.setValue(0.4, section: 0, slider: 0)
        #expect(doc.preview == .lighting(brightness: 0.4, contrast: 0, gamma: 1, shadows: 0, highlights: 0))
        state.setValue(9, section: 0, slider: 1)   // clamped to the range
        #expect(state.value(section: 0, slider: 1) == 1)
        state.resetSlider(section: 0, slider: 1)
        #expect(state.value(section: 0, slider: 1) == 0)
        state.apply()
        #expect(doc.preview == nil)
        #expect(doc.operations == [.lighting(brightness: 0.4, contrast: 0, gamma: 1, shadows: 0, highlights: 0)])
        #expect(doc.undoTitle == "Lighting")
    }

    @Test func identityAppliesNothingAndCancelLeavesNoTrace() {
        let doc = document()
        let state = AdjustmentToolState(kind: .lighting, document: doc)
        state.setValue(0.2, section: 0, slider: 3)
        state.cancel()
        #expect(doc.preview == nil && doc.operations.isEmpty && !doc.isDirty)
        let other = AdjustmentToolState(kind: .lighting, document: doc)
        other.setValue(0.2, section: 0, slider: 0)
        other.setValue(0, section: 0, slider: 0)
        other.apply()
        #expect(doc.operations.isEmpty)
    }

    /// Sharpen and blur open at a visible setting, previewed at once.
    @Test func sharpenAndBlurPreviewTheirDefaults() {
        let doc = document()
        let sharpen = AdjustmentToolState(kind: .sharpen, document: doc)
        #expect(doc.preview == .sharpen(amount: 1, radius: 1.5))
        sharpen.cancel()
        _ = AdjustmentToolState(kind: .blur, document: doc)
        #expect(doc.preview == .blur(radius: 2))
    }

    /// Both colour sections show at once: the one not being moved is staged
    /// as a committed step. Apply leaves two steps; Cancel takes both back.
    @Test func colorsStagesTheOtherSection() {
        let doc = document()
        doc.apply(.grayscale)   // earlier work, which the tool must never undo
        let state = AdjustmentToolState(kind: .colors, document: doc)
        state.setValue(0.5, section: 0, slider: 1)   // saturation
        #expect(doc.operations == [.grayscale])
        state.setValue(-0.25, section: 1, slider: 0)   // red
        let colors = EditOperation.colors(hue: 0, saturation: 0.5, lightness: 0, temperature: 0, tint: 0)
        let rgb = EditOperation.rgbAdjust(red: -0.25, green: 0, blue: 0)
        #expect(doc.operations == [.grayscale, colors])
        #expect(doc.preview == rgb)
        // Back to the first section: the staged step swaps, leaving no redo.
        state.setValue(0.6, section: 0, slider: 1)
        let colors2 = EditOperation.colors(hue: 0, saturation: 0.6, lightness: 0, temperature: 0, tint: 0)
        #expect(doc.operations == [.grayscale, rgb])
        #expect(doc.preview == colors2)
        #expect(!doc.canRedo)
        #expect(state.hasPendingChanges)

        state.cancel()
        #expect(doc.operations == [.grayscale] && doc.preview == nil)

        let again = AdjustmentToolState(kind: .colors, document: doc)
        again.setValue(0.5, section: 0, slider: 1)
        again.setValue(-0.25, section: 1, slider: 0)
        again.apply()
        #expect(doc.operations == [.grayscale, colors, rgb])
        #expect(doc.preview == nil)
        #expect(doc.undoTitle == "RGB Adjust")
    }

    @Test func gammaSliderMovesInLogScale() throws {
        let gamma = try #require(AdjustmentKind.lighting.sections[0].sliders.first { $0.title == "Gamma" })
        let range = gamma.positionRange
        #expect(abs(gamma.position(for: 1) - (range.lowerBound + range.upperBound) / 2) < 1e-9)
        #expect(abs(gamma.value(forPosition: gamma.position(for: 2.5)) - 2.5) < 1e-9)
    }

    @Test func straightenPreviewsAnAutoCroppedRotation() {
        let doc = document()
        let state = AdjustmentToolState(kind: .straighten, document: doc)
        state.setValue(-3.5, section: 0, slider: 0)
        #expect(doc.preview == .rotate(degrees: -3.5, autoCrop: true))
        state.setValue(80, section: 0, slider: 0)
        #expect(doc.preview == .rotate(degrees: 45, autoCrop: true))
    }
}

@Suite struct EditChromeTests {
    @Test func hudEditedLine() {
        #expect(ViewerHUD.editedText(undoTitle: "Crop") == "Edited  ·  Undo Crop")
        #expect(ViewerHUD.editedText(undoTitle: "") == "Edited")
    }

    /// Zoom survives tone changes, not a change of shape or size.
    @Test func viewIsPreservedOnlyForTheSameGeometry() {
        let size = CGSize(width: 600, height: 400)
        #expect(EditSession.preservesView(displayedGeometry: [], newGeometry: [], displayedSize: size, newSize: size))
        #expect(!EditSession.preservesView(displayedGeometry: [], newGeometry: [.flip(horizontal: true)],
                                           displayedSize: size, newSize: size))
        #expect(!EditSession.preservesView(displayedGeometry: [], newGeometry: [], displayedSize: size,
                                           newSize: CGSize(width: 400, height: 600)))
        #expect(!EditSession.preservesView(displayedGeometry: [], newGeometry: [], displayedSize: nil, newSize: size))
    }

    @MainActor @Test func geometryCountsThePreviewButNotToneOperations() {
        let doc = document()
        doc.apply(.lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0))
        doc.apply(.rotate90(turns: 1))
        #expect(EditSession.geometry(of: doc) == [.rotate90(turns: 1)])
        doc.preview = .crop(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(EditSession.geometry(of: doc).count == 2)
        doc.preview = .crop(CGRect(x: 0, y: 0, width: 1, height: 1))   // identity
        #expect(EditSession.geometry(of: doc) == [.rotate90(turns: 1)])
    }
}
