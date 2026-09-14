import Testing
import CoreGraphics
import Foundation
@testable import MinivuCore

@Suite struct MontageLayoutTests {
    let canvas = CGSize(width: 3024, height: 1964)
    let tolerance = 1e-6

    /// A mix of shapes: landscape, portrait, square, panorama.
    let aspects: [Double] = [1.5, 0.667, 1, 1.5, 1.333, 2.8, 0.75, 1.5, 1.778, 0.8, 1.5, 1.25, 0.5625, 1.5]

    // MARK: Grid

    @Test func gridCellsAreUniformAndSpaced() throws {
        let spacing = 16.0
        let tiles = MontageLayout.grid(aspectRatios: Array(repeating: 1.5, count: 12), canvas: canvas, spacing: spacing)
        // Twelve 3:2 photos on a 3:2-ish screen: four columns, three rows.
        #expect(tiles.count == 12)
        let first = try #require(tiles.first)
        for tile in tiles {
            #expect(abs(tile.frame.width - first.frame.width) < tolerance)
            #expect(abs(tile.frame.height - first.frame.height) < tolerance)
            #expect(tile.rotation == 0 && tile.border == 0)
        }
        let xs = Set(tiles.map { ($0.frame.minX * 1000).rounded() }).sorted()
        let ys = Set(tiles.map { ($0.frame.minY * 1000).rounded() }).sorted()
        #expect(xs.count == 4 && ys.count == 3)
        #expect(abs(first.frame.minX - spacing) < tolerance && abs(first.frame.minY - spacing) < tolerance)
        let last = try #require(tiles.last)
        #expect(abs(last.frame.maxX - (canvas.width - spacing)) < 1e-3)
        #expect(abs(last.frame.maxY - (canvas.height - spacing)) < 1e-3)
        // The gap between neighbouring cells is the spacing.
        let second = tiles[1]
        #expect(abs(second.frame.minX - first.frame.maxX - spacing) < 1e-3)
        #expect(tiles.map(\.image) == Array(0..<12))
    }

    @Test func gridRepeatsPhotosToFillLeftoverCells() {
        let tiles = MontageLayout.grid(aspectRatios: Array(repeating: 1.5, count: 7), canvas: canvas, spacing: 0)
        let shape = MontageLayout.gridShape(count: 7, canvas: canvas, spacing: 0, cellAspect: 1.5)
        #expect(tiles.count == shape.columns * shape.rows)
        #expect(tiles.count >= 7)
        #expect(tiles.map(\.image) == (0..<tiles.count).map { $0 % 7 })
        // No row is left empty.
        #expect((shape.rows - 1) * shape.columns < 7)
    }

    @Test func gridShapeFollowsThePhotosShape() {
        let square = MontageLayout.gridShape(count: 6, canvas: CGSize(width: 3000, height: 2000), spacing: 0, cellAspect: 1)
        #expect(square.columns == 3 && square.rows == 2)
        let tall = MontageLayout.gridShape(count: 6, canvas: CGSize(width: 3000, height: 2000), spacing: 0,
                                           cellAspect: 0.3)
        #expect(tall.columns == 6 && tall.rows == 1)
        #expect(MontageLayout.gridShape(count: 0, canvas: canvas, spacing: 0, cellAspect: 1.5) == (0, 0))
    }

    // MARK: Mosaic

    @Test func mosaicRowsFillTheWidthAndTheHeight() throws {
        let spacing = 12.0
        let tiles = MontageLayout.mosaic(aspectRatios: aspects, canvas: canvas, spacing: spacing)
        // Every photo in order, then repeats from the first when the rows
        // would otherwise fall short of the bottom.
        #expect(tiles.count >= aspects.count && tiles.count <= 2 * aspects.count)
        #expect(tiles.map(\.image) == (0..<tiles.count).map { $0 % aspects.count })
        let rows = Dictionary(grouping: tiles) { ($0.frame.minY * 1000).rounded() }
        #expect(rows.count > 1)
        // One factor stretches (or squashes) every cell's height, so every
        // photo is cropped by the same small share.
        let first = try #require(tiles.first)
        let scale = aspects[first.image] / (first.frame.width / first.frame.height)
        #expect(abs(scale - 1) < 0.1, "the crop is slight: \(scale)")
        for (_, row) in rows {
            let sorted = row.sorted { $0.frame.minX < $1.frame.minX }
            let first = try #require(sorted.first), last = try #require(sorted.last)
            #expect(abs(first.frame.minX - spacing) < tolerance)
            #expect(abs(last.frame.maxX - (canvas.width - spacing)) < 1e-6)
            for (left, right) in zip(sorted, sorted.dropFirst()) {
                #expect(abs(right.frame.minX - left.frame.maxX - spacing) < 1e-6)
            }
            for tile in sorted {
                #expect(abs(tile.frame.height - first.frame.height) < tolerance)
                let shape = tile.frame.width / tile.frame.height
                #expect(abs(aspects[tile.image] / shape - scale) < 1e-6, "photo \(tile.image) is cropped like the rest")
            }
        }
        // Rows are spaced, and the block fills the height between the
        // margins exactly: no band of background at the top or bottom.
        let ordered = rows.values.map { $0[0].frame }.sorted { $0.minY < $1.minY }
        for (upper, lower) in zip(ordered, ordered.dropFirst()) {
            #expect(abs(lower.minY - upper.maxY - spacing) < 1e-6)
        }
        #expect(abs(ordered[0].minY - spacing) < 1e-6)
        #expect(abs(ordered[ordered.count - 1].maxY - (canvas.height - spacing)) < 1e-6)
    }

