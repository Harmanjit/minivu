# Feature notes: batch presets (G6), AVIF export (G14), Set Colour Label, multi-page tools (G17) (branch feature/batch)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section of each goal says where
it should.

## G6: batch actions and presets

### What the user can do

- **File > Save Edits as Preset…** (viewer only; after Revert to Saved, no
  key equivalent). Enabled while the photo on screen has edits, committed or
  in an open tool, and no sheet is up; disabled in the browser (nothing there
  implements it). An open tool's change is applied first, as Save As applies
  it. A sheet opens with:
  - **Name**, prefilled "<photo name> Edits" (extension dropped).
  - **Included**: the steps the preset will apply, in order, each with a note
    where it behaves differently on other photos (Auto Enhance "Measured
    again on each photo.", Crop and Perspective "as a fraction of its size",
    RAW Adjustments "RAW files only; other photos ignore it.").
  - **Left Out**: every step that can't travel, each with the reason (see
    "Portability" below). Never dropped silently.
  - The line by the buttons says when the name replaces an existing preset,
    or, in red, that nothing can be saved because no step travels (Save is
    then disabled). Save is the default button, Cancel the cancel button.
  - Saving over a preset made in Batch Convert replaces its edits only and
    keeps its output options.
  The photo's own edits are not changed.
