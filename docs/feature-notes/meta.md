# Feature notes: metadata editing (G1), Remove location (S4), colour labels and keywords (G4), ratings in files (G2)

Branch `feature/meta`. Notes for the documentation pass: what was built,
why, the limits, and which DESIGN.md, wiki and help sections should change.
Nothing in DESIGN.md, docs/wiki or the help pages was edited.

## G1: Edit Metadata

### What the user can do

- **Image > Edit Metadata…** (⌘I), also in the grid's right-click menu
  under Edit Comment…. Works on the browser's selection (folders ignored)
  and on the image the viewer shows.
- ⌘I was free everywhere: the menus use ⇧⌘I (Invert Selection) and ⌥⌘I
  (Resize/Resample…), and the viewer's bare I (the HUD) returns nil when
  Command is held. ⌘I is Get Info in Finder and Info in Photos, the
  image's details.
- The sheet has:
  - **Description:** Title, Caption, Creator (names separated by
    semicolons, since a name may contain a comma), Copyright.
  - **Keywords:** every keyword any of the files has, with "2 of 5" beside
    one only some files have. Minus removes a keyword from every file
    (undo arrow puts it back); plus adds a partial keyword to the rest. A
    field adds new keywords, comma separated, with Return (and on Save).
    Adding skips a keyword a file already has in another letter case.
  - **Date Taken:** the current date (or Mixed / None), then Leave
    unchanged, **Shift by** (Later or Earlier, days, hours, minutes,
    seconds) or **Set to** (date and time picker, shown as a wall clock).
    For one file, or files that share a date, the new date is shown.
  - **Location:** **Remove location**, with how many of the files have
    one; disabled when none has.
- **Several files:** a field whose value differs shows "Mixed" as its
  placeholder. Left empty it keeps each file's own value; typing a value
  writes it to all; the x button beside a mixed field clears it in every
  file ("Removed from every file"). Only fields the user changed are
  written (`MetadataEdit` holds nil for untouched fields).
- **Save** is the default button, Esc cancels. Save is disabled until
  something changed.
- More than one file shows Batch Convert's progress sheet ("Updating the
  Metadata of N Images") with Cancel. Cancel stops before the next file:
  every file is written atomically, so what is on disk is whole files,
  each with the change or without it.
- Afterwards a summary alert (only when there is something to say) lists
  up to 8 files per kind: failures with their reason, files skipped (PDF,
  SVG), camera raws whose own location stays (see Limits) and files a
  shift found no date taken in.
- If the image has unsaved edits in the viewer, the usual "Save / Don't
  Save / Cancel" question comes first (`resolveUnsavedEdits(before:)`, as
  Move to Trash does), from the browser too.
- Afterwards the browser lists the folder again (new dates and sizes, the
  preview pane), the viewer's entry is restamped from the file as after
  Save (`metadataDidChange`), and the info panel reads again, also after a
  sidecar write (`MetadataRevisions`, see below).
- The info panel's Description section now reads title, caption, keywords,
  artist and copyright the way the editor does (XMP first), shows a
  **Sidecar** row naming the XMP sidecar when one is used, and shows the
  sidecar's date taken as **Original** for such files.

### How it is written (MinivuCore/Export/MetadataWriter.swift)

- **In the file:** JPEG, HEIC/HEIF, PNG, TIFF (the formats lossless rotate
  already rewrites; camera raws excluded by extension and by content, so a
  NEF renamed .tif gets a sidecar). Fields are written as XMP: dc:title,
  dc:description, dc:subject, dc:creator, dc:rights (language alternatives
  as x-default). ImageIO mirrors them into IPTC (ObjectName,
  Caption/Abstract, Keywords, By-line, CopyrightNotice) and TIFF/EXIF
  (ImageDescription, Artist, Copyright), verified for all four formats by
  the tests. The date taken is written as photoshop:DateCreated and
  xmp:CreateDate (plus exif:DateTimeOriginal/Digitized and
  photoshop:DateTimeOriginal when the file has them); ImageIO writes EXIF
  DateTimeOriginal/DateTimeDigitized and IPTC DateCreated/TimeCreated and
  DigitalCreationDate from those. A shift keeps each date's fraction and
  zone suffix; Set writes both dates, as cameras record them.
