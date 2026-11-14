# Feature notes: metadata editing (G1) and Remove location (S4)

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
  location, default on, and that in-place Save keeps location.
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
  stored options load with it on.
- MinivuTests/MetadataEditorTests: the sheet model (mixed fields, clearing,
  keywords for several files, date shift and set, location); the batch
  with mixed values, a sidecar and a skipped PDF; Cancel leaves whole
  files; failures and notes in the summary; the browser command
  (validation, the write, progress sheet, reload) and the viewer command
  (the unsaved-edits question, restamping).
- MinivuTests/MainMenuTests: the menu item and ⌘I (and the existing
  duplicate-shortcut check).
