# Feature notes: Live Text and Share (branch feature/sys)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section of each goal says where
it should.

## G7: Live Text in the viewer

### What the user can do

- **Select text in the picture**, as in Preview. In the viewer, move the
  pointer over the image; a moment later text in it can be selected by
  dragging over it (the pointer becomes an I-beam over text). The text's
  own context menu (right-click on selected text) keeps Copy, Look Up in
  the dictionary and Services.
- **⌘C** in the viewer copies the selected text when there is a
  selection, and the picture (as before) when there isn't.
- **Edit > Copy Text (⇧⌘C)** copies all the text recognised in the
  picture, analysing it first if the pointer hasn't already caused that.
  A picture with no text beeps and leaves the clipboard alone. Greyed out
  in the browser, while Live Text is off, and before a picture is shown.
- **View > Live Text** (checkmark, no shortcut) turns the feature on or
  off. On by default. Off means nothing is analysed at all, the overlay is
  hidden and Copy Text is greyed out. Takes effect at once in an open
  viewer. Stored in the defaults key `liveText`.

### What is analysed, and when

- **What is shown, not the file.** The texture the canvas draws is read
  back (`LiveTextImage`, MinivuRender) as an upright 8-bit sRGB image no
  longer than 4096 px: the page shown, an edit's render (an open tool's
  unapplied change included, as Copy takes it), the frame of a paused
  animation. No decode: the texture is already at the size the screen
  needed, sharper only if the user zoomed in, so "never decode more pixels
  than shown" holds.
- **HDR**: an HDR texture is tone mapped from its own content headroom
  (`CIToneMapHeadroom`) for recognition, so text in highlights brighter
  than paper white keeps its edges. This image is never written or shown,
  so the app keeps its HDR; it is not an edit operation, so
  `hdrHighlightsSurviveEveryKindOfTool` does not apply (the scale-down
  happens after the tone map, so the macOS 27 clamp issue cannot clip it).
- **Lazily.** Flipping through a folder with the keyboard analyses
  nothing, however long each picture stays up. The pointer moving over the
  viewer asks for an analysis (the user might select something), as does
  Copy Text. It starts only once the picture has been on screen for 0.4 s,
  runs off the main thread (texture readback on a GCD thread, recognition
  in VisionKit), at most one at a time, and is cancelled as soon as the
  user moves to another image or page. A picture is analysed once: zoom,
  pan, full screen and sharper textures keep the analysis, because it is in
  the picture's own coordinates. An idle viewer does nothing.
- A `LiveTextController.Subject` names the picture (file, date, page, the
  edit operations drawn, the animation frame) and is taken when each
  texture arrives, not when analysis starts: an edit changes the document
  at once but its render arrives later, and the picture still on screen
  meanwhile must not be filed under the edit.
- **Not offered** while an edit tool is open (the tool owns the pointer
  and its picture changes with every slider step) or while an animation
  plays. It comes back when the tool closes or playback pauses.

### Privacy decisions

- Only `ImageAnalyzer.AnalysisTypes.text` is requested. Text recognition
  runs on the Mac. **Visual Look Up** (plants, landmarks, art) asks Apple's
  servers, so it is never requested, and the overlay's interaction type is
  `.textSelection` only, so it never offers Look Up for the image either.
  Machine-readable codes are not requested (nothing would use them).
- **Data detectors are off.** Each would underline part of the photo and
  turn a click there into opening Safari, Maps or FaceTime: another
  application, and a network connection, from a click that everywhere
  else on the image toggles the zoom. Selecting the text and copying it
  covers what they would do, at the user's word. (Data detection itself
  is local; the objection is to what a click on one launches.)
- The overlay's menu loses the image-wide items VisionKit adds (Copy
  Image, Share Image, Copy/Share Subject, Look Up): the viewer's own
  commands copy and share the image, and subject lifting is not asked for.
- No entitlement was added. Nothing in minivu opens a connection.

### How it is built