- **Why the whole XMP view without merging:** measured on macOS 27,
  `kCGImageDestinationMergeMetadata` can't delete a tag in HEIC, PNG or
  TIFF (the documented kCFNull removes nothing there; it works only in
  JPEG), and clearing a field or removing the location are deletions. The
  full copy, changed and passed back with merge off, keeps what has no XMP
  form (Apple's maker note, the EXIF auxiliary tags: verified).
  `kCGImageMetadataShouldExcludeGPS` drops the GPS directory with it; on
  its own, without metadata, it dropped all of a JPEG's EXIF (measured),
  so it is never used alone.
- **JPEG:** ImageIO's copy is made in memory; only its EXIF, XMP and
  extended-XMP segments and the IPTC record inside the Photoshop APP13
  segment are spliced into the original header (`splicedHeader`). Other
  APP13 resources (clipping paths, resolution) are kept; the IPTC digest
  (0x0425) is dropped since it would no longer match. COM comments, unknown
  APPn segments and an MPF gain-map index (offsets corrected) stay. The
  image data is compared byte for byte, so a JPEG is never re-encoded.
  ImageIO writes an odd-sized IPTC record without the pad byte; the parser
  accepts that and pads what it writes.
- **HEIC:** ImageIO's copy is the new file; pixels and the gain map are
  carried over byte for byte (decoded pixels and gain-map data compared in
  the tests).
- **PNG:** ImageIO's copy is *not* used. Measured: it writes the new XMP
  into the old chunk's space and leaves the end of the old XMP in the file
  (a removed title still readable in the bytes), and its eXIf chunk keeps
  the old GPS directory even with ExcludeGPS. Instead a blank 1-bit image
  of the same size is encoded with the new metadata and its eXIf and XMP
  iTXt chunks replace the old ones; legacy tEXt/iTXt/zTXt Title,
  Description, Author, Copyright chunks are dropped when that field is
  changed (the XMP holds the new value), and ImageMagick's "Raw profile
  type …" chunks are dropped as stale copies. IDAT is copied unchanged.
- **TIFF:** ImageIO's copy, made in memory, then `TIFFScrubber` zeroes
  every byte no directory points at. Measured: a TIFF copy writes a shorter
  IPTC record over the old one and leaves the old tail in the file (a
  removed city name readable in the bytes). The scrubber follows the IFD
  chain, SubIFDs, EXIF/GPS/Interop directories, out-of-line values, strips,
  tiles and old-style JPEG thumbnails, and refuses (the write fails, file
  untouched) a structure it can't follow.
- **Every write** goes through `SafeFileWriter` (atomic, creation date,
  permissions and extended attributes kept), is read back before the swap
  and refused if any changed field didn't take (`MetadataWriter.Error
  .didNotTake`), and is recorded with `OwnWrites`. The app queues each batch
  on `FileWriteQueue.shared` with `touching:` (metadata only, so a save in
  progress isn't superseded), naming each image and each sidecar.
- **Sidecars:** camera raws (never modified) and formats ImageIO can't
  rewrite (GIF, BMP, WebP, AVIF, JPEG XL, JPEG 2000, PSD, TGA, ICO…) get
  "basename.xmp" beside the file (`MetadataSidecar.url`), the
  Lightroom/Bridge/Capture One convention. An existing sidecar is merged
  into (a Lightroom rating survives); one that isn't readable XMP is left
  alone and the file reported as failed. Dates go in as
  exif:DateTimeOriginal/photoshop:DateCreated and
  exif:DateTimeDigitized/xmp:CreateDate. `MetadataFields.read(from:)` lays
  the sidecar over the file's own values, only for files that use
  sidecars, so a JPEG never reads its raw twin's sidecar.
- **PDF and SVG** are refused (`Method.unsupported`); the menu item is
  disabled for a selection of only those, and they are listed as skipped.

### Design decisions

- One `MetadataEdit` for the whole selection, holding only changes, keeps
  mixed values intact and makes keywords add/remove rather than replace.
- Writes run one file at a time: each is milliseconds of disk work, and in
  turn Cancel and the report follow the order of the files.
- `MetadataRevisions` (app, @Observable): a per-file counter the info
  panel's task id includes. A sidecar write leaves the image's date alone,
  which is what the panel otherwise follows.
- Progress UI only for more than one file; a single file's write is quick.
- The date is handled as a wall clock (`WallClock`), never converted
  through the Mac's time zone, so a photo taken at 14:30 in Tokyo still
  says 14:30 after a shift made in London.

### Limits

- Camera raws: the location in the raw file itself can't be removed
  (minivu never modifies raws); the summary says so per file. The
  sidecar's date shows in the info panel, but the browser's grid, sort and
  Batch Rename's date token still read the raw's own EXIF date.
- A raw and a GIF (or another sidecar format) with the same base name share
  one sidecar, the convention's known collision.
- Language alternatives: only the x-default entry is edited; other
  languages of a title, caption or rights go with the old value.
- PNG keeps only what XMP can express: tags with no XMP form (a maker note)
  are lost on a PNG metadata write. Rare in PNGs.
- A TIFF maker note that points outside its own blob (rare outside raws)
  would lose what lies outside when the scrubber zeroes unreferenced bytes.
- Folders opened through a single file (not a folder) may not allow a
  sidecar to be created under the sandbox; such a file fails with the
  system's reason.
- Writing to a hard-linked file replaces it with a new inode (as Save does).

### Documentation to change

- DESIGN.md 4.7 "Lossless actions": add Edit Metadata (fields, XMP plus
  IPTC/EXIF mirroring, the per-format strategy above, sidecars, the
  read-back check), and that every write goes through the write queue.
- DESIGN.md 4.6 "Catalog": the sentence "nothing writes them into files"
  still holds for stars and tags; mention that Edit Metadata writes
  descriptive XMP into files or sidecars.
- DESIGN.md 5, shortcut table (Image section): add "Edit Metadata… | ⌘I
  (Finder's Get Info, Photos' Info)". DESIGN.md 5 Browser/Viewer: the
  sheet, mixed values, progress and summary.
- DESIGN.md 8 "Known limits": the Limits above.
- Wiki Editing.md: a section for Edit Metadata after the Edit Comment
  section (line ~164). Wiki Browser.md: the right-click menu list (line
  ~237) and the Image menu list (line ~244). Wiki Keyboard-Shortcuts.md:
  ⌘I. Wiki Limitations.md: the Limits. Wiki Security-and-Privacy.md line
  ~37: Edit Metadata writes into files (or sidecars), never re-encoding.
- Help pages: Editing.md (beside Edit Comment…), Browser.md (Image menu
  list). The keyboard-shortcuts page is generated from the menu bar, so ⌘I
  appears there without an edit.

## S4: Remove location in Save As and Batch Convert

### What the user can do

- **Save As…:** under "Keep metadata (EXIF, GPS, IPTC, XMP)" in Options, an
  indented **Remove location** toggle, disabled while Keep metadata is off.
- **Batch Convert…:** **Remove location** under Keep metadata in the
  Format section, same behaviour.
- **On by default** for both (`ExportOptions.removeLocation` defaults to
  true, and options saved before it existed decode as on). Remembered with
  the other options per format (Save As's store, which Batch Convert also
  starts from, and Batch Convert's own settings).
- **Save (⌘S, in place) keeps all metadata including location**, the
  documented promise: `SavePolicy.inPlaceOptions` turns it off whatever
  Save As remembered.
- **Writing over the original counts as in place, so location is kept
  there too**, whatever the toggle says (the toggle's help tag says so):
  - Save As onto the original itself (its own name, or another letter
    case of it, Replace confirmed in the save panel):
    `SavePresenter.write` turns Remove location off for that write when
    the destination is the source file (`sameFile`/`sameItem`). The
    remembered option is not changed.
  - Batch Convert replacing a source with its own conversion (beside the
    originals, names and format kept, existing files Replace, so the
    action is `.replace(original: true)`):
    `BatchConvertSettings.settings(for:)` turns it off for that output
    only; the batch's other, new files still leave location out.
- It removes the GPS dictionary, every `exif:GPS…` XMP tag (whatever is
  present, not a fixed list), and the IPTC place names (City,
  Sub-location, Province/State, Country code and name, IPTC Extension
  Location Created and Location Shown) with their XMP forms
  (photoshop:City/State/Country, Iptc4xmpCore:Location/CountryCode,
  Iptc4xmpExt:LocationCreated/LocationShown). Everything else is kept.

### Design decisions

- Location is stripped from both views ImageIO is given
  (`CarriedMetadata`'s properties and its XMP metadata): ImageIO writes a
  GPS directory from `exif:GPS…` XMP tags even when the GPS dictionary is
  gone. One shared list (`LocationMetadata`) serves Save As, Batch Convert
  and Edit Metadata, so they can't disagree about what a location is.
- Why the original keeps its location: the task asks for the default on
  for Save As "to a new file" and for Batch Convert, and for in-place Save
  to keep all metadata. Overwriting the source is the in-place case
  whichever command does it; stripping it there would silently and
  permanently lose GPS and place names from the user's only copy, which a
  batch resize "in place" made easy before this fix.
- Save As writes a new file from scratch, so none of the stale-bytes
  problems of rewriting (PNG, TIFF above) apply; the tests search the bytes
  of the result for the removed city anyway.

### Limits

- Camera and lens serial numbers, and dates, are not location and stay
  with Keep metadata on.
- JPEG 2000, GIF, BMP, TGA and ICO carry no metadata at all, so the toggle
  isn't shown for them (as Keep metadata isn't).

### Documentation to change

- docs/SECURITY-REVIEW.md: S4 can be marked fixed (that file lives in the
  main checkout only; it isn't in this worktree).
- DESIGN.md 4.7 "Saving" (the Save As accessory list) and 4.8 Batch
  Convert ("Metadata is kept or stripped by `ImageEncoder`"): add Remove
  location, default on, and that in-place Save keeps location, as do Save
  As onto the original and a Batch Convert output replacing its source.
- Wiki Security-and-Privacy.md line ~34: replace "There is no separate
  switch for location…" with the new option and its default. Wiki
  Editing.md Save As options table (line ~142): add the row. Wiki Tools.md
  Batch Convert options (line ~101): replace "Keeping metadata keeps the
  GPS position too; turn it off to strip it."
- Help pages: Privacy.md (how location is handled on export), Editing.md
  (Save As options) and Tools.md (Batch Convert options).

## Tests

- MinivuCoreTests/MetadataWriterTests: per format (JPEG, HEIC, PNG, TIFF)
  every field written and mirrored into IPTC/TIFF/EXIF with decoded pixels
  identical (JPEG scan data and PNG IDAT byte-identical); removing the
  location property by property and by searching the bytes; clearing a
  field leaves no trace in the bytes; JPEG and HEIC gain maps byte-identical
  with the JPEG comment and MPF index intact; other Photoshop resources and
  unknown APP segments kept; multi-page TIFF; date shift across a year end,
  set, zone suffixes, no date to shift; sidecars for GIF, a DNG by name and
  a raw renamed .tif, merging and an unreadable sidecar; atomic write with
  creation date, permissions and an extended attribute kept.
- MinivuCoreTests/ExportRemoveLocationTests: Save As encodes with Remove
  location on (default) and off for JPEG, PNG, HEIC, TIFF; old option JSON
  decodes with it on. ExportEncoderTests updated for the new default.
- MinivuCoreTests/MetadataReaderTests: the info panel shows a sidecar's
  values and date, and a JPEG never reads its raw twin's sidecar.
- MinivuRenderTests/BatchConvertEngineTests: Batch Convert with Remove
  location on and off, format-only and resized paths.
- MinivuTests/SaveTests: in-place Save turns Remove location off; partial
  stored options load with it on; Save As onto the original (same name and
  another letter case) keeps its location while a copy leaves it out
  (`saveAsOverTheOriginalKeepsItsLocation`).
- MinivuTests/BatchConvertWindowTests:
  `originalsReplacedByTheirConversionKeepTheirLocation` (a source replaced
  by its conversion keeps its location, a new file in the same batch
  doesn't).
- MinivuTests/MetadataEditorTests: the sheet model (mixed fields, clearing,
  keywords for several files, date shift and set, location); the batch
  with mixed values, a sidecar and a skipped PDF; Cancel leaves whole
  files; failures and notes in the summary; the browser command
  (validation, the write, progress sheet, reload) and the viewer command
  (the unsaved-edits question, restamping).
- MinivuTests/MainMenuTests: the menu item and ⌘I (and the existing
  duplicate-shortcut check).

## G4: Colour labels and keywords

### What the user can do

- **Image > Label**, a submenu after Tag: **None, Red, Orange, Yellow,
  Green, Blue, Purple, Gray** on **⌥⌘0 to ⌥⌘7** (None first, then
  Finder's own order of its colour tags). Each item has a dot in its
  colour (a ring for None). It works on the browser's selection (images
  only, as ratings do), the viewer's image and the compare window's
  focused pane. The grid's right-click menu has the same submenu, after
  Rating, without shortcuts.
- The label is the file's **standard Finder colour tag**: choosing Green
  replaces whichever standard colour tag the file had and keeps every
  other tag ("Holiday", a blue "Project" tag of the user's own) in its
  place; None removes the colour tag. The browser's dots and its Finder
  tag filter follow at once. A checkmark shows the label every selected
  image shares.
- **Keywords in the info panel** (the preview pane's and the viewer's
  right-hand panel): for a file whose metadata can be written, the
  keywords are a section of their own at the end, each a token with an
  x button ("Remove keyword Paris" to VoiceOver), then an "Add keywords"
  field: comma separated, Return adds them. A keyword the file already has
  in another letter case isn't added again. The Description section then
  no longer lists them. PDF, SVG and folders show no editor.

### Shortcuts: why ⌥⌘0 to ⌥⌘7

Every key equivalent in MainMenu.swift and the windows' own key handling
was listed first. ⌃0–⌃5 are the ratings, bare digits rate in the grid, viewer
and compare window, ⌘0 is Actual Size and ⌘1–⌘4 pick a compare pane
(only with Command alone, so ⌥⌘1 never reaches them). The ⌥⌘ letters are
taken (Reveal, Resize, Compare, Lighting, Colors, Preview Pane, Batch
Convert, Hide Others) but no ⌥⌘ digit is, and the system's own ⌥⌘8
(Accessibility Zoom) is past the last one. Bridge labels with ⌘6–⌘9 and
Lightroom with bare 6–9, both of which minivu can't use (⌘ digits pick
compare panes; bare digits are FastStone's ratings).
MainMenuTests.noShortcutIsUsedTwice covers it.

### Design decisions

- **Finder tags, not a catalog column.** A Finder tag is the Mac's colour
  label: Finder, Spotlight, Smart Folders and every app that reads tags
  see it, and minivu already read and filtered by them. A label is
  written as Finder writes tags, straight into the
  `com.apple.metadata:_kMDItemUserTags` attribute as "Name\nN" with the
  colour number, so it shows in its colour whatever the system's
  language. The name is Finder's own for that colour
  (`NSWorkspace.fileLabels`, which follows the language and any renaming
  in Finder's settings); a tag named as any standard colour (Finder's
  name or the English one) counts as the colour tag, in any letter case.
- Tag writes go through `FileWriteQueue` (`touching:`): an image write
  copies the file's extended attributes to the new file, so a tag set
  during one could otherwise be lost.
- **Quick keyword edits reuse Edit Metadata's path** (`MetadataEditor.write`
  for one file: no progress sheet, a summary alert only on failure, the
  unsaved-edits question first, `MetadataRevisions` so the panel reads
  again, sidecars for raws).

### Limits

- Labels apply to images only, not folders (as ratings).
- Only one colour label per file: choosing one removes the other standard
  colour tags Finder may have given the file.
- The viewer and compare window don't draw the label; the browser does.
  The browser's dots refresh when it becomes key again.
- A file in a folder minivu may not write extended attributes to beeps
  and is logged; nothing else is said. So does a file whose existing tags
  can't be read (the attribute isn't a list of names, or changed while it
  was read): `FinderTags.entries(of:)` throws and the label is refused
  rather than written alone over tags minivu couldn't see.

## G2: Ratings and the tag in files

### What the user can do

- **Settings > General > "Write ratings into files (XMP)"**, off by
  default, with a footer explaining it. While on, every rating, tag and
  label change made in minivu is also written into the file. While off,
  nothing is written (tested).
- **Reading is always on:** a file with no catalog row shows the rating
  and tag it carries itself (embedded XMP, or for raws and formats minivu
  writes sidecars for, the XMP sidecar first): marks made in Lightroom,
  Bridge, digiKam, XnView MP or a camera appear in the grid, the
  preview pane, the viewer's HUD and the compare window, and sort and
  filter like minivu's own.

### Why reading isn't a setting

Reading never changes a file, and with the conflict policy below it never
overrides anything the user did in minivu: it only fills in files minivu
has no marks for. A setting whose "off" hides real data the user put in
their photos elsewhere would be a trap, and the cost is a header read per
file, made lazily. So it is always on.

### Mapping (MinivuCore/FileMarks.swift, `MarksXMP`)

| minivu | XMP | Notes |
|---|---|---|
| 0–5 stars | `xmp:Rating` | Read and written by Lightroom, Bridge, Capture One, digiKam, XnView MP and Windows. -1 is Bridge's and digiKam's "Rejected": shown as no stars, never written, and kept when minivu clears a rating. "3.0" is read as 3. |
| Tagged | `digiKam:PickLabel` = 3 ("Accepted"), namespace `http://www.digikam.org/ns/1.0/` | Lightroom keeps Pick and Reject in its catalog only (never XMP); Bridge has no pick; XnView MP keeps its tag in its own database. digiKam is the only one of the four with an XMP pick, so its "Accepted" is used. Untagging removes a PickLabel of 3 only: digiKam's Rejected (1) and Pending (2) stay. |
| Colour label | `xmp:Label` = "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray" | Lightroom's default label set's names (Red, Yellow, Green, Blue, Purple), which XnView MP also writes. Bridge's defaults are other words ("Select", "Second", "Approved", "Review", "To Do"), so a Bridge user sees a "custom" label. Chosen colour replaces any label; None removes only a label that names a colour (reading "Grey" too), keeping Bridge's text. |

Why the tag isn't `xmp:Label`: that is where all three label-writing
applications keep the colour label, so a "tagged" label would collide
with G4's colours. Why colour labels don't fight G4: the **Finder tag is
the label**; `xmp:Label` is a one-way copy written when the user labels
in minivu with the setting on. minivu never turns an `xmp:Label` into a
Finder tag (that would change files just by browsing them) and doesn't
show it.

### How it is written

- `MarksFileWriter` (Sources/Minivu/Save/MarksFileWriter.swift) is the
  `CatalogMirror` the catalog was designed with (`CatalogFileMirror`,
  installed with `Catalog.shared.fileMarksReader` in `AppServices.start`).
  Each committed change reaches it on the main queue in order, naming the
  mark it set (`Catalog.MarkField`: rating or tagged); it keeps, per file,
  the last value of each mark changed and the last label chosen.
- **Only the marks changed in minivu are written.** Pressing T writes the
  tag and leaves the file's `xmp:Rating` alone; pressing 3 writes the
  rating and leaves its pick. Otherwise a catalog row with a rating from
  months ago would overwrite, on the next T, a rating set in Lightroom
  since (the row's other mark may be stale relative to the file). This is
  what "never rewrites a file just because they differ" below relies on.
- **Coalesced:** written once changes to the file have been quiet for
  0.8 s. 1-2-3-4-5 quickly is one write with five stars; T T writes
  nothing new.
- **Off the main thread everywhere:** the browser, viewer and compare
  window all write ratings and tags on `BrowserModel.catalogWrites`,
  because a change to a file without a row reads that file's own marks
  first (adoption, below). The browser and the compare window decide a
  tag toggle on that queue too, after any write still queued, so a quick
  T T tags and untags in both (the viewer shows what the keys set at once
  and toggles from that).
- **Quitting** (`applicationShouldTerminate`), with the setting on, always
  waits: `MarksFileWriter.flush(after: BrowserModel.catalogWrites)` waits
  for the catalog's queue to drain, then for the main-queue blocks that
  bring its changes to the writer, then hands everything pending to the
  write queue, and quitting waits for that queue. A rating pressed just
  before ⌘Q, still on the catalog's queue while it reads a few hundred
  sidecars, is therefore written. With the setting off quitting is
  immediate as before.
- **Only committed changes are mirrored.** If the catalog's transaction
  fails (read-only or damaged catalog, full disk) the mirror isn't called:
  the rows still hold their old marks, which would otherwise overwrite a
  value another application has put in the file since.
- **Through FileWriteQueue** (`enqueue(touching:)`, metadata only, naming
  the image and its sidecar), off the main thread (`BlockingWork`), one
  file at a time, by the stage-1 `MetadataWriter`: embedded in JPEG, HEIC,
  PNG and TIFF (lossless, pixels and gain maps untouched, read back), XMP
  sidecar for camera raws and every other format. A file that already says
  what would be written is skipped (no rewrite, no new date); a file gone
  before its turn is skipped.
- Afterwards: `ExternalEditWatcher.noteOwnWrite`, `MetadataRevisions`, the
  viewer restamps its entry, and the file's cache entry is forgotten.
- **Failures** (read-only folder, sandbox refusing a sidecar) are logged;
  the first of a session is told as a sheet on the main window ("The
  rating couldn't be written into …"), later ones only logged, so rating
  a read-only folder doesn't raise an alert per key press. The marks stay
  in the catalog.

### How it is read (never slowing browsing)

- `FileMarksCache` (MinivuCore) remembers each file's marks with its size,
  date and sidecar date; a lookup is one or two `lstat`s, a read is
  `CGImageSourceCopyMetadataAtIndex` (a header read, no pixels) plus the
  sidecar for files that use one. 50,000 entries, then it starts again.
- The browser's listing reads **no file**: it takes what the cache already
  knows (a stat each, on the listing's background thread).
- The grid asks for the marks of cells as they are displayed or
  prefetched (`wantFileMarks`, beside the thumbnail requests): gathered per
  layout pass, read at utility priority in chunks of 200, one read after
  another, each chunk applied as it arrives. Files with a catalog row are
  never read.
- Sorting by rating, or a rating or Tagged Only filter, needs every image's
  marks: then the whole folder is read the same way in the background,
  and the order and filter follow chunk by chunk. Never on the main thread.
- The viewer and compare window read the shown file's marks in the
  background when not known, and show the row's or the remembered marks
  meanwhile.

### Conflict policy: the catalog wins

When the catalog has a row and the file has marks, the **row's marks
show**, and minivu never rewrites a file just because they differ. Why:
a mark made in minivu is the user's explicit choice there; file
timestamps can't say who changed what last (any edit, copy, sync or
backup restore touches them, and a sidecar has its own date); and with
writing on, minivu's choices go into the file, so the two agree. A file
without a row shows its own marks.

Two details make that hold up (Catalog.swift, schema version 2):

- **Adoption:** the first change to a file without a row first copies the
  file's marks into a new row (`fileMarksReader`, reading the file on the
  catalog's write queue), so pressing 3 on a file digiKam tagged keeps it
  tagged instead of the new row silently untagging it (and, with writing
  on, untagging the file).
- **Kept empty rows:** a row is normally deleted when it has no marks. A
  row standing over a file's own marks (`overrides_file`) is kept empty
  instead, so clearing a Lightroom rating in minivu, with writing off,
  doesn't bring the file's rating back. Copies carry the flag. A
  version-1 catalog gains the column on first open and keeps every rating.

Tests: `FileMarksTests.aFilesMarksBecomeTheRowsBeforeAChange`,
`MarksFileTests.clearingAFilesRatingInMinivuKeepsItCleared` and
`filesWithoutARowShowTheirOwnMarksOnceShown` (the catalog wins, a file
with a row isn't even read).

### Limits

- Only changes made while the setting is on are written; turning it on
  doesn't write the marks already in the catalog.
- After a rating is written into a JPEG, HEIC, PNG or TIFF, its date
  changes and its thumbnail is made again, as with any metadata write.
- To take a file's newer rating over a catalog row, rate it again in
  minivu: there is no "prefer the file" command.
- (Not a limit, checked: a rating or keywords written into a file that
  has unsaved viewer edits survive a later Save. Save reads the metadata
  from the file on disk as it writes, and the marks write is minivu's own
  (`OwnWrites`), so Save doesn't take it for another application's
  change. Pinned by `SaveWriteTests.saveKeepsMetadataWrittenWhileEditing`.)
- A pending change for a file moved or renamed within the 0.8 s quiet
  period is skipped (the catalog moves the marks; the file just isn't
  written).
- `xmp:Label` is not read or shown; Finder tags are the labels.
- Windows' EXIF rating tags (0x4746/0x4749) and IPTC StarRating aren't
  read; `xmp:Rating`, which Windows also writes, is.
- The mapping above comes from the applications' documented behaviour; it
  was not checked against the applications themselves on this Mac.

### Documentation to change

- DESIGN.md 4.6 "Catalog": marks can be mirrored into files
  (`CatalogMirror` now implemented; its callback now names the mark that
  changed, `didChange: MarkField`, and mirrors copy out only that mark),
  the conflict policy, adoption and
  kept empty rows, schema version 2 (`overrides_file`), and reading of
  file marks (`FileMarksCache`), lazy. Replace "nothing writes them into
  files".
- DESIGN.md 4.7 (metadata writing): `MetadataEdit` also carries rating,
  tag and colour label; the `MarksXMP` mapping table above.
- DESIGN.md 4.x on the browser model: `wantFileMarks`, the chunked
  background reads, whole-folder reads for rating sort and filters.
- DESIGN.md 5, shortcut table (Image section): Label None…Gray, ⌥⌘0–⌥⌘7.
  DESIGN.md 5 Browser/Viewer/Compare: the Label submenu; the info panel's
  keyword editor. Settings: the new General toggle.
- DESIGN.md 8 "Known limits": the G2 and G4 limits above.
- Wiki Browser.md: Label in the Image menu and context menu lists, the
  info panel's keywords, ratings from other apps. Wiki Viewer.md: Label,
  the info panel's keywords. Wiki Compare (or wherever compare is
  documented): Label. Wiki Settings page: the toggle and its footer. Wiki
  Keyboard-Shortcuts.md: ⌥⌘0–⌥⌘7. Wiki Limitations.md: the limits. Wiki
  Security-and-Privacy.md: the setting modifies files only when on; tags
  are written as extended attributes.
- Help pages: Browser.md (Label, keywords in the preview pane, ratings
  from other apps), Viewer.md (Label, keywords in the info panel),
  Settings (the toggle). The keyboard-shortcuts page is generated from the
  menu bar, so ⌥⌘0–⌥⌘7 appear without an edit.

## Tests (G4 and G2)

- MinivuCoreTests/FileMarksTests: marks written into JPEG, HEIC, PNG and
  TIFF with identical pixels and cleared again; a reject, digiKam's other
  picks and Bridge's label text kept; raws' marks in the sidecar (a
  Lightroom sidecar with attribute-form values read and merged); a JPEG
  never reads its raw twin's sidecar; colour label names; the cache reads
  once until the file or sidecar changes; adoption and kept empty rows,
  copies included; a version-1 catalog migrated; Finder colour tags set,
  replaced and removed keeping other tags, localised names, no empty
  attribute left; unreadable tags refused, not overwritten.
- MinivuTests/MarksFileTests: nothing written with the setting off (and
  it defaults off); 1-2-3-4-5 and T T written once with the last value;
  only the mark that changed is written (a Lightroom rating survives T);
  writes wait behind earlier writes in FileWriteQueue; raws get a sidecar
  and are never modified; a file that already says it is left alone, a
  missing file skipped, a failure reported once; labels reach
  `xmp:Label`; the browser shows files' own ratings only once shown,
  reads no file while listing, never reads a file with a row (the catalog
  wins), and reads the whole folder for rating sort and filters; clearing
  a file's rating in minivu sticks; label logic, the menu's titles,
  shortcuts and VoiceOver descriptions. The browser and viewer Label
  commands with checkmarks are in `AppWindowTests.LabelWindowTests` (in
  the same file).
- MinivuTests/KeywordEditingTests: comma splitting; no editor for a PDF or
  folder; sections and fields from one read.
  `AppWindowTests.KeywordWindowTests` (same file): the viewer's and the
  browser's quick keyword edits written without a sheet.
- Every test here that opens a browser or viewer window is nested in
  `AppWindowTests`, the serialized parent of all window suites (one
  viewer, one `ImageLoader` prefetch set); outside it they ran alongside
  other window suites and closed their viewer.
- MinivuTests/CompareWindowTests: ratings and tags now land on the
  catalog's queue; a quick T T tags and untags. ManageModelTests
  (`ratingChangesReachOnlyTheirCells`): the same in the browser.
- MarksFileTests `flushingBeforeQuittingWaitsForTheCatalogsQueue`: a
  rating still on the catalog's queue when quitting is written.
- MinivuCoreTests/CatalogTests `aFailedChangeIsNotMirrored`: a change
  whose transaction fails never reaches the mirror.
- MinivuTests/MainMenuTests: the Image menu's order with Label (and the
  existing duplicate-shortcut check).
