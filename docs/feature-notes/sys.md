# Feature notes: Live Text, Share and Shortcuts (branch feature/sys)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section of each goal says where
it should.

## G7: Live Text in the viewer

### What the user can do

- **Select text in the picture**, as in Preview. In the viewer, move the
  pointer over the image (over the picture itself: not over the
  filmstrip, a panel or the control bar); a moment later text in it can be selected by
  dragging over it (the pointer becomes an I-beam over text). The text's
  own context menu (right-click on selected text) keeps Copy, Look Up in
  the dictionary and Services.
- **⌘C** in the viewer copies the selected text when there is a
  selection, and the picture (as before) when there isn't.
- **Edit > Copy Text (⇧⌘C)** copies all the text recognised in the
  picture, analysing it first if the pointer hasn't already caused that.
  A picture with no text beeps and leaves the clipboard alone. Moving to
  another picture before the text is read ends the copy silently (no
  beep: nobody found out the picture had no text). Greyed out
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
  picture asks for an analysis (the user might select something), as does
  Copy Text. Only movement over the canvas counts, with nothing in front
  of it (`ViewerWindowController.isOverCanvas(windowPoint:)`, a hit test
  of the window point): the filmstrip, the info and histogram panel and
  the control bar ask for nothing. It starts only once the picture has been on screen for 0.4 s,
  runs off the main thread (texture readback on a GCD thread, recognition
  in VisionKit), at most one at a time, and is cancelled as soon as the
  user moves to another image or page. Zoom, pan and full screen keep the
  analysis, because it is in the picture's own coordinates. An idle viewer
  does nothing.
- **Sharper copies.** A picture is read at the resolution shown when its
  text was first asked for, usually fitted to the window (1 to 2 kpx for a
  24 to 50 MP photo), where small text can't be read. When a texture at
  least **twice as sharp** as the one analysed replaces it (the user zoomed
  in), the picture is analysed once more, with sizes counted up to the
  4096 px cap, and only if its text was already asked for (analysed or
  being analysed). The first analysis stays selectable until the second is
  ready. So the most a picture costs is about three readings (fit, about
  2x, the cap), and only while the user is zooming into it. Copy Text
  waits for the sharper reading when one is due.
- **An edit tool opened and closed** without changing the picture brings
  the analysis back instead of reading the picture again: putting Live
  Text aside (a tool, playback, the setting) stops all work and hides the
  overlay, but keeps the analysis of the picture on screen; any other
  picture drops it.
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
- Text is recognised in what is shown, up to 4096 px on the long side.
  Small text in a large photo becomes selectable after zooming in (see
  "Sharper copies"); text too small to read even at 4096 px (a tiny
  caption in a 100 MP scan) is not, where Preview, which reads the whole
  file, might. Recognition languages are the system's.
- Not in the browser's preview pane or the compare window.

### Where the docs should change

- DESIGN.md section 5, menu shortcut table: Edit gains "Copy Text | ⇧⌘C";
  View gains "Live Text | none". Section 5 Viewer: a paragraph on Live
  Text. Section 4.4 (canvas): the text overlay beside `canvasOverlay`.
  Section 6/1 "idle means idle": Live Text analyses only on pointer
  movement over the picture or Copy Text, and once more when a texture
  twice as sharp arrives for a picture already read. "Selection and the clipboard" (section 7): ⌘C in
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

> Superseded: later work added a sixth action, Set Colour Label
> (batch.md), and AVIF to Convert Images (batch.md, G14). The wiki's
> Tools page has the current list.

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
- The processor's target triple and deployment target come from the
  built binary (`lipo -archs`) and Package.swift (`.macOS(.vNN)`), not
  literals. Only this build's records go in: the whole module's
  `minivu-primary.swiftconstvalues` when no newer record lies beside it,
  otherwise one record for each file in `minivu.SwiftFileList`, so the
  record of a deleted or renamed source file, or one left by a build of
  the other kind, can't bring back an action minivu no longer has.