- `Sources/Minivu/Viewer/LiveText.swift`: `LiveTextAnalyzing` (the seam;
  `VisionLiveTextAnalyzer` in the app, a fake in tests),
  `LiveTextController` (scheduling, cancelling, the overlay's delegate)
  and `LiveTextOverlayHost`.
- `Sources/Minivu/Viewer/ViewerLiveText.swift`: the viewer's glue, Copy
  Text, validation, availability.
- The overlay (`ImageAnalysisOverlayView`) sits in a host view that
  `ViewerContainerView.textOverlay` keeps on the canvas's frame, above the
  canvas and below any tool overlay, the HUD and the panels. The host lets
  the pointer through to the canvas everywhere but on text (and anywhere
  inside it while a selection exists), so a click beside text still
  toggles the zoom, a drag still pans and press-and-hold still shows the
  magnifier. A click away from the text ends a selection. When the
  selection empties, the keyboard goes back to the canvas.
- Following the view: the delegate's `contentsRect(for:)` returns the
  picture's rectangle as a fraction of the overlay's bounds, reaching past
  them when zoomed in. **VisionKit's unit space counts from the top left**
  even though the overlay is not flipped, and `hasText(at:)` takes points
  the same way; this was measured (a test with real recognition checks
  that text drawn at the top of a picture is selectable there, and not at
  the mirrored place, at fit and when zoomed in and panned to a corner).
  The canvas calls `onTextOverlayViewChange` after every zoom, pan or
  resize (beside `onViewChange`, which belongs to the tools).

### Limits

- On text, a drag selects rather than pans and a press-and-hold selects
  rather than shows the magnifier (as in Preview). On a picture covered in
  text, pan with the arrow keys, a trackpad or the scroll wheel, or turn
  Live Text off.
- A playing animation has no Live Text; pause it (P) first.
- Text is recognised in what is shown at screen size; very small text in a
  large photo is read better after zooming in (the sharper texture is not
  re-analysed automatically, since the picture is the same; Copy Text
  after zooming in uses the analysis already made). Recognition languages
  are the system's.
- Not in the browser's preview pane or the compare window.

### Where the docs should change

- DESIGN.md section 5, menu shortcut table: Edit gains "Copy Text | ⇧⌘C";
  View gains "Live Text | none". Section 5 Viewer: a paragraph on Live
  Text. Section 4.4 (canvas): the text overlay beside `canvasOverlay`.
  Section 6/1 "idle means idle": Live Text analyses only on pointer
  movement or Copy Text. "Selection and the clipboard" (section 7): ⌘C in
  the viewer copies selected Live Text before the picture. Section 8:
  the limits above. A note under 4.3 that Live Text tone maps HDR for
  recognition only.
- Wiki: Viewer.md (new "Live Text" section), Keyboard-Shortcuts.md (Edit:
  Copy Text ⇧⌘C; View: Live Text), Security-and-Privacy.md ("No network":
  Live Text is on-device text recognition only, no Visual Look Up, no data
  detectors), Settings.md (View > Live Text is a setting kept between
  launches), Accessibility.md (the overlay is labelled "Text in the
  image"), Limitations.md, Architecture.md (VisionKit is the one framework
  added; tests use a fake analyser plus one real recognition test).
- Help pages: Viewer.md ("Select and copy text"), Privacy.md ("No
  network": text recognition stays on the Mac). The Keyboard Shortcuts
  page is generated and picks up ⇧⌘C by itself.

## G15: Share

### What the user can do

- **Browser:** File > Share…, the grid's right-click menu (Share…) and a
  new Share button in the toolbar (between Slideshow and Search) offer the
  selected images to the system's share sheet: AirDrop, Messages, Mail,
  Notes and whatever else is installed. With nothing selected, the lead
  image. Folders in the selection are left out (sharing a folder is a
  Finder job). Unlike the other Tools it never falls back to every image
  in the folder.
- **Viewer:** File > Share… offers the image shown. The share sheet points
  at the middle of the picture.
- No shortcut (Finder's Share has none either).

### Decisions

- **No network entitlement, no connection.** Each share service runs in
  its own process and reads the files through the sandbox extension the
  picker gives it. minivu only hands over file URLs. (Decided by Harman.)
- **Unsaved edits in the viewer:** the file as last saved is shared, and
  the user is told first ("“name” has edits that aren’t saved. The file is
  shared as it was last saved, without the edits made here. To share the
  edits, save them first." Share Saved File / Cancel), the same rule as
  Open in External Editor. Rejected: sharing a rendered copy. That means
  writing a file under a name, format and quality nobody chose, somewhere
  the service can read, kept for as long as an AirDrop or a Mail draft
  might take, and the picture shared would exist nowhere the user can see
  it. Saving first, then sharing, does the same with choices they made.
  Share is greyed out in the viewer while a sheet is up.
- Files, never pictures: the share sheet always gets the file as it is on
  disk, with its metadata, as Finder would share it.

### How it is built

- `Sources/Minivu/Tools/Share/FileSharing.swift`: `SharePresenting` (the
  seam; `SharingServicePresenter` uses `NSSharingServicePicker`) and
  `FileSharing.shared`, which asks the unsaved-edits question through a
  `confirm` hook and then shows the picker.
- `BrowserShare.swift`, `ViewerShare.swift`: the `shareFiles:` action and
  where the sheet points. The toolbar button is AppKit's
  `NSSharingServicePickerToolbarItem`, whose delegate (`BrowserToolbar`)
  returns the same `shareURLs` when it is clicked.
- Tests never reach a share service: the presenter is a fake and the
  question is answered by the test.

### Limits

- The toolbar button shows the system's picker directly (AppKit's own
  item), so it does not go through `FileSharing`; that is fine in the
  browser, which has no edits to warn about.
- Many files at once are offered as they are; there is no confirmation
  threshold (the share sheet itself shows what is being sent).

### Where the docs should change

- DESIGN.md section 5, menu shortcut table: File gains "Share… | none".
  Section 5 Browser toolbar list: Share. Section 5 Tools / external
  editors neighbourhood: a Share paragraph with the unsaved-edits rule.
  Section 1/2: the note that share services (like external editors) run
  in their own processes and minivu still opens no connection.
- Wiki: Browser.md (toolbar list, right-click menu, a "Share" section),
  Viewer.md, Keyboard-Shortcuts.md (File: Share…, no shortcut),
  Security-and-Privacy.md (sharing hands file URLs to the system's share
  services; minivu makes no connection), Limitations.md.
- Help pages: Browser.md and Viewer.md (how to share), Privacy.md.