    /// The rows fill the height whichever way they missed it: too short
    /// (cells grow taller) or too tall (cells get shorter).
    @Test func mosaicFillsTheHeightFromBothSides() throws {
        let screen = CGSize(width: 2560, height: 1600)
        for spacing in [0.0, 8, 30] {
            for photos in [Array(repeating: 1.5, count: 9), Array(repeating: 0.75, count: 13), aspects, [1.5, 1.5, 1.5, 2.8]] {
                let tiles = MontageLayout.mosaic(aspectRatios: photos, canvas: screen, spacing: spacing)
                let top = try #require(tiles.map(\.frame.minY).min())
                let bottom = try #require(tiles.map(\.frame.maxY).max())
                #expect(abs(top - spacing) < 1e-6 && abs(bottom - (screen.height - spacing)) < 1e-6,
                        "\(photos.count) photos, spacing \(spacing): \(top)...\(bottom)")
                let left = try #require(tiles.map(\.frame.minX).min())
                let right = try #require(tiles.map(\.frame.maxX).max())
                #expect(abs(left - spacing) < 1e-6 && abs(right - (screen.width - spacing)) < 1e-6)
            }
        }
    }

    @Test func mosaicOfOnePhotoFillsTheCanvas() throws {
        let tiles = MontageLayout.mosaic(aspectRatios: [0.5], canvas: CGSize(width: 1000, height: 500), spacing: 10)
        let tile = try #require(tiles.first)
        #expect(tiles.count == 1)
        #expect(tile.frame == CGRect(x: 10, y: 10, width: 980, height: 480))
        // Spacing that leaves no height at all: the row stays centred.
        let tight = MontageLayout.mosaic(aspectRatios: [2], canvas: CGSize(width: 1000, height: 100), spacing: 60)
        let row = try #require(tight.first)
        #expect(abs(row.frame.midY - 50) < tolerance && abs(row.frame.width / row.frame.height - 2) < tolerance)
    }

    @Test func mosaicRepeatsPhotosOnlyToReachTheBottom() {
        // Many photos fill the screen on their own: no repeats.
        let many = Array(repeating: 1.5, count: 60)
        #expect(MontageLayout.mosaic(aspectRatios: many, canvas: canvas, spacing: 4).count == 60)
        // Two wide photos can't: they repeat, never more than once each.
        let few = MontageLayout.mosaic(aspectRatios: [2, 2.5], canvas: CGSize(width: 1000, height: 1400), spacing: 0)
        #expect(few.count == 3)
        #expect(few.map(\.image) == (0..<few.count).map { $0 % 2 })
    }

    // MARK: Scattered

    @Test func scatteredIsDeterministicAndInsideTheMargins() {
        let spacing = 20.0
        let a = MontageLayout.scattered(aspectRatios: aspects, canvas: canvas, spacing: spacing, seed: 42)
        let b = MontageLayout.scattered(aspectRatios: aspects, canvas: canvas, spacing: spacing, seed: 42)
        let c = MontageLayout.scattered(aspectRatios: aspects, canvas: canvas, spacing: spacing, seed: 43)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == aspects.count)
        #expect(Set(a.map(\.image)) == Set(aspects.indices))
        let inner = CGRect(origin: .zero, size: canvas).insetBy(dx: spacing, dy: spacing)
        for tile in a {
            let box = tile.boundingBox
            #expect(box.minX >= inner.minX - 1e-6 && box.maxX <= inner.maxX + 1e-6, "tile \(tile.image) x")
            #expect(box.minY >= inner.minY - 1e-6 && box.maxY <= inner.maxY + 1e-6, "tile \(tile.image) y")
            #expect(abs(tile.rotation) <= MontageLayout.maximumTilt)
            #expect(tile.border > 0)
            let picture = tile.pictureFrame
            #expect(abs(picture.width / picture.height - aspects[tile.image]) < 1e-6)
        }
        // The tilts vary.
        #expect(Set(a.map { ($0.rotation * 100).rounded() }).count > 3)
    }

    @Test func scatteredCoversTheCanvasEvenly() {
        let tiles = MontageLayout.scattered(aspectRatios: Array(repeating: 1.5, count: 14), canvas: canvas, spacing: 0,
                                            seed: 7)
        // Every quarter of the screen has a photo's centre in it.
        let half = CGSize(width: canvas.width / 2, height: canvas.height / 2)
        for qx in 0..<2 {
            for qy in 0..<2 {
                let quarter = CGRect(x: Double(qx) * half.width, y: Double(qy) * half.height,
                                     width: half.width, height: half.height)
                #expect(tiles.contains { quarter.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
            }
        }
    }

    @Test func emptyInputsGiveNoTiles() {
        for style in MontageStyle.allCases {
            #expect(MontageLayout.layout(style, aspectRatios: [], canvas: canvas, spacing: 8, seed: 1).isEmpty)
            #expect(MontageLayout.layout(style, aspectRatios: [1.5], canvas: .zero, spacing: 8, seed: 1).isEmpty)
        }
    }

    @Test func unreadableShapesCountAsThreeByTwo() {
        let tiles = MontageLayout.mosaic(aspectRatios: [.nan, 0, -1], canvas: CGSize(width: 900, height: 200), spacing: 0)
        #expect(tiles.count == 3)
        for tile in tiles { #expect(abs(tile.frame.width / tile.frame.height - 1.5) < 1e-6) }
    }

    // MARK: Helpers

    @Test func neededSizeCoversTheCell() {
        // A 3:2 photo in a square cell must be 150 px tall to cover 100 × 100.
        let tile = MontageTile(image: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(MontageLayout.neededLongEdges([tile], aspectRatios: [1.5]) == [0: 150])
        // A portrait photo in a wide cell: 200 wide, so 400 tall.
        let wide = MontageTile(image: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 50))
        #expect(MontageLayout.neededLongEdges([wide], aspectRatios: [1.5, 0.5]) == [1: 400])
        // The largest use wins; the border is left out.
        let bordered = MontageTile(image: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 220), border: 10)
        #expect(MontageLayout.neededLongEdges([tile, bordered], aspectRatios: [1.5]) == [0: 300])
    }

    @Test func aspectFillCentresAndCovers() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 100)
        let fill = MontageLayout.aspectFill(2, in: frame)
        #expect(fill == CGRect(x: -40, y: 20, width: 200, height: 100))
        #expect(MontageLayout.aspectFill(0.5, in: frame) == CGRect(x: 10, y: -30, width: 100, height: 200))
    }

    @Test func seededGeneratorRepeats() {
        var a = SplitMix64(seed: 99), b = SplitMix64(seed: 99)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
        var c = SplitMix64(seed: 1)
        #expect(c.shuffled(Array(0..<10)).sorted() == Array(0..<10))
        let unit = c.nextUnit()
        #expect(unit >= 0 && unit < 1)
    }
}