- Not done: `appintentsnltrainingprocessor` (Siri phrase training). Tried:
  without localised phrases (an AppShortcuts.xcstrings) its corpus comes
  out empty, and its archive step fails outside Xcode. The App Shortcuts
  still carry their phrases in the metadata; whether Siri accepts the
  spoken phrase is unverified.
- What could not be checked here: Shortcuts itself (agents can't launch
  it). "Works" was defined as the right artefacts in the bundle; the
  checks by hand below are what prove it.

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
- **Internal storage only**, as everywhere else in minivu (DESIGN.md 1).
  Every file on disk a shortcut passes is checked with `VolumePolicy` as
  it arrives (`AutomationInput.make`, with the file's access started,
  since the sandbox may hide its volume until then). One file on an
  external drive, a memory card or a network share fails the whole
  action before anything is read, converted or rated: "“IMG_0001.JPG”
  isn't on this Mac's internal storage, so minivu did nothing…", with the
  same advice the Finder open path gives (copy the photos to this Mac
  first). Files that arrive as data are copied into minivu's container,
  which is internal. Open in minivu was already covered by
  `application(_:open:)` and now refuses the same way, as an error the
  shortcut shows.
- **Rename works only where minivu may write already**: the Pictures
  folder and folders added to the sidebar (their bookmarks are opened at
  launch). Nothing new was granted to make it work.
- **All or nothing.** Shortcuts has no "partly done" result, so if any
  file fails to convert the action fails, naming up to eight files, and
  the files that did convert are removed. A rename is checked whole
  before anything moves: Batch Rename's checks (unknown tokens, two files
  getting one name, a name held by another file), then **every folder a
  file would be renamed in must be one minivu may change**
  (`Automation.unwritableFolders`, access(2) with W_OK, which the sandbox
  answers as well as the permissions). One folder minivu may not change
  (for example the Desktop, when it is not in the sidebar) and nothing is
  renamed anywhere, and the error names the folders and says where Rename
  works. What can still fail part-way is a file that changes or goes away
  between the checks and the move (another app renaming it meanwhile);
  then the error lists those files and says the others were renamed (they
  keep their new names and stars, as in Batch Rename). The action
  registers no undo (there is no window to hold it); renaming back with
  another shortcut or Batch Rename is the way back.
- **One rename at a time, app-wide.** Every batch rename, from any
  browser window or any shortcut, joins one queue
  (`BatchTools.queueRename`) and moves files only once the rename before
  it has finished; a window's renames and undos already ran one after
  another, and now also wait for other windows' and for shortcuts'. Two
  renames never meet in a folder half way (the swap step steps a file
  aside under a hidden name), and each sees the folder the previous one
  left. A rename takes milliseconds a file, so the wait is short. The
  plan itself is still made before queuing, so a rename planned against
  a folder another rename then changes turns a clash into a per-file
  failure (exclusive renames), never an overwrite.
- **Nothing on the main thread.** Taking the shortcut's files (reading a
  file that came as data and writing its copy, the volume checks) and
  making or clearing run folders run on a GCD thread
  (`BlockingWork.run`), so a shortcut handing Convert several large
  images from Photos never stalls an open viewer.
- **Files that arrive as data** (from another app, not a disk) are copied
  into minivu's folder for Convert and Resize, under their own names, and
  removed afterwards. Rename and Set Rating refuse them: they are about
  the file itself.
- **Same engines as the menus.** Convert and Resize run Batch Convert's
  planner and `BatchConvertJob` (two files at a time, one on 8 GB Macs,
  one camera RAW at a time; writes through `FileWriteQueue.shared`).
  Rename runs `RenamePlanner` and `BatchRenamer` through
  `BatchTools.renameWithoutWindow`, which queues behind other renames,
  waits for queued writes and counts in `renamesRunning`, so quitting
  waits for it. Ratings go
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
  Rename, which can rename only in folders minivu could already change
  and checks that for every folder before anything moves. Files on
  external, removable or network volumes are refused outright
  (`VolumePolicy`), as in the rest of the app.
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
- `AutomationFiles.swift`: `AutomationInput` (made with `make(_:originalsOnly:)`,
  off the main thread), the shortcut's files checked and made readable for
  the length of the action, and the files handed back.
