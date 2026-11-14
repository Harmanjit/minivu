# Feature notes: Live Text, Share and Shortcuts (branch feature/sys)

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

## G12: Shortcuts actions (automation)

### What the user can do

In the Shortcuts app, minivu now appears in the action library (search
"minivu", or the Apps tab) with five actions:

| Action | Parameters (defaults) | Result |
|---|---|---|
| Convert Images | Images; Format (JPEG; also HEIC, PNG, TIFF, JPEG 2000, GIF, BMP, TGA, ICO); Quality 1-100 (90); Long Side in pixels (empty = keep the size, never enlarges); Remove Location (on) | the converted images |
| Resize Images | Images; Resize By (Long Side, Width, Height, Percentage); Size (2048); Enlarge Smaller Images (off); Remove Location (on) | the resized images, each in its own format (JPEG where minivu can't write the original's, e.g. RAW) |
| Rename Images | Images; Pattern (`{date}-{###}`, Batch Rename's tokens); Counter Starts At (1) | the files under their new names |
| Set Rating | Images; Rating 0-5 (5; 0 clears) | the same files |
| Open in minivu | Images or Folder | nothing; minivu comes forward |

Three of them (Convert, Resize, Open in minivu) are also offered as ready
App Shortcuts under minivu in the Shortcuts app (and Spotlight), which ask
for their images when run.

Finder Quick Actions: a shortcut that receives images "from Quick Actions"
and uses a minivu action can be turned on as a Quick Action (shortcut
details > Use as Quick Action > Finder), and then appears in Finder's
right-click > Quick Actions. minivu can't ship a user shortcut itself, so
this is a recipe for the docs, not a built-in item. Finder's own Open With
> minivu already covers opening.

Scripts: `shortcuts run "<name>" --input-path <file>` runs such a shortcut
from Terminal; Automator can call it through "Run Shortcut". There is no
AppleScript dictionary (see Decisions).

No menu items, key equivalents or settings were added.

### Feasibility finding (App Intents without Xcode)

The question was whether Shortcuts can see App Intents in an app built by
plain SwiftPM and scripts/make_app.sh. It can:

- SwiftPM's default build engine since Swift 6.2 is Swift Build (the
  engine Xcode uses). It already passes the compiler the App Intents
  protocol list and writes a `.swiftconstvalues` file per source (debug)
  or per module (release), with no flags added. Measured on a scratch
  package and on minivu (`minivu-p.build/Objects-normal/arm64/
  minivu-primary.swiftconstvalues` in release).
- What Xcode adds is running `appintentsmetadataprocessor` (in the Xcode
  toolchain) over those records. make_app.sh now does that after copying
  the resources, writing `Contents/Resources/Metadata.appintents/`
  (`extract.actionsdata` and `version.json`, tools version 27B52). It
  lists the five actions with their parameters, defaults and ranges, the
  two enums, `openAppWhenRun` for Open in minivu only, and the three App
  Shortcuts. The signature seals it with the other resources; `codesign
  --verify --strict` passes.
- make_app.sh names `--build-system swiftbuild` explicitly and stops if
  the records or the actions are missing, so a toolchain change can't
  ship an app whose actions have silently vanished.
- Not done: `appintentsnltrainingprocessor` (Siri phrase training). Tried:
  without localised phrases (an AppShortcuts.xcstrings) its corpus comes
  out empty, and its archive step fails outside Xcode. The App Shortcuts
  still carry their phrases in the metadata; whether Siri accepts the
  spoken phrase is unverified.
- What could not be checked here: Shortcuts itself (agents can't launch
  it). "Works" was defined as the right artefacts in the bundle; the
  manual checks below are what proves it.

### Decisions

- **App Intents, not an AppleScript dictionary.** App Intents were
  feasible, so they were used: Shortcuts, Spotlight and Siri use them
  natively, they pass files with their own sandbox permission, and they
  add no Apple Events surface. minivu still has no scripting dictionary,
  no `NSAppleEventsUsageDescription`, and no Services (NSServices)
  entries; Open With in Finder and a Quick Action shortcut cover Finder.