@Suite struct MontageOutputTests {
    @Test func pixelSizeIsPointsTimesScale() {
        #expect(MontageOutput.pixelSize(points: CGSize(width: 1512, height: 982), backingScale: 2)
            == CGSize(width: 3024, height: 1964))
        #expect(MontageOutput.pixelSize(points: CGSize(width: 1706.5, height: 960), backingScale: 2)
            == CGSize(width: 3413, height: 1920))
        #expect(MontageOutput.pixelSize(points: CGSize(width: 2560, height: 1440), backingScale: 1)
            == CGSize(width: 2560, height: 1440))
    }

    @Test func fileNamesSortByTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_789_381_805)   // 2026-09-14 10:30:05 UTC
        #expect(MontageOutput.timestamp(date, timeZone: utc) == "2026-09-14 at 10.30.05")
        #expect(MontageOutput.montageFileName(date: date, timeZone: utc) == "Montage 2026-09-14 at 10.30.05.jpg")
        #expect(MontageOutput.montageFileName(date: date, display: 2, timeZone: utc)
            == "Montage 2026-09-14 at 10.30.05 (2).jpg")
        let earlier = MontageOutput.montageFileName(date: date.addingTimeInterval(-3600 * 24 * 40), timeZone: utc)
        #expect(earlier < MontageOutput.montageFileName(date: date, timeZone: utc))
    }
}