- `AutomationIntents.swift`: the five intents, the two AppEnums
  (`AutomationFormat`, `AutomationResizeMode`) and `MinivuShortcuts`. Titles,
  defaults and display names must stay literals: the metadata processor
  reads them from the compiler's records, not by running the code.
- `scripts/make_app.sh`: the processor step, after the resources are
  copied and before signing.
- `IntentLaunch.swift`: the launch decision and idle quit (see
  "Launched by a shortcut"); `IntentLaunchTests` drive it with a
  scheduler fired by hand.
- Tests: `AutomationTests` (engine on real files, data-only files, each
  intent's `perform()`, the volume refusal, a read-only folder among
  writable ones renaming nothing, a shortcut's rename waiting behind one
  under way), under `.batchToolsReset`, which now also resets
  `Automation` and the rename queue.

### Launched by a shortcut (decided 2026-11-16)

Formerly a Limit: a shortcut run while minivu was quit launched it with
its browser window and Dock icon, and it stayed open. Harman decided that
a launch made only to run an action must not open the browser.

**Behaviour.**

- A normal launch (Dock, Finder, Launchpad, `open -a`, opening files or
  folders, Open in minivu) shows the browser as before. So do a Dock or
  Finder click on a running minivu and any intent while minivu already
  runs normally.
- A launch for any other action (Convert, Resize, Rename, Set Rating,
  Set Colour Label, which leave `openAppWhenRun` false) shows no window
  and leaves the Dock (`.accessory`) as soon as the action starts. The
  Dock icon shows while minivu starts, until then: the activation policy
  is still `.regular` from main.swift, kept so that a normal launch is
  exactly as before (starting `.accessory` and switching would risk the
  menu bar of every normal launch for a flash on these).
- Such a minivu quits 60 s after its last action ends, through
  `NSApp.terminate`, so the normal quit waits for queued writes
  (`FileWriteQueue`, ratings, renames) exactly as ⌘Q does. Another action
  within the 60 s cancels the quit; the period starts again when it ends.
  60 s: a shortcut's steps, or the same Quick Action used on a few
  selections in a row, come seconds apart, and each would otherwise pay a
  fresh launch (catalog, Metal); an idle windowless process costs little
  for a minute.
- Opening minivu meanwhile (clicking it in the Dock, Finder or
  Launchpad, opening a file in it, Open in minivu) makes it an ordinary
  app: Dock icon, browser window, no quit.

**Telling the launch apart: the evidence.**

- *App Intents (macOS 27.2 SDK, AppIntents.swiftinterface).* No launch
  reason reaches the app. `openAppWhenRun` (deprecated in 26 for
  `supportedModes`), `IntentModes` and
  `IntentSystemContext.currentMode` (26+) describe the intent, and are
  readable only inside `perform()`, after launch has finished.
  `AppDependencyManager` registers dependencies; nothing about launch.
- *AppKit.* `NSApplicationLaunchIsDefaultLaunchKey` is documented as NO
  for opening or printing files, a Services action, restored state "or
  if the app launch was in some other sense not a default launch". An
  intent launch is not listed, so it can't be relied on either way.
- *Apple events.* `kAEOpenApplication` is the event for any launch
  without documents. The public keys (`keyAELaunchedAsLogInItem`,
  `keyAELaunchedAsServiceItem`, `keyAERestoreAppState`) don't cover
  intents. LaunchServices does have private ones: the shared cache holds
  `_kLSOpenOptionBackgroundLaunchKey`,
  `_kLSOpenOptionBackgroundLaunchReasonKey` and
  `_LSOpenExtractBackgroundLaunchReasonFromAppleEvent`, so a background
  launch reason travels in the launch Apple event, under an undocumented
  keyword. Not used: private, and unverifiable without running Shortcuts.
- *What is public, and used:* a launch the user makes activates the app
  (LaunchServices activates it; `applicationDidBecomeActive` follows
  `didFinishLaunching`); a launch for an `openAppWhenRun = false` action
  is meant not to, and its `perform()` runs instead. Agents can't run
  Shortcuts, so this is unverified here; the hand check's log line
  confirms it.

