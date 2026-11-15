import Testing
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MinivuCore
import MinivuRender
@testable import Minivu

extension AppWindowTests {
    /// G6: named presets for Batch Convert and Batch Rename, the batch's own
    /// watermark, and the viewer's Save Edits as Preset. Presets go to a
    /// defaults suite of the test's own.
    @MainActor @Suite(.serialized, .batchToolsReset) struct BatchPresetWindowTests {
        let scratchDefaults = ScratchDefaults("minivu-batch-preset-tests")
        var defaults: UserDefaults { scratchDefaults.defaults }
        let sheets = BatchSheetRecorder()

        init() {
            _ = NSApplication.shared
            BatchTools.store = BatchStore(defaults: defaults)
            BatchTools.trash = { url in throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            BatchTools.sheets = sheets.presenter
        }

        var store: BatchStore { BatchTools.store }

        func stamp(_ text: String) -> Watermark {
            var watermark = Watermark()
            watermark.text = text
            return watermark
        }

        // MARK: - The list

        /// Save, save over (one name, any letter case), rename, delete, and
        /// everything kept in the store as it changes, in name order.
        @Test func presetsAreSavedRenamedAndDeleted() throws {
            let list = PresetList<RenamePattern>.rename(store)
            #expect(list.presets.isEmpty)
            let web = try #require(list.save(RenamePattern(text: "web {#}"), as: "  Web  "))
            #expect(web.name == "Web")
            list.save(RenamePattern(text: "{date}"), as: "Archive")
            #expect(list.presets.map(\.name) == ["Archive", "Web"])
            let replaced = try #require(list.save(RenamePattern(text: "web-{###}"), as: "WEB"))
            #expect(replaced.id == web.id && list.presets.count == 2, "one preset per name, whatever the case")
            #expect(list.save(RenamePattern(), as: "  \n ") == nil, "a name of nothing")

            #expect(!list.rename(web.id, to: "archive"), "the name is taken")
            #expect(list.rename(web.id, to: "Blog"))
            #expect(PresetList<RenamePattern>.rename(store).presets.map(\.name) == ["Archive", "Blog"])
            #expect(store.renamePresets.first { $0.name == "Blog" }?.value == RenamePattern(text: "web-{###}"))

            list.delete(web.id)
            #expect(PresetList<RenamePattern>.rename(store).presets.map(\.name) == ["Archive"])

            // Two lists of one store (two sheets up at once) never write
            // back what the other saved away.
            let other = PresetList<RenamePattern>.rename(store)
            other.save(RenamePattern(text: "{name}"), as: "Plain")
            list.save(RenamePattern(text: "{ext}"), as: "Ext")
            #expect(PresetList<RenamePattern>.rename(store).presets.map(\.name) == ["Archive", "Ext", "Plain"])
            #expect(PresetList<RenamePattern>.cleaned(String(repeating: "x", count: 200))?.count
                == PresetList<RenamePattern>.maximumNameLength)
        }

