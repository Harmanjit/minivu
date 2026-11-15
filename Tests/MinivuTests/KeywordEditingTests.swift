import Testing
import AppKit
import MinivuCore
@testable import Minivu

/// The info panel's keywords, added and removed in place in the viewer and
/// the browser's preview pane (G4).
@MainActor @Suite(.serialized) struct KeywordEditingTests {
    @Test func theFieldSplitsKeywordsAtCommas() {
        #expect(KeywordEditor.keywords(in: "Paris, Seine ,, night ") == ["Paris", "Seine", "night"])
        #expect(KeywordEditor.keywords(in: " , ").isEmpty)
    }

    @Test func theInfoPanelReadsTheFieldsWithTheSections() throws {
        let t = try ScratchFolder()
        let a = try t.jpeg("a.jpg", width: 20, height: 20)
        try MetadataWriter.apply(MetadataEdit(addedKeywords: ["one", "two"]), to: a)
        let read = MetadataReader.sectionsAndFields(for: a)
        #expect(read.fields?.keywords == ["one", "two"])
        #expect(read.sections == MetadataReader.sections(for: a))
        #expect(MetadataReader.sectionsAndFields(for: try t.file("doc.pdf")).fields == nil, "no editor for a PDF")
        #expect(MetadataReader.sectionsAndFields(for: t.url).fields == nil, "nor for a folder")
    }
}

extension AppWindowTests {
    /// Keywords edited in place in the viewer's info panel and the browser's
    /// preview pane. They open the app's windows, so they run with the other
    /// window suites.
    @MainActor @Suite(.serialized) struct KeywordWindowTests {
        @Test func theViewerEditsItsImagesKeywords() async throws {
            let folder = try ScratchFolder()
            let url = try folder.jpeg("a.jpg", width: 300, height: 200)
            let entry = try #require(FolderEntry(url: url))
            ViewerWindowController.show(images: [entry], index: 0, fullScreen: false) { _ in }
            defer { ViewerWindowController.show(images: [], index: 0, fullScreen: false) { _ in } }
            let viewer = try #require(ViewerWindowController.current)
            await TestTiming.waitUntil { viewer.model.current != nil }

            let stub = MetadataSheetStub(answer: nil)
            defer { stub.restore() }
            let edit = try #require(viewer.infoPanel(for: entry).editKeywords)
            edit(MetadataEdit(addedKeywords: KeywordEditor.keywords(in: "Paris, Seine ,, ")))
            await TestTiming.waitUntil { MetadataFields.read(from: url).keywords == ["Paris", "Seine"] }
            #expect(MetadataFields.read(from: url).keywords == ["Paris", "Seine"])
            edit(MetadataEdit(removedKeywords: ["Paris"]))
            await TestTiming.waitUntil { MetadataFields.read(from: url).keywords == ["Seine"] }
            #expect(MetadataFields.read(from: url).keywords == ["Seine"])
            #expect(stub.models.isEmpty, "no sheet for a quick keyword edit")
            // A PDF's panel shows its keywords, if any, without an editor.
            let pdf = try #require(FolderEntry(url: try folder.file("doc.pdf")))
            #expect(viewer.infoPanel(for: pdf).editKeywords == nil)
        }

        @Test func theBrowserEditsKeywordsFromThePreviewPane() async throws {
            _ = NSApplication.shared
            let t = try ScratchFolder()
            let a = try t.jpeg("a.jpg", width: 20, height: 20)
            let controller = BrowserWindowController()
            defer { controller.window?.close() }
            _ = controller.grid.view
            controller.open(folder: t.url)
            await controller.model.work?.value
            controller.writeKeywords(MetadataEdit(addedKeywords: ["night"]), to: a)
            await TestTiming.waitUntil { MetadataFields.read(from: a).keywords == ["night"] }
            #expect(MetadataFields.read(from: a).keywords == ["night"])
            await MetadataEditor.work?.value
            #expect(MetadataRevisions.shared.revision(of: a) > 0)
        }
    }
}