- **Convert and Resize never write beside the originals.** A shortcut's
  files come with permission to read each file, not to write in its
  folder, and minivu's sandbox would refuse such writes anyway. So they
  are converted into a folder of minivu's own in its container
  (`tmp/Automation/<run>/`) and handed back as files; the shortcut's next
  action (Save File, Move, AirDrop…) puts them where the user wants. Each
  output is marked `removedOnCompletion`, so Shortcuts deletes it once it
  has taken it, and run folders older than a day are removed when the
  next run starts.
- **Rename works only where minivu may write already**: the Pictures
  folder and folders added to the sidebar (their bookmarks are opened at
  launch). Elsewhere it fails, saying exactly that, after Batch Rename's
  usual checks. Nothing new was granted to make it work.
- **All or nothing.** Shortcuts has no "partly done" result, so if any
  file fails to convert the action fails, naming up to eight files, and
  the files that did convert are removed. A rename is checked whole
  before anything moves (unknown tokens, clashes); a rename that fails
  part-way reports the failures (the renamed files keep their new names
  and their stars, as in Batch Rename).
- **Files that arrive as data** (from another app, not a disk) are copied
  into minivu's folder for Convert and Resize, under their own names, and
  removed afterwards. Rename and Set Rating refuse them: they are about
  the file itself.
- **Same engines as the menus.** Convert and Resize run Batch Convert's
  planner and `BatchConvertJob` (two files at a time, one on 8 GB Macs,
  one camera RAW at a time; writes through `FileWriteQueue.shared`).
  Rename runs `RenamePlanner` and `BatchRenamer` through
  `BatchTools.renameWithoutWindow`, which waits for queued writes and
  counts in `renamesRunning`, so quitting waits for it. Ratings go
  through `BrowserModel.catalogWrites` and the action returns once
  written. Open in minivu calls `AppDelegate.application(_:open:)`, the
  Finder path.
- **Remove location** reuses `ExportOptions.removeLocation`, brought over
  unchanged from feature/meta (commit e5cc1d8 and its
  LocationMetadata.swift) so both branches merge cleanly. Resize offers
  it too, on by default, as Batch Convert does.
- **Colour labels**: the rating is implemented; a `// COLOUR LABEL:` mark
  in Automation.swift and AutomationIntents.swift says what to add (a
  `SetColorLabelIntent` with a literal AppEnum of the labels, and
  `Automation.setColorLabel`) when labels land.

### Security and privacy (for the security review)