        /// The remembered settings stay under their old keys and load as
        /// before; a stored preset that can't be read (a later minivu's) is
        /// skipped and the others still load.
        @Test func oldSettingsAndUnreadablePresetsStillLoad() throws {
            defaults.set(Data(#"{"options":{"format":"png"},"quarterTurns":2}"#.utf8), forKey: "batchConvertSettings")
            defaults.set(try JSONEncoder().encode(RenamePattern(text: "old {#}")), forKey: "batchRenamePattern")
            #expect(store.convertSettings?.quarterTurns == 2 && store.convertSettings?.edits == [])
            #expect(store.renamePattern.text == "old {#}")

            let good = NamedPreset(name: "Grey", value: BatchConvertPreset(edits: [.grayscale]))
            let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
            let future = #"{"id":"\#(UUID().uuidString)","name":"Future","value":{"edits":[{"teleport":{}}]}}"#
            defaults.set(Data("[\(future),\(goodJSON)]".utf8), forKey: "batchConvertPresets")
            #expect(store.convertPresets.map(\.name) == ["Grey"])
            #expect(store.convertPresets.first?.value.edits == [.grayscale] && store.convertPresets.first?.value.output == nil)
        }

        // MARK: - Batch Convert

        /// A preset saved from the sheet brings back every option and the
        /// edits; one made in the viewer (edits only) changes the edits and
        /// nothing else; None clears the edits.
        @Test func convertPresetsBringBackTheSheet() async throws {
            let t = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try t.jpeg("IMG_1.jpg", width: 20, height: 20)))
            let model = BatchConvertModel(entries: [entry], store: store)
            model.format = .png
            model.settings.resize = BatchResize(mode: .longSide, pixels: 800)
            model.settings.quarterTurns = 1
            model.settings.edits = [.grayscale, .sharpen(amount: 1, radius: 2)]
            model.settings.watermark = stamp("© Web")
            model.usesPattern = true
            model.pattern = RenamePattern(text: "web {#}")
            #expect(model.choose(folder: try t.folder("out")))
            #expect(model.savePreset(named: "Web"))
            let saved = model.settings
            let webID = try #require(model.selectedPresetID)
            #expect(store.convertPresets.first?.value.edits == [.grayscale, .sharpen(amount: 1, radius: 2)])
            #expect(store.convertPresets.first?.value.output?.edits == [], "the edits are kept once, beside the output")

            // An edits-only preset, as the viewer saves it.
            PresetList.convert(store).save(BatchConvertPreset(edits: [.negative, .resize(width: 5, height: 5, filter: .box)]),
                                           as: "Negative")
            let again = BatchConvertModel(entries: [entry], store: store)
            #expect(again.presets.presets.map(\.name) == ["Negative", "Web"])
            again.format = .jpeg
            again.usesPattern = false
            again.setUsesChosenFolder(false)
            again.settings.edits = []
            again.choosePreset(again.presets.named("Negative")?.id)
            #expect(again.settings.edits == [.negative], "only steps a preset may carry")
            #expect(again.format == .jpeg && !again.usesPattern && !again.usesChosenFolder, "the rest stays")

            again.choosePreset(webID)
            #expect(again.settings == saved, "everything the sheet had when saved")
            #expect(again.usesPattern && again.pattern.text == "web {#}" && again.chosenFolder?.lastPathComponent == "out")
            #expect(again.watermarkSummary == "“© Web”")

            again.choosePreset(nil)
            #expect(again.settings.edits.isEmpty && again.selectedPresetID == nil)
            #expect(again.settings.watermark == stamp("© Web"), "None clears the edits only")

            again.choosePreset(webID)
            again.removeEdit(at: 0)
            #expect(again.settings.edits == [.sharpen(amount: 1, radius: 2)])
            #expect(again.renameSelectedPreset(to: "Blog"))
            #expect(!again.renameSelectedPreset(to: "negative"), "taken")
            again.deleteSelectedPreset()
            #expect(PresetList.convert(store).presets.map(\.name) == ["Negative"] && again.selectedPresetID == nil)
        }

        /// The watermark is added in the batch sheet with the viewer's
        /// inspector, picture included, and Apply hands it to the batch;
        /// Cancel changes nothing, and one that draws nothing is no
        /// watermark.
        @Test func aWatermarkIsAddedInTheBatchSheet() async throws {
            let t = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try t.jpeg("a.jpg", width: 20, height: 20)))
            let logo = try t.jpeg("logo.jpg", width: 8, height: 8)
            let model = BatchConvertModel(entries: [entry], store: store)
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            let convert = BatchConvertSheet(model: model)
            convert.begin(on: parent) { _ in }
            defer { convert.end() }

            convert.editWatermark()
            var editor = try #require(sheets.shown.last?.contentView as? NSHostingView<WatermarkInspectorView>)
            let year = Calendar(identifier: .gregorian).component(.year, from: Date())
            #expect(editor.rootView.state.payload.text == "© \(year)")
            editor.rootView.state.update { $0.text = "© Me"; $0.tiled = true }
            editor.rootView.actions.cancel()
            #expect(model.settings.watermark == nil, "cancelled")

            convert.editWatermark()
            editor = try #require(sheets.shown.last?.contentView as? NSHostingView<WatermarkInspectorView>)
            let ask = ViewerWindowController.askForWatermarkImage
            defer { ViewerWindowController.askForWatermarkImage = ask }
            ViewerWindowController.askForWatermarkImage = { _, done in done(logo) }
            editor.rootView.chooseImage()
            editor.rootView.actions.apply()
            let watermark = try #require(model.settings.watermark)
            #expect(watermark.kind == .image && watermark.imageName == "logo.jpg" && watermark.imageBookmark != nil)
            #expect(model.watermarkSummary == "logo.jpg")
            #expect(sheets.shown.last?.contentView is NSHostingView<BatchConvertView>, "back to the Convert sheet")