**The decision (`IntentLaunch`, Automation/IntentLaunch.swift).** In
`applicationDidFinishLaunching`, with files to open, the app already
active or the snapshot harness asked for, the browser shows at once.
Otherwise minivu waits up to 300 ms (`decisionWindow`) for whichever comes
first: an activation, a reopen or a file shows the browser; an action's
`perform()` (each one but Open in minivu's runs in `IntentLaunch.run`)
makes the launch intent-only; the timeout shows the browser. An action
that started, or even finished, before launching finished counts. It fails
safe: when unsure, the window shows, as before. The cost to a normal
launch is the time until the activation event, one run-loop turn in
practice, and 300 ms when nothing activates the app (`open -g`, a bare
executable started from Terminal).

For the hand check, launch logs one line (subsystem com.minivu.app,
"launch: event …, default …, active …") with the launch Apple event and
its parameters, `launchIsDefault` and whether minivu was active. If a
Shortcuts launch turns out to activate minivu, it shows the window (as
before) and the line says why.

### Limits

- Rename can't reach folders outside Pictures and the sidebar, by design
  of the sandbox; it refuses the whole set up front when any file is in
  such a folder.
- Files on external drives, memory cards and network shares are refused,
  as in the rest of minivu.
- Set Rating rates the file at the path Shortcuts gives. A shortcut that
  hands on a temporary copy (some actions do) rates the copy.
- Converted files use Batch Convert's other defaults (metadata kept,
  original colour profile, Lanczos 3); the remembered Batch Convert
  settings are not used, so a shortcut does the same on every Mac.
- Siri phrases are unverified (no phrase training, see above).
- English only; the metadata says the phrases are not localised.

### Checks by hand (agents can't run Shortcuts or the sandboxed app)

- Install build/minivu.app in /Applications, open it once, open
  Shortcuts: the five actions appear under minivu, and the three App
  Shortcuts under minivu's app tile.
- Convert Images on two photos from Pictures, then Save File: converted
  copies, originals untouched.
- **Volumes**: the same shortcut as a Quick Action on photos on a USB
  stick or memory card: it fails with "isn't on this Mac's internal
  storage, so minivu did nothing", and Set Rating on them rates nothing.
- **Rename**: three photos in Pictures plus two on the Desktop (Desktop
  not in minivu's sidebar): it fails naming the Desktop folder, and
  nothing is renamed, in Pictures either. With only the Pictures photos
  it renames them. (This confirms access(2) reflects the sandbox, which
  the tests can only show with POSIX permissions.)
- Run a shortcut's rename while a browser window's Batch Rename of other
  files runs: both finish, one after the other.
- **Launch by a shortcut** (see "Launched by a shortcut"). Keep Console
  open, filtered on `launch:`, and note each logged line.
  - With minivu quit, run a Convert shortcut from the Shortcuts app: no
    window appears, the Dock icon shows at most briefly, the converted
    files arrive, and minivu quits about 60 s later (Activity Monitor).
  - The same as a Finder Quick Action on two photos: the same result.
  - Run Convert twice within a minute: the second run doesn't relaunch
    minivu (same process ID in Activity Monitor) and the minute starts
    again after it.
  - With minivu quit, run Open in minivu: the browser and viewer open as
    before, and minivu stays open.
  - Run Convert with minivu quit, then within the 60 s click minivu in
    the Dock (or Launchpad, or double-click it in Applications): the
    browser opens, the Dock icon stays, and minivu doesn't quit.
  - Launch minivu from the Dock, Finder and `open -a minivu`: the browser
    appears as quickly as before.
  - Run Convert on a large set and, while it runs, nothing else: minivu
    quits only after the files are handed back.

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
    minivu's. (Superseded: since G2 in meta.md, minivu can write ratings
    as XMP when Write ratings into files is on.)
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
  minivu's process with its sandbox; no Apple Events interface; "internal
  volumes only" covers the intents too. Section 4.8, Batch Rename: all
  renames, from any window or shortcut, run one at a time
  (`BatchTools.queueRename`).
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