The review recorded no Apple Events interface (CWE-352, cross-site
request forgery's desktop form: another process driving the app). That is
still true: there is no scripting dictionary and no Apple Events handler
beyond AppKit's standard open-documents event. The new surface is App
Intents:

- **Who can run them.** Only the system's intent runtime, on behalf of
  Shortcuts, Spotlight or Siri: a shortcut the user built or added, or a
  ready App Shortcut the user runs. Other apps cannot call minivu's
  intents directly. Scripts can run a user's shortcut (`shortcuts run`),
  which needs the user's shortcut to exist first.
- **What they can reach.** The intents run inside minivu's own process,
  with its sandbox and entitlements unchanged (no network, user-selected
  files, app-scoped bookmarks, Pictures). They read only the files the
  shortcut passed (each with its own security scope, released when the
  action ends, except Open in minivu, which keeps it for the session as
  a Finder open does) and write only into minivu's container, except
  Rename, which can rename only in folders minivu could already change.
- **Prompts.** Shortcuts has its own privacy prompts (for example before
  a shortcut first shares files with an app); macOS asks
  before any app sends Apple Events to another (Automation privacy), which
  applies to "Run AppleScript" steps but not to minivu's intents, which
  aren't Apple Events. Exactly which prompts appear is for the manual
  check.
- **Nothing leaves the Mac** through minivu: no network code was added,
  and what a shortcut does with the files next is Shortcuts' business.
- **Destructive power.** The worst a shortcut can do through minivu is
  rename images in Pictures or sidebar folders (undoable by renaming
  back; stars follow) and change ratings. Nothing is deleted or
  overwritten: Convert and Resize never replace a file.

### How it is built

- `Sources/Minivu/Automation/Automation.swift`: the engine (`convert`,
  `resize`, `convertSettings`, `rename`, `setRating`, `open`,
  `makeRunFolder`), with `outputRoot` and `catalog` replaceable in tests.
- `AutomationFiles.swift`: `AutomationInput`, the shortcut's files made
  readable for the length of the action, and the files handed back.
- `AutomationIntents.swift`: the five intents, the two AppEnums
  (`AutomationFormat`, `AutomationResizeMode`) and `MinivuShortcuts`. Titles,
  defaults and display names must stay literals: the metadata processor
  reads them from the compiler's records, not by running the code.
- `scripts/make_app.sh`: the processor step, after the resources are
  copied and before signing.
- Tests: `AutomationTests` (engine on real files, data-only files, each
  intent's `perform()`), under `.batchToolsReset`, which now also resets
  `Automation`.

### Limits

- A shortcut run while minivu isn't open launches it in the background;
  the browser window appears as at any launch.
- Rename can't reach folders outside Pictures and the sidebar, by design
  of the sandbox.
- Set Rating rates the file at the path Shortcuts gives. A shortcut that
  hands on a temporary copy (some actions do) rates the copy.
- Converted files use Batch Convert's other defaults (metadata kept,
  original colour profile, Lanczos 3); the remembered Batch Convert
  settings are not used, so a shortcut does the same on every Mac.
- Siri phrases are unverified (no phrase training, see above).
- English only; the metadata says the phrases are not localised.

### Quick Look extension: assessed, not built

Asked whether a Quick Look preview extension is feasible and adds
something real. Findings:

- **Buildable: yes.** A scratch SwiftPM executable linked with
  `-e _NSExtensionMain -application_extension` (unsafe linker flags, which
  a root package may use) and a `QLPreviewProvider` builds, has
  `_NSExtensionMain` as its entry point, and wraps into an .appex
  (`XPC!`, `com.apple.quicklook.preview`) that signs ad hoc with the
  sandbox and hardened runtime and verifies. Whether PlugInKit loads an
  ad-hoc-signed extension (no team identifier) could not be tested
  without registering it with the system, which agents must not do.
- **Adds little, takes something away:**
  - minivu's ratings live in its catalog in minivu's own container. A
    sandboxed extension has a container of its own and cannot read
    minivu's without an App Group, which needs an entitlement this task
    does not add and, on macOS 15 and later, a team-signed provisioning
    profile for a prompt-free group container; ad hoc signing has none.
  - minivu writes no XMP ratings (DESIGN.md 4.6: stars stay in the
    catalog), so a rating read from XMP would be Lightroom's, not
    minivu's.
  - Finder's preview pane, Get Info and Quick Look's own info already
    show the camera, lens, exposure and size.
  - minivu decodes only through Apple's frameworks, so the system preview
    already shows every format minivu reads. A data-based extension would
    replace it for the types it claims and lose what it has: HDR
    highlights, Live Text, Markup, rotation, multi-page PDFs and
    animations.
  - It would be a second binary decoding untrusted files, against "lean".
- **Recommendation:** not worth shipping. Revisit if minivu ever mirrors
  ratings into XMP (`CatalogMirror`), and even then a Finder column or
  Spotlight importer would serve better than replacing the preview.

### Where the docs should change

- DESIGN.md section 2 (Platform): the SwiftPM bullet gains "make_app.sh
  also runs appintentsmetadataprocessor to write
  Contents/Resources/Metadata.appintents (Shortcuts actions); it relies on
  Swift Build writing .swiftconstvalues". Section 4.8 (Tools): a new
  "Automation" paragraph from "Decisions" and "How it is built" above.
  Section 5: a short "Shortcuts" entry listing the five actions. Section 8
  (Known limits): the Limits above. Section 1 or 2: App Intents run in
  minivu's process with its sandbox; no Apple Events interface.
- Wiki: Tools.md (a "Shortcuts" section with the table and the Quick
  Action recipe), Security-and-Privacy.md (the security section above),
  Architecture.md (the Automation folder and the metadata step),
  Installation.md (building needs the Xcode toolchain for the metadata
  step, as it already does for xcrun), Limitations.md, Troubleshooting.md
  ("minivu's actions don't appear in Shortcuts": move the app to
  /Applications, open it once, restart Shortcuts).
- Help pages: Tools.md (using minivu in Shortcuts, Quick Action recipe),
  Privacy.md (what a shortcut can and can't do through minivu).
- Keyboard shortcuts page: no change (no key equivalents added).
- docs/SECURITY-REVIEW.md (on another branch): add App Intents as a new
  surface with the protections above.