            // Editing starts from the watermark there is; one that draws
            // nothing is removed.
            convert.editWatermark()
            editor = try #require(sheets.shown.last?.contentView as? NSHostingView<WatermarkInspectorView>)
            #expect(editor.rootView.state.payload == watermark)
            editor.rootView.state.update { $0.kind = .text; $0.text = " " }
            editor.rootView.actions.apply()
            #expect(model.settings.watermark == nil)
        }

        /// A batch with a preset's edits and a watermark writes them into
        /// every file, through the browser's run.
        @Test func aBatchAppliesThePresetsEdits() async throws {
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 80, height: 60)
            let b = try t.jpeg("b.jpg", width: 60, height: 80)
            let controller = BrowserWindowController(catalog: Catalog.inMemory())
            _ = controller.grid.view
            defer { controller.window?.close() }
            controller.open(folder: t.url)
            await controller.model.work?.value
            controller.preview.isVisible = false

            var settings = BatchConvertSettings(options: .defaults(for: .png), edits: [.negative])
            settings.watermark = stamp("MMMM")
            controller.runBatchConvert([try #require(FolderEntry(url: a)), try #require(FolderEntry(url: b))],
                                       settings: settings)
            await controller.batchWork?.value
            for name in ["a.png", "b.png"] {
                let url = t.url.appendingPathComponent(name)
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                // ScratchFolder's JPEGs are orange (0.8, 0.3, 0.1): the
                // negative is a blue, much less red.
                let centre = centreRGB(image)
                #expect(centre[0] < 140 && centre[2] > 140, "\(name) is the negative: \(centre)")
            }
        }

        func centreRGB(_ image: CGImage) -> [Int] {
            var pixel = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
            return pixel.prefix(3).map(Int.init)
        }

        // MARK: - Batch Rename

        @Test func renamePresetsBringBackThePattern() throws {
            let t = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try t.jpeg("a.jpg", width: 10, height: 10)))
            let model = BatchRenameModel(entries: [entry], store: store)
            model.pattern = RenamePattern(text: "{date:yyyyMMdd}-{###}", counterStart: 7, nameCase: .lower)
            #expect(model.savePreset(named: "Dated"))
            let dated = try #require(model.selectedPresetID)
            model.pattern = RenamePattern(text: "{name}")
            model.choosePreset(nil)
            #expect(model.pattern.text == "{name}", "None leaves the pattern")
            model.choosePreset(dated)
            #expect(model.pattern == RenamePattern(text: "{date:yyyyMMdd}-{###}", counterStart: 7, nameCase: .lower))

            let again = BatchRenameModel(entries: [entry], store: store)
            #expect(again.presets.presets.map(\.name) == ["Dated"])
            again.choosePreset(dated)
            #expect(again.renameSelectedPreset(to: "By Date"))
            again.deleteSelectedPreset()
            #expect(store.renamePresets.isEmpty)
        }

        // MARK: - Save Edits as Preset

        /// Closes whatever viewer is open without asking about edits.
        func closeViewer() {
            ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in }
        }

        func enabled(_ viewer: ViewerWindowController, _ action: Selector) -> Bool {
            viewer.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        /// File > Save Edits as Preset… in the viewer: enabled once the photo
        /// has edits; the sheet lists what travels and what stays behind, and
        /// saving makes a preset Batch Convert offers. Saving over a preset
        /// made in Batch Convert keeps its output options.
        @Test func saveEditsAsPresetFromTheViewer() async throws {
            let folder = try ScratchFolder()
            let entry = try #require(FolderEntry(url: try folder.jpeg("IMG_7.jpg", width: 600, height: 400)))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { closeViewer() }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.canEditCurrent }
            #expect(!enabled(viewer, .saveEditsAsPreset), "nothing edited yet")

            var shown: EditsPresetModel?
            let present = ViewerWindowController.presentEditsPreset
            defer { ViewerWindowController.presentEditsPreset = present }
            ViewerWindowController.presentEditsPreset = { model, _ in shown = model }

            viewer.rotateRight(nil)
            let session = try #require(viewer.editSession)
            session.document.apply(.lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0))
            session.document.apply(.redEye([RedEyeSpot(center: CGPoint(x: 0.4, y: 0.4))]))
            session.document.apply(.resize(width: 300, height: 450, filter: .lanczos3))
            #expect(enabled(viewer, .saveEditsAsPreset))
            viewer.saveEditsAsPreset(nil)
            let model = try #require(shown)
            #expect(model.name == "IMG_7 Edits")
            #expect(model.portable.operations == [.rotate90(turns: 1),
                                                  .lighting(brightness: 0.2, contrast: 0, gamma: 1, shadows: 0, highlights: 0)])
            #expect(model.portable.leftOut.map(\.title) == ["Red-Eye Removal", "Resize"])
            #expect(model.canSave && model.status == nil)

            // Saved over a preset Batch Convert made: its output stays.
            let output = BatchConvertSettings(options: .defaults(for: .heic), quarterTurns: 2)
            PresetList.convert(store).save(BatchConvertPreset(edits: [.grayscale], output: output), as: "img_7 edits")
            #expect(model.status?.contains("img_7 edits") == true)
            let saved = try #require(model.save())
            #expect(saved.value.edits == model.portable.operations && saved.value.output == output)
            #expect(BatchConvertModel(entries: [entry], store: store).presets.presets.map(\.name) == ["IMG_7 Edits"])
            #expect(session.document.isDirty, "the photo's edits are left as they were")

            // Edits that can't travel at all can't be saved.
            let nothing = EditsPresetModel(operations: [.redEye([RedEyeSpot()])], suggestedName: "x", store: store)
            #expect(!nothing.canSave && nothing.save() == nil && nothing.status != nil)
            model.name = "   "
            #expect(!model.canSave)
        }
    }
}
