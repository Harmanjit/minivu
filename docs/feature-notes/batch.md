# Feature notes: batch presets (G6), AVIF export (G14), Set Colour Label (branch feature/batch)

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