- **Tools > Batch Convert…** gains:
  - A **Preset** row at the top: a popup (None, then the presets in name
    order) and an "ellipsis" menu (VoiceOver: "Preset Actions") with **Save
    Preset…**, **Rename Preset…** and **Delete Preset…**. Names are asked for
    in an alert with a text field; a name already used (any letter case)
    replaces that preset; Rename refuses a name another preset has (beep).
    Delete asks first ("This can't be undone").
    Choosing a preset saved from Batch Convert brings back every option of
    the sheet (format and options, Keep HDR, edits, size and orientation,
    watermark, destination including the chosen folder's bookmark, names).
    Choosing one saved from the viewer replaces the edits only. None clears
    the edits and leaves the rest. Changing an option afterwards doesn't
    change the preset until it is saved again.
  - An **Edits** section (after Format): the steps the batch applies to every
    image, each with its note and a minus button to leave it out of this
    batch (VoiceOver: "Remove <step>"); "None" when there are none. Then
    **Watermark**: a summary ("“© 2026”", the picture's file name, or None),
    **Add…**/**Edit…** and **Remove**. Add/Edit opens the viewer's own
    watermark inspector (text or picture, font, size, opacity, nine-place
    position, margin, tiling, spacing) as a sheet over the Convert sheet;
    Apply hands the watermark to the batch, Cancel leaves it, Reset returns
    to what it opened with. Choose Picture… uses the same open panel and
    read-only bookmark as the viewer, and refuses removable/network volumes.
  - **Keep HDR** (Format section, only for JPEG, HEIC and AVIF; on by
    default): HDR originals keep their highlights as an ISO gain map. Off,
    they are written SDR as before.
- **Tools > Batch Rename…** gains the same **Preset** row above the pattern:
  a preset keeps the pattern text, counter start/step/digits, find and
  replace and letter cases (the whole `RenamePattern`). None leaves the
  pattern as it is.
- Settings: none in Settings. Presets live in UserDefaults
  (`batchConvertPresets`, `batchRenamePresets`). The sheets still remember
  their last state as before, now including the edits, watermark and Keep
  HDR.

### Order of operations

Edits (a preset's) → turn → flip → resize (sized from the edited and turned
picture) → watermark → encode with the output options. The watermark goes
last so it is drawn crisply at the output size; its lengths are fractions
of the short side, so it covers the same share of every photo whatever the
resize. A watermark that is part of a preset's edits is applied in its
place among the edits.

### Portability (`MinivuRender/Batch/BatchEdits.swift`)

| Step | In a preset? | Why |
|---|---|---|
| Lighting, Colors, RGB, Curves, Levels, Grayscale, Sepia, Negative | yes | amounts |
| Sharpen, Blur, Noise Reduction | yes | radii in full-resolution pixels suit any photo |
| Drop Shadow, Frame, Bump Map, Sketch, Oil Paint, Lens, Vignette, Watermark | yes | fractions of the short side, normalised positions, pixel radii |
| Rotate (quarter turns and any angle), Flip | yes | no coordinates |
| Crop, Perspective | yes, with a note | stored normalised: the same part of each photo |
| Auto Enhance | yes, measured again on each photo | see below |
| RAW Adjustments | yes, with a note | the RAW engine's settings; ignored for non-RAW files (as `EditOperation.rawDevelop` already is) |
| Resize | left out | a size in pixels for this photo; Batch Convert's own Resize works from each photo's size |
| Canvas Size | left out | absolute pixels would give every photo the same canvas |
| Text and Shapes (annotations) | left out | placed on this photo's content |
| Clone Stamp, Healing Brush | left out | strokes painted on this photo's content |
| Red-Eye Removal | left out | spots on this photo's eyes |
| Remove Background | left out | the subject mask was found in this photo |

Steps that change nothing are dropped without a word (the document doesn't
record them either). Choosing a stored preset filters its edits through the
same rules again, so a hand-edited or future preset can't smuggle in a step
that would be mis-applied.

**Auto Enhance: re-analysed per image, decided and why.** The stored values
are a measurement of one photo (a tone curve, vibrance, a highlight/shadow
lift, a white balance shift for its histogram and faces). Applied to another
photo they are wrong more often than right: a curve that lifted a dark
interior crushes a bright beach. "Auto" means "measure this photo", so a
preset carries the step with its values cleared, and `BatchConverter`
measures each image exactly as the viewer does: the steps before it are
rendered at `EditRenderer.analysisPixelSize` (1024 px) from a small decode
(the codec's downscale; for RAW files the camera's embedded preview, never
a render of the sensor data, so no extra RAW engine work or slot), then
`AutoEnhance.analyse`. Cost: one small decode and render per file, tens of
milliseconds. A RAW file with no embedded preview gets no Auto Enhance
(the step is left out for that file).

### How it is built

- **Engine (MinivuRender).** `BatchConvertSettings` gains `edits`,
  `watermark` and `keepsHDR`, decoded with defaults when missing, so settings
  remembered by an older minivu load unchanged (tested).
  `operations(sourceSize:)` builds the order above. `BatchConverter`:
  - `prepare` reads the header, works out the operations, checks the memory
    budget, and measures Auto Enhance, all before any full decode.
  - Edits make every file go through `EditRenderer.renderForExport`, the
    renderer the viewer's Save and Save As use; there is no second renderer.
  - HDR: when Keep HDR is on, the original is HDR (gain map, PQ or HLG, a
    raster file) and the format holds a gain map (JPEG, HEIC, AVIF), the file
    renders through `renderHDRForExport` (half floats with the original's
    headroom, the path Save uses for gain-map photos) and is encoded with
    `ImageEncoder.encode(…, gainMap: true)`. Measured in tests: the decoded
    highlights stay above 2× SDR white after a colour edit and a Lanczos
    resize (the macOS 27 clamp workaround in `EditRenderer.lanczos` holds),
    for gain-map and PQ originals. PNG, TIFF and the rest stay SDR. RAW stays
    SDR (the batch's RAW settings keep `hdrRaw` off).
- **Presets (app).** `BatchStores.swift`: `NamedPreset<Value>` (id, name,
  value), `BatchConvertPreset` (edits + optional output settings; output nil
  for a preset saved from the viewer), and `PresetList<Value>` (observable;
  save/rename/delete, names compared ignoring case, sorted by name, cut to
  80 characters). Each change re-reads the store first, so a viewer's sheet
  and a Batch Convert sheet on another window never write back a list that
  lacks the other's preset (found by a test). A stored preset that can't be
  decoded is skipped; the rest load.
- **Sheets.** `BatchPresetViews.swift` holds `BatchPresetControls` (both
  batch sheets) and `BatchWatermarkSheet`. `EditsPresetSheet.swift` holds
  the viewer's sheet and its model; `Viewer/ViewerBatchPreset.swift` the
  command and validation (`validateBatchPresetAction`, in the viewer's
  validate chain). `EffectToolState` now takes an optional document, so the
  watermark inspector runs without a photo to preview on.
  `Watermark.starting()` is the shared starting watermark ("© <year>").

### Memory

- Before decoding, `BatchConverter.checkBudget` refuses (`DecodeError.tooLarge`,
  reported against that file; the batch goes on) a header past the export
  limit (`ImageDecoder.exceedsExportBudget`, a quarter of RAM; S3) and an
  output the operations would make past it: more than 32768² pixels, or
  pixels × 4 bytes (8 at 16 bits or for HDR half floats) over the limit.
  An enlarging resize, a frame or a shadow can grow the output past the
  original, which the decode check alone wouldn't see.
- RAW: the job's one-RAW-at-a-time slot and the editor's RAW slots apply as
  before; the Auto Enhance measurement never renders RAW data.

### Limits

- No preview of the preset on the first image in the Convert sheet (optional
  in the brief; not built).
- A preset saved in the viewer while a Batch Convert sheet is already open on
  another window appears in that sheet's popup the next time it opens.
- Crop and Perspective use the same fractions on every photo, which suits a
  series shot from one place, not photos of different framing.
- Resize and Canvas Size are left out rather than converted to relative
  sizes (Batch Convert has its own Resize; a relative canvas mode would need
  a new operation).
- RAW Adjustments carry absolute white balance (kelvin and tint), not "as
  shot"; across cameras the same numbers can look different.
- The watermark editor in the batch has no preview (there is no photo
  open); the viewer's Watermark tool previews.
- HDR is kept only as a gain map (JPEG, HEIC, AVIF); a PQ/HLG original
  becomes a gain-map file, not PQ/HLG.

### Where the docs should change

- DESIGN.md 4.7 "Editing": a paragraph "Batch presets" (the portability
  table's rule, Auto Enhance re-measured per image, `BatchEdits`).
- DESIGN.md 4.8 "Batch Convert": operations now run edits, turn, flip,
  resize, watermark; "always SDR" becomes "SDR, or HDR with a gain map for
  JPEG/HEIC/AVIF when Keep HDR is on"; the budget check of the output before
  decoding; presets stored under their own keys.
- DESIGN.md 4.8 "Batch Rename": named patterns.
- DESIGN.md 5, menu-shortcut table: File > Save Edits as Preset… (none).
  Tools section: presets in both sheets.
- DESIGN.md 8 "Known limits": the limits above.
- docs/wiki/Tools.md: Batch Convert (Preset row, Edits, Watermark, Keep
  HDR), Batch Rename (Preset row). docs/wiki/Editing.md: "Save Edits as
  Preset". docs/wiki/Limitations.md.
- Help pages: Tools.md (Batch Convert and Batch Rename presets, watermark,
  Keep HDR), Editing.md (Save Edits as Preset…, after Revert to Saved).
- Keyboard shortcuts page: nothing (no new keys).

## G14: AVIF export

### What the user can do

- **AVIF** appears in the Format popups of **Save As…**, **Batch Convert…**
  and the Shortcuts **Convert Images** action, after HEIC, only where ImageIO
  can write it (on this Mac, macOS 27, it can).
- Options as for HEIC: **Quality** slider (default 80), **Color profile**,
  **Keep metadata** and **Remove location** (default on), plus a
  **"10 bits per channel"** toggle (the existing "16 bits" option, titled
  with the depth the format holds: "16 bits per channel" for PNG and TIFF).
- **HDR**: Save As stays SDR, as for every format. Batch Convert (Keep HDR)
  and Convert Images keep HDR originals as an AVIF with an ISO gain map. An
  AVIF original with a gain map is saved in place with a new one, like HEIC.
- **Save (⌘S) of an AVIF** now writes in place where AVIF is writable (it
  used to fall back to Save As), with the usual confirmation; a PQ/HLG AVIF
  is tone mapped and the Replace alert says so, as for HEIC.

### Measured (macOS 27.2, `ExportAVIFTests`)

- `CGImageDestinationCopyTypeIdentifiers()` lists `public.avif`.
- 8-bit input writes 8-bit AVIF; 16-bit input writes **10-bit** AVIF
  (`kCGImagePropertyDepth` 10). 16-bit PQ/HLG input writes a 10-bit HDR
  AVIF, but minivu doesn't use that (no PQ export anywhere).
- `kCGImageDestinationEncodeToISOGainmap` writes an 8-bit base plus a gain
  map; decoded for HDR it has the content headroom written (4.0) and values
  well above 1. `EncodeToISOHDR` tone maps to SDR instead.
- EXIF, GPS and XMP are kept; IPTC only through its XMP mirror. ICC
  profiles (Adobe RGB tested) are embedded.
- **Quality 1.0 fails** (ImageIO tries a lossless encode and the finalize
  fails). `ImageEncoder.maximumQuality(.avif)` is 0.99, so the slider's 100
  writes the best lossy file.

### Design decisions

- Runtime check, not OS version: `ExportFormat.isWritable` asks ImageIO
  once a launch; menus use `ExportFormat.writableCases`. `format(for:)`
  answers nil for .avif where it isn't writable, so Save falls back to Save
  As there. A remembered AVIF (Save As's last format, Batch Convert's
  settings, a preset) on a Mac without the encoder falls back to JPEG.
- Shortcuts' format list is a compile-time literal (the metadata processor
  reads it), so AVIF is always listed; `Automation.convert` refuses it
  before converting anything where it isn't writable
  (`Failure.formatNotWritable`).
- `supports16Bit` is now `deepBitDepth != nil` (16 for PNG/TIFF, 10 for
  AVIF), so every path that renders 16-bit for the option (Save, Save As,
  Batch) feeds AVIF 16-bit pixels and ImageIO keeps 10.

### Where the docs should change

- DESIGN.md 3 / 4.7 "Saving": AVIF among the formats Save writes back and
  Save As offers (where ImageIO writes it); remove AVIF from "Files minivu
  can't write back"; the gain-map sentence becomes "JPEG, HEIC or AVIF".
  Known limits: Save As stays SDR (unchanged).
- docs/wiki/Editing.md Save As options table (AVIF row, 10 bits),
  docs/wiki/Tools.md Batch Convert formats, Shortcuts table.
- Help: Editing.md (Save As formats), Tools.md (Batch Convert, Shortcuts).

## Shortcuts: Set Colour Label

### What the user can do

A sixth action, **Set Colour Label**: Images; Label (None, Red, Orange,
Yellow, Green, Blue, Purple, Gray; default Red; None removes the label).
Returns the same files. It writes the file's standard Finder colour tag
exactly as Image > Label does (other tags kept, the XMP copy when "Write
ratings into files" is on), through `ColorLabelCommand.write`, which
`setLabel` now uses too.

### Checks (same as Set Rating, plus the file's own permission)

- `AutomationInput.make(originalsOnly: true)`: files on external, removable
  or network volumes fail the whole action before anything is labelled;
  files that arrive as data are refused.
- A label is written into the file's extended attributes, so unlike a
  rating it needs permission to change each file: `Automation.unwritableFiles`
  (access(2) W_OK, which the sandbox answers) is checked for every file
  first; one file minivu may not change and nothing is labelled
  (`Failure.filesNotWritable`, naming the files). A file whose tags can't be
  read or change while written fails as it runs (`Failure.labelFailed`,
  naming those; the others keep their label). No beep: the action reports
  failures itself.
- `openAppWhenRun` is false, as for the other background actions.

### Where the docs should change

- docs/feature-notes/sys.md's action table (and the docs written from it):
  add the row; the "COLOUR LABEL" marks in Automation.swift and
  AutomationIntents.swift are gone. Wiki Tools.md Shortcuts table; help
  Tools.md; Security-and-Privacy.md / Privacy.md: a shortcut can also set
  Finder colour tags on files minivu may change.
- Checks by hand (agents can't run Shortcuts): the action appears under
  minivu after rebuilding the app (make_app.sh's metadata step); labelling
  photos in Pictures works; photos passed for reading only (Desktop, not in
  the sidebar) fail with "minivu may not change these files".

## G17: multi-page files, Extract Pages, Image Strip, every page in Batch Convert

### What the user can do

All four work in the browser on `toolImages` (the selection, or every image
shown when nothing is selected), in the browser's order. The Tools menu
gains three items, none with a key equivalent (occasional commands that
open a sheet, like Contact Sheet; no shortcut was taken):

```
Batch Convert…            ⌥⌘B
Batch Rename…             ⇧F2
Extract Pages…            (new)
─────
Create Multi-Page File…   (new)
Image Strip…              (new)
Contact Sheet…
Montage Wallpaper…
Set as Desktop Picture
```

They are enabled when the folder has images, and disabled while a batch
sheet is up and while a batch, a copy or one of these jobs runs in the
window (`canPerformTools`). The viewer doesn't implement them (disabled
there).

- **Tools > Create Multi-Page File…** opens a sheet:
  - **Pages**: the images as a numbered list (a file with several pages
    says "12 pages", or "12 frames" for an animation format), reordered by
    dragging, **Move Up** / **Move Down** on the selected rows, or
    **Reverse**. **Include every page of multi-page files** (on by
    default): every page of a PDF or multi-page TIFF, and every frame of an
    animation, goes in; off, only the first.
  - **Format**: **Multi-Page TIFF** (default; Compression: None, LZW
    (default), PackBits), **PDF** (Page size: Same as Each Image (default),
    A4, US Letter; Margin in points for paper, default 36; Lossless (larger
    file), off by default; Quality slider, default 85), **Animated GIF**
    (Frame delay in seconds, default 0.5; Play: Forever (default) or a
    number of times; Frame size: long side in px, default 800, or Same as
    the first image; Background: Transparent (default) or a colour), and
    **Animated HEIC** where ImageIO lists `public.heics` (as GIF, without
    the Play row, plus Quality, default 80).
  - The line by the buttons gives the page count, or in red why the file
    can't be made (a setting out of range; an animation whose frames would
    not fit in memory). **Save…** (default button) ends the sheet and asks
    for the file in a save panel (the first image's name with the format's
    extension, in the folder shown); the panel asks before replacing. A
    progress sheet with Cancel follows; the new file is selected when it is
    in the folder shown. Pages that couldn't be read are left out and
    listed afterwards ("1 page was left out.").
- **Tools > Extract Pages…** opens the Batch Convert sheet in its Extract
  Pages mode ("Extract Pages from 3 Files"; button **Extract**): no Preset
  row and no Edits section; a **Pages** section with **All pages**
  (default) or **A range** (From / To, counted from 1). Each page of a PDF
  or multi-page TIFF, or each frame of an animation (GIF, APNG, WebP,
  animated HEIC), is written as a file of its own in the chosen format
  (PNG by default, every Batch Convert format and option available),
  with resize, turn and flip, destination, existing-file policy and
  names exactly as in Batch Convert. Names default to the pattern
  `{name}-{page}` ("scan-03.png"). Files with one page are skipped ("It
  has only one page."), as are files shorter than the range's start. Its
  settings and pattern are remembered apart from Batch Convert's.
- **Batch Convert…** gains a **Pages** section after Format: **Multi-page
  files: First page only** (default, as before) or **Every page**. Every
  page writes all pages into one file for TIFF (pages) and GIF (frames,
  keeping the original's delays and loop count), and one file per page,
  numbered, for every other format; the footnote says which.
- **Tools > Image Strip…** opens a sheet: the same order list; **Arrange**:
  Side by Side (default), One Above Another, Grid; **Height** / **Width** /
  **Cell height** in px (default 1080); **Columns** (grid, default 3);
  **Spacing** and **Margin** in px (default 0); **Background**: white by
  default, a colour, or Transparent where the format keeps alpha; **File**:
  any writable format but ICO, with Quality, Color profile, TIFF
  compression and 16/10 bits as in Save As. The line by the buttons shows
  the strip's size ("5,120 × 1,080 pixels") or why it can't be made.
  **Save…** asks for the file (the first name plus " Strip"), makes it with
  progress and Cancel, selects it, and opens it in the viewer.
- Names: a new token **`{page}`** (also `{frame}`): the page or frame
  number from 1, zero-padded to the file's page count. Offered in the
  Insert Token menu of Batch Convert and Extract Pages; Batch Rename
  refuses it as an unknown token (it renames whole files). An output that
  is one page of a file and whose pattern lacks `{page}` gets "-NN" after
  its name, so pages of one file never ask for one name.
- Settings: none in Settings. UserDefaults keys `extractPagesSettings`,
  `extractPagesPattern`, `multiPageSettings`, `imageStripSettings`; Batch
  Convert's remembered settings gain `pages` (missing in older settings:
  First page only).

### Design decisions and why

- **Measured on macOS 27 (ImageIO writing):** `public.heics` is a
  destination type; `public.avis` isn't, and a `public.avif` destination
  for more than one image can't be created, so **animated AVIF is not
  offered** (pinned by `MultiPageTests.noAnimatedAVIF`). Animated HEIC
  keeps every frame's delay but the last, which reads back as the one
  before it, and records no loop count (files read back as playing once),
  so the sheet offers no loop choice for HEIC and says so (pinned by
  `MultiPageTests.animatedHEIC`, so a change in ImageIO shows).
- **Memory: one page at a time where ImageIO allows it.** ImageIO's own
  multi-page TIFF keeps every image and decodes them all at the end (eight
  12 MP pages: 386 MB over the start, the same with lazily decoded pages
  from files). So minivu encodes each TIFF page by itself with ImageIO
  (compression, profile) and joins them with **`TIFFPageWriter`**
  (MinivuCore/Export), which appends each page's bytes with its offsets
  moved and links the directories: one decoded page in memory at a time.
  It follows the same tags as `TIFFScrubber` and refuses rather than guess
  (BigTIFF, unknown types, past 4 GB). **PDF** goes through a Core
  Graphics PDF context, which writes each page as it ends; JPEG pages are
  encoded first and handed over as JPEG data, embedded unchanged (eight
  12 MP pages with a flat footprint, the file the size of the JPEGs).
  **GIF and animated HEIC** encoders keep every frame until finalize
  (16 frames of 1000 × 750 px peak at 133 MB as GIF; a 12 MP HEIC frame
  adds about 48 MB as it is added), and there is no way round that in
  ImageIO; so frames are made at the frame size (default 800 px) and the
  whole animation is checked before anything is decoded: frames × width ×
  height × 4 × 3 must fit the export limit (a quarter of RAM;
  `MultiPageBuilder.checkBudget`). The sheet shows the refusal live.
- **Writes:** the multi-page file and the strip are made at
  `SafeFileWriter.temporaryFile` (a hidden sibling, or the volume's
  item-replacement folder when the save panel granted only the file) and
  put in place with `SafeFileWriter.place` inside
  `FileWriteQueue.enqueue(replacing:)`, so the long work doesn't hold the
  queue and only a whole file ever appears; `OwnWrites` and
  `SavePresenter.didWrite` as for Save. Batch Convert's every-page files
  are written to a hidden sibling and committed with the new
  `BatchFileWriter.commit(fileAt:)` (same exclusive rename, policies and
  Replace-to-Trash as before). Cancel is checked before every page; a
  cancelled file is deleted, so only whole files remain.
- **Extract Pages is Batch Convert.** Splitting is converting with one
  output per page, so it reuses the planner (clashes numbered, existing
  files by policy, Replace confirmed), the job (2 at a time, 1 RAW, progress,
  Cancel, summary) and the sheet. The planner reads each source's page
  count from its header only when pages are asked for. **A page never
  replaces its own original**: it is numbered like a clash with another
  source ("scan-2 2.png"), even under Replace, and never appears in the
  Replace question.
- **Every page in Batch Convert:** only TIFF and GIF hold several pages
  among Batch Convert's formats. HEIC is left out on purpose (an animated
  HEIC is a different kind of file from the photo HEIC a batch is asked
  for). Batch Convert has no PDF output format (it never had; ExportFormat
  has none), so PDFs are handled as sources; a PDF output is made with
  Create Multi-Page File.
- **No metadata in multi-page outputs** (TIFF, PDF, GIF, HEIC, and Batch
  Convert's every-page files): pages come from different files, and one
  file's EXIF and location on the whole document would be wrong. TIFF
  pages keep their own colour profile (or Batch Convert's chosen one).
  Single-page outputs (Extract Pages, every page as JPEG) keep metadata
  as Batch Convert does.
- **Image strip: saved, then opened in the viewer (decided).** An unsaved
  document in the viewer was the other choice, but every viewer document
  is a file (Save, Revert, marks, info panel, filmstrip, the change
  watcher all work from its URL), and a strip of 20 photos up to 32768 px
  long would sit in memory only until saved. Saved first, it is safe at
  full resolution, opens like any photo (shown fitted to the 16384 px
  texture limit, as any large image), and can be edited non-destructively.
  The strip is one bitmap (8 bits, 16 with the 16-bit option, Display P3)
  checked before drawing against 32768 px a side (as Resize and Batch
  Convert) and the export limit; each picture is decoded at about its
  frame's size by the codec and drawn in turn (strip + one picture in
  memory). Grid cells take the pictures' middle aspect ratio; pictures are
  fitted and centred in them.
- **PDF page size "Same as Each Image"** is the picture at the resolution
  its file records (72 dpi when none, as Preview does), at most 14,400 pt
  a side (the PDF limit). Paper sizes turn to the picture's shape and fit
  it inside the margin, enlarging small pictures as a print would.
- **Animation frames** are fitted into one canvas (the first picture fitted
  into the frame size, never enlarged), centred over the background. An
  animation's own frames keep their delays; other pictures get the frame
  delay. Delays below 20 ms are refused (browsers show ≤ 10 ms at 100 ms).
- **PDF page images** (Extract Pages, every page) render as the viewer
  renders a PDF page at full resolution: actual size at 144 dpi, at least
  4096 px and at most 16384 px on the long edge.
- No new Core Image operation and no new edit operation, so nothing was
  added to `hdrHighlightsSurviveEveryKindOfTool`; every page and strip
  output is SDR (an HDR original's page is ImageIO's SDR rendition).
- `CancellationFlag` moved from the app to MinivuCore (public), so the
  engine's jobs can check it.

### Limits

- Animated GIF and HEIC are limited by memory as a whole (see above);
  TIFF and PDF only by one page.
- Animated HEIC: no loop count, and the last frame's delay is the one
  before it (ImageIO, macOS 27). No animated AVIF.
- Multi-page outputs carry no metadata; Batch Convert's every-page option
  writes multi-page output only for TIFF and GIF.
- A PDF's pages are rendered, not the images embedded in them extracted.
- Multi-page TIFFs are classic TIFF: at most 4 GB (refused past it).
- The image strip opens in the viewer after saving; it is never an unsaved
  document. No live preview of the strip or of the multi-page file in the
  sheets (the size and page count are shown).
- Not available from the viewer or Shortcuts. (A Batch Convert preset
  saves the Pages choice with the sheet's other options.)

### Where the docs should change

- DESIGN.md 3 "Formats": a line that minivu writes multi-page TIFF, PDF,
  animated GIF and animated HEIC (where ImageIO can), not animated AVIF.
- DESIGN.md 4.5 "Memory": the multi-page rule (one page at a time for TIFF
  via `TIFFPageWriter` and for PDF; GIF/HEIC frames checked as a whole at
  frames × w × h × 12 bytes against the export limit; strips one bitmap
  plus one picture, checked against 32768 px and the export limit).
- DESIGN.md 4.8 "Tools": a "Multi-page files, Extract Pages, Image
  Strip" paragraph (the decisions above: `PageSequence`, `MultiPageWriter`,
  `MultiPageBuilder`, `TIFFPageWriter`, `ImageStripLayout`/`Renderer`, the
  temporary-file-then-place write path); "Batch Convert": the Pages
  setting, `BatchOutput.pages`, `commit(fileAt:)`, pages never replace
  their original, Extract Pages as a mode of the sheet. "Batch Rename":
  the `{page}` token exists but is refused there.
- DESIGN.md 5 "User interface", Tools menu table: Extract Pages…, Create
  Multi-Page File…, Image Strip… (no shortcuts); the Batch Convert sheet's
  Pages section.
- DESIGN.md 8 "Known limits": the limits above.
- docs/wiki/Tools.md: sections for Create Multi-Page File, Extract Pages
  and Image Strip; Batch Convert's Pages option; the `{page}` token in the
  rename token table. docs/wiki/Limitations.md: HEIC loop/last delay, no
  animated AVIF, no metadata in multi-page files.
- Help pages: Tools.md (the three new commands, Batch Convert's Pages
  option, `{page}`).
- Keyboard shortcuts page: nothing (no new keys).

## Tests

- MinivuCoreTests/ExportAVIFTests (skipped where AVIF isn't writable):
  round trip and quality, quality 1 clamped, 10 bits, metadata and Remove
  location, colour profile, HDR gain map round trip, a gain map refused for
  PNG. ExportFormatTests: writability from ImageIO's list, capabilities,
  extensions.
- MinivuRenderTests/BatchPresetEngineTests: portability, old settings
  decoding, the order of operations, edits and the watermark rendered, Auto
  Enhance measured per image, HDR gain maps for JPEG/HEIC/AVIF (highlights
  measured after edits and resize; off and PNG stay SDR; PQ originals), the
  output budget.
- MinivuTests/BatchPresetWindowTests: preset list save/rename/delete and two
  lists of one store, old settings and unreadable presets, Batch Convert
  presets (full and edits-only, None, remove a step), the batch watermark
  sheet (cancel, picture, apply, identity), a browser batch with edits and a
  watermark, Batch Rename presets, Save Edits as Preset from the viewer.
- MinivuTests/AutomationTests: Convert Images to AVIF, Set Colour Label
  (tags kept, None, read-only file refused, data-only refused, volume
  refused, labels list). MainMenuTests: the new File item.
- G17: MinivuCoreTests/MultiPageTests (TIFF pages joined in order with
  their sizes, compressions and profiles; refusals past 4 GB and of
  non-TIFF pages; reading TIFF, PDF, GIF and single files as pages; page
  ranges; PDF page sizes and lossless vs JPEG; GIF frame size, delays and
  loops; animated HEIC as measured; no animated AVIF; builder order,
  every page and unreadable files; Cancel leaves no file for TIFF, PDF and
  GIF; the animation budget; settings decoding; strip layouts, rendering,
  transparency, Cancel and budget; the `{page}` token and Batch Rename's
  refusal). MinivuRenderTests/BatchPagesEngineTests (old settings load;
  first / every / separate pages planned into outputs and names; a page
  never replaces its original; a page decoded and an every-page TIFF;
  every-frame GIF timing; Cancel; the GIF budget).
  MinivuTests/MultiPageWindowTests (Extract Pages from the browser with a
  range and its own remembered settings; Batch Convert's every page as
  JPEG and TIFF; Cancel leaves whole files; Create Multi-Page File's sheet,
  order and save; pages left out and reported; the sheet's checks; order
  moves; Image Strip's sheet, save and opening). MainMenuTests and
  BatchRenameWindowTests: the new Tools items and their validation.
