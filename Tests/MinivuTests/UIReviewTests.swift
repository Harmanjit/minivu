import Testing
import AppKit
import MinivuCore
import MinivuRender
@testable import Minivu

/// Keyboard, accessibility and motion rules from the whole-app UI review.
@MainActor @Suite struct UIReviewTests {
    func keyDown(_ characters: String, modifiers: NSEvent.ModifierFlags = .command, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 51)
    }

    /// ⌘⌫, ⌘↑ and ⌘↓ typed while a text field has the keyboard are the
    /// text's (the menu items that share them validate as disabled); a click
    /// on the menu, or the same keys elsewhere, still reach the commands.
    @Test func textEditingKeysBelongToTheText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "IMG_0001")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 22)
        let other = NSView(frame: NSRect(x: 10, y: 50, width: 50, height: 50))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)

        let key = try #require(keyDown("\u{7F}", in: window))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!TextKeys.belongToText(in: window, event: key))

        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSText)
        #expect(TextKeys.belongToText(in: window, event: key))
        #expect(!TextKeys.belongToText(in: window, event: click))
        #expect(!TextKeys.belongToText(in: window, event: nil))
        #expect(!TextKeys.belongToText(in: nil, event: key))
    }

    /// Reduce Motion keeps the fades and the dissolve and turns every
    /// transition that moves the picture into a cross-fade.
    @Test func reduceMotionTransitions() {
        for transition in SlideshowTransition.allCases {
            #expect(transition.reducingMotion(false) == transition)
        }
        #expect(SlideshowTransition.crossFade.reducingMotion(true) == .crossFade)
        #expect(SlideshowTransition.fadeThroughBlack.reducingMotion(true) == .fadeThroughBlack)
        #expect(SlideshowTransition.dissolve.reducingMotion(true) == .dissolve)
        for moving in [SlideshowTransition.slide, .push, .wipe, .zoom, .iris] {
            #expect(moving.reducingMotion(true) == .crossFade)
        }
    }

    /// With Reduce Motion a fly-out appears where it will stay and fades,
    /// rather than starting past the edge and sliding in; closing, it fades
    /// where it is.
    @Test func reduceMotionFlyoutsFadeInPlace() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let flyouts = FlyoutController(container: container)
        let top = NSView()
        flyouts.add(top, edge: .top, thickness: 96)
        flyouts.reducesMotion = { true }
        flyouts.layout(in: container.bounds)
        let open = FlyoutGeometry.openFrame(for: .top, thickness: 96, in: container.bounds, pinnedThickness: [:])

        flyouts.pointerMoved(to: CGPoint(x: 500, y: 598))
        #expect(flyouts.isOpen(.top) && !top.isHidden)
        #expect(top.frame == open)

        flyouts.pointerMoved(to: CGPoint(x: 500, y: 300))
        #expect(!flyouts.isOpen(.top))
        #expect(top.frame == open)

        // Pinned without animation, as the snapshot harness and tests do.
        flyouts.setPinned(true, edge: .top, animated: false)
        #expect(top.frame == open && top.alphaValue == 1)
    }

    /// VoiceOver hears a thumbnail as one item: its name, stars, tag,
    /// Finder tags and size.
    @Test func gridCellSpeaksAsOneItem() {
        #expect(ThumbnailCellView.accessibilityText(name: "a.jpg", isFolder: false, rating: 0, isTagged: false,
                                                    finderTags: [], dimensions: "") == "a.jpg")
        #expect(ThumbnailCellView.accessibilityText(name: "a.jpg", isFolder: false, rating: 1, isTagged: true,
                                                    finderTags: ["Red", "Work"], dimensions: "600 × 400")
                == "a.jpg, 1 star, tagged, Finder tags: Red, Work, 600 × 400")
        #expect(ThumbnailCellView.accessibilityText(name: "Trip", isFolder: true, rating: 3, isTagged: true,
                                                    finderTags: [], dimensions: "") == "Trip, folder")

        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 150, height: 200))
        cell.nameField.stringValue = "b.jpg"
        cell.isRatable = true
        cell.detailField.stringValue = "6032 × 4032"
        cell.setMarks(Catalog.Marks(rating: 4, isTagged: true), finderTags: [FinderTag(name: "Blue", colorIndex: 4)])
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .image)
        #expect(cell.accessibilityLabel() == "b.jpg, 4 stars, tagged, Finder tags: Blue, 6032 × 4032")
        #expect(!cell.nameField.isAccessibilityElement() && !cell.stars.isAccessibilityElement())
        cell.isSelected = true
        #expect(cell.isAccessibilitySelected())
    }

    /// Increase Contrast outlines a selected cell; a folder under a drag is
    /// outlined either way.
    @Test func increaseContrastOutlinesTheSelection() {
        #expect(ThumbnailCellView.borderWidth(isSelected: true, isDropTarget: false, increasesContrast: false) == 0)
        #expect(ThumbnailCellView.borderWidth(isSelected: true, isDropTarget: false, increasesContrast: true) == 2)
        #expect(ThumbnailCellView.borderWidth(isSelected: false, isDropTarget: false, increasesContrast: true) == 0)
        #expect(ThumbnailCellView.borderWidth(isSelected: false, isDropTarget: true, increasesContrast: false) == 2)
    }

    /// A control bar button is spoken by name; the key in brackets is left
    /// to the tooltip.
    @Test func controlBarButtonsAreSpokenWithoutTheirKeys() {
        #expect(ViewerControlBar.spokenName("Next Image (→)") == "Next Image")
        #expect(ViewerControlBar.spokenName("Full Screen (Return)") == "Full Screen")
        #expect(ViewerControlBar.spokenName("Show Info") == "Show Info")
        #expect(ViewerControlBar.spokenName("Play (Space)") == "Play")
    }
}
