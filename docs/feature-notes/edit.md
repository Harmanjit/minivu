# Feature notes: editing (branch feature/edit)

Notes for the documentation pass. Nothing here is user-facing yet; the
sections at the end of each goal say which parts of DESIGN.md, the wiki
and the help pages should change.

## G11: more Core Image tools

Five new tools, each a new `EditOperation` case rendered by `EditGraph`,
one undo step when applied, with its own undo title ("Undo Auto Enhance",
"Undo Noise Reduction", "Undo Vignette", "Undo Perspective", "Undo Canvas
Size"). All are in the viewer's tools panel and the Image menu, enabled
whenever the image on screen can be edited. None has a key equivalent:
every plausible letter is taken (⌥⌘C is Colors, ⌥⌘I Resize, ⌘K Crop), and
the existing effects have none either. The menu-shortcut table in DESIGN.md
section 5 needs the new rows with "none".

All five keep HDR: each is a case of `hdrHighlightsSurviveEveryKindOfTool`
(Tests/MinivuRenderTests/EditRendererTests.swift), preview and full
resolution.

### Auto Enhance

- **What the user does.** Image > Adjust > Auto Enhance, or Auto Enhance in
  the tools panel's Adjust group. One click: no inspector. The command is
  disabled for the moment it takes to measure the image (tens of
  milliseconds); a photo that needs nothing gets a beep and no step.
- **How.** `EditRenderer.autoEnhancement(for:)` renders the committed edit
  at 1024 px (`renderForAnalysis`), off the main thread, and asks
  `CIImage.autoAdjustmentFilters` (red-eye off). The suggested filters and
  their numeric inputs are stored in the operation (`AutoEnhance`, a list of
  name + numbers + vectors), so every render, preview or saved file, and the
  document after a reload, applies exactly the same adjustment; nothing is
  re-analysed per render. A length input (`inputRadius`) is stored in
  full-resolution pixels and scaled per render.
- **Design decisions.** Only an allow-list of filters is ever instantiated
  from a document (`AutoEnhance.knownFilters`: face balance, vibrance, tone
  curve, highlight/shadow, temperature and tint), each measured to pass HDR
  values through (the suggested tone curve asks to extrapolate past its last
  point). A filter a later macOS suggests is dropped until checked. If the
  document changes while the analysis runs, or the viewer moves on, the
  result is dropped.
- **Limits.** The analysis sees an 8-bit SDR rendering, so on an HDR photo
  it judges the SDR rendition; the adjustment itself keeps HDR. Running it
  twice stacks two steps.

### Noise Reduction

- **What the user does.** Image > Adjust > Noise Reduction…, or the tools
  panel. Sliders: Level 0–100% (default 50%) and Sharpness 0–2 (default
  0.4). Previews at once, like Sharpen and Blur.
- **How.** Not `CINoiseReduction`: on macOS 27 it clips every value to 1
  in the edit renderer (measured: an HDR 4.0 came out 1.0 in preview and
  full resolution alike, whether or not the edges were clamped). Instead a
  bilateral filter of our own (`effectsDenoise` in EffectsKernels.swift),
  on encoded values: neighbours are weighted by distance and by colour
  difference, so differences below the range sigma (Level × 0.1 encoded
  units) average away while edges stay. The same loop computes a plain
  blur; the edges alone (bilateral minus blur) are added back Sharpness
  times, so sharpening doesn't amplify the noise.
- **Scale.** The spatial window (1–3 full-resolution pixels sigma, at most
  13 × 13 taps) scales with the working image like a blur radius; the range
  sigma is a property of values and doesn't. A proxy has averaged most of
  its noise away, so at screen size the filter does little, which matches
  how the full-resolution result looks at that size.
- **A macOS 27 finding worth recording.** A `clampedToExtent()` image read
  by a sampling general kernel (not only Lanczos, bicubic and the unsharp
  mask) also came back clipped to 1. The denoise kernel therefore holds its
  sample positions to the image itself. DESIGN.md "Core Image on macOS 27"
  should say this, and the bump map and sketch (which pass a clamped image
  to general kernels) may lose HDR highlights for the same reason; they are
  not in the HDR test (only Drop Shadow stands for "effect").
- **Limits.** The full-resolution render of a 24 MP photo reads up to 169
  texels a pixel; it runs in the background lane like every full render.

### Vignette

- **What the user does.** Image > Effects > Vignette…, or the tools panel's
  Effects group. Sliders: Amount −100…100 (default 50; positive darkens the
  edges, negative lightens them), Radius 0–100% (where the falloff starts,
  default 50%) and Feather 0–100% (how far it runs, default 50%).
- **How.** A gain in linear light, up to two stops at the corners at Amount
  100, easing in with smoothstep on an ellipse fitted to the image
  (`effectsVignette`). Radius and feather are fractions of the
  centre-to-corner distance, so the proxy matches the saved file with no
  scaling. Core Image's `CIVignetteEffect` clips to 1 in this context
  (measured), hence the kernel.

### Perspective

- **What the user does.** Image > Perspective…, or the tools panel's
  Adjust group. Four white handles sit on the image's corners over the
  uncorrected picture, with a thirds grid inside the quadrilateral and the
  image outside it dimmed. Drag each handle onto a corner of something
  that should be rectangular. **Auto** asks Vision for the most prominent
  rectangle (a document, a screen, a window, a building's face) and moves
  the handles there; the footnote says whether one was found. **Show
  result** previews the correction (the handles hide meanwhile). The
  inspector also has numeric across/down fields for each corner, in percent,
  which is how VoiceOver users set them; the overlay itself is labelled
  "Perspective corners". Return or a double-click inside applies; Esc
  cancels.
- **How.** `PerspectiveQuad` stores the four corners normalised (top-left
  origin, like a crop). The output size is the longer of each pair of
  opposite edges, in pixels of the input, so nothing along an edge is
  squeezed. The graph warps with a projective map (Heckbert's closed form
  for square to quadrilateral) in a Core Image warp kernel, bilinear
  samples. A crossed or folded quadrilateral is an identity (Apply commits
  nothing); its outline turns red. Changes geometry.
- **Limits.** The true proportions of the rectangle photographed can't be
  known without the focal length; the longer edges are the usual estimate.
  Corners can't go outside the image (no "pull the canvas out" as
  Photoshop's perspective crop allows). Bilinear sampling softens strong
  corrections a little.

### Canvas Size

- **What the user does.** Image > Canvas Size…, or the tools panel. A sheet
  like Resize: width and height in pixels or percent of the image, a 3 × 3
  anchor (each square has a VoiceOver label, "Anchor: Top Left"), a fill
  colour or Transparent, the current and new size. A smaller canvas crops
  the image about the anchor (the sheet says so). Apply is disabled while
  the size is unchanged.
- **How.** `CanvasSize` stores the exact output size, the anchor and the
  fill (alpha 0 is transparent). The image's offset is worked out in
  full-resolution pixels and scaled, so the proxy places it where the saved
  file does; an odd spare pixel goes to the right or bottom. Changes
  geometry. Sizes are capped at 32768 px, as Resize is.
- **Limits.** Stored in absolute pixels, so as a Batch Convert preset it
  would give every photo the same canvas; a relative mode (add N px or N%)
  would suit batches better.

### DESIGN.md, wiki and help changes for G11

- DESIGN.md 4.7, **Operations / Effects**: list the new operations and that
  Auto Enhance stores measured filter values (never re-analyses per
  render); the allow-list rule; vignette, denoise and perspective kernels
  join the runtime-compiled kernel list (EffectsKernels).
- DESIGN.md 4.7, "Core Image rules learned the hard way" and 7 "Core Image
  on macOS 27": `CINoiseReduction` and `CIVignetteEffect` clip to 1; a
  `clampedToExtent()` read by a sampling general kernel clips too; hold
  sample positions in the kernel instead.
- DESIGN.md 5, menu-shortcut table: Image > Canvas Size…, Perspective…,
  Adjust > Auto Enhance, Noise Reduction…, Effects > Vignette… (all
  "none").
- docs/wiki/Editing.md: "The tools panel" (new rows), "Rotate, flip, resize
  and crop" (Canvas Size, Perspective), "Tone and colour" (Auto Enhance,
  Noise Reduction), "Effects" (Vignette).
- Help pages: Editing.md "The tools" (Canvas Size, Perspective, Auto
  Enhance, Noise Reduction); Effects.md "Effects" (Vignette). The keyboard
  shortcuts page needs nothing (no new keys).

## G6 (part): Watermark

- **What the user does.** Image > Watermark… (below Text and Shapes), or
  Watermark in the tools panel's Draw group. An inspector with Kind: Text or
  Image.
  - Text: the text (defaults to "© " and the year), font family (the
    drawing tool's font menu), weight, colour.
  - Image: Choose Picture… opens an open panel as a sheet; the chosen
    file's name shows. Files on removable or network volumes are refused
    with a beep, as everywhere in minivu.
  - Placement: Size (1–100% of the photo's short side; the text's size or
    the picture's height; default 5%), Opacity (default 60%), Position (a
    nine-place grid, default bottom right, VoiceOver labels "Position:
    Bottom Right"), Margin (0–25% of the short side, default 3%), Tile
    across the photo, and Spacing between tiles (0.2–5 watermark heights).
  It previews at once and applies as one step, "Undo Watermark".
- **How.** `Watermark` is a plain Codable value. The stamp (one line of
  text with Core Text, or the picture) is drawn with Core Graphics into a
  small 8-bit bitmap at exactly its size on the working image, then
  composited source-over: wherever it is transparent the photo's values
  pass through untouched (HDR included) and under it they are only scaled.
  Every length is a fraction of the short side rounded to whole working
  pixels, so preview and full resolution show the same watermark in the same
  place (tested within two proxy pixels, at the default sizes and at the
  sliders' far ends). The bitmap holds the stamp alone: tiling pads it with
  transparent Core Image pixels to the cell (stamp plus gap) and repeats
  that with `CIAffineTile`, anchored at the chosen position, so the widest
  spacing costs no more memory than the narrowest (an earlier version drew
  the gap into the bitmap, about 3 GB for a 6000 x 4000 photo at size 100%
  and spacing 5x). A stamp too big for the photo (a long text at a large
  size) is shrunk to fit inside the margins, by the same fraction at every
  scale (`WatermarkGraph.Layout`, measured again up to four times because
  fonts track small sizes wider), so the saved file never loses a watermark
  the preview shows and the bitmap is never larger than the photo.
- **The picture's file.** Stored as a read-only security-scoped bookmark
  (`.withSecurityScope` + `.securityScopeAllowOnlyReadAccess`, falling back
  to a plain bookmark outside the sandbox) plus the file name, so a saved
  document or a Batch Convert preset can render it in a later session. The
  app-scoped bookmark entitlement the app already has covers this; no new
  entitlement. Rendering resolves the bookmark quietly (no UI, no
  mounting), opens access only for the decode, checks the volume policy,
  and decodes with ImageIO's thumbnail path at the height drawn (rounded up
  to a power of two, at most twice the size drawn), cached for the last six
  pictures so a dragged slider doesn't reread the file. A missing file draws
  nothing rather than failing the render.
- **For Batch Convert (a later wave).** Put a `.watermark(Watermark)` in
  the operations Batch Convert renders through `EditGraph`; nothing else is
  needed. The inspector's state type is the generic `EffectToolState`, so a
  preset editor can reuse `WatermarkInspectorView` with a state of its own.
- **Limits.** One line of text, no rotation, no outline or shadow for
  legibility over busy photos. A text or picture too large for the photo
  is shown smaller than the Size slider says (fitted inside the margins). Tiles form a straight grid (no diagonal or
  staggered rows). The picture is drawn at 8 bits, so an HDR logo is shown
  SDR.
- **DESIGN.md, wiki and help changes.** DESIGN.md 4.7 "Effects, drawing and
  retouching": the watermark's rendering and its bookmark; 5, the menu
  table row (Image > Watermark…, none); 4.8 Batch Convert once the later
  wave uses it. docs/wiki/Editing.md "Text and Shapes" neighbour section
  "Watermark"; docs/wiki/Security-and-Privacy.md: the watermark keeps a
  read-only bookmark to the chosen picture. Help: Effects.md, a new
  "Watermark" section after "Text and Shapes"; Privacy.md, the bookmark.

## G10: RAW Adjustments

DESIGN.md says minivu is not a RAW developer; Harman has now asked for a
light set of RAW controls, so this widens that scope on purpose. They are
the RAW engine's own settings, nothing more: no curves, masks, profiles or
lens corrections of minivu's own.

- **What the user does.** Image > Adjust > RAW Adjustments… (the first
  item, above a separator), or RAW Adjustments in the tools panel's Adjust
  group (symbol `camera.aperture`). Enabled only for camera RAW files
  (`ImageKind.raw`); a RAW file whose camera Apple's RAW engine doesn't
  know beeps when the tool is asked for. No key equivalent. The inspector:
  - Exposure, −4…+4 EV (default 0, on top of the camera's baseline).
  - Boost, 0–100% (default 100%): how much of the engine's contrast curve
    is applied; lower is flatter.
  - Recover highlights, a toggle (on by default), shown only on macOS 26
    and later and only when the engine supports it for the camera.
  - White Balance: Temperature, 2000–20000 K on a logarithmic slider, and
    Tint, −150…+150; both start at the white balance the camera recorded.
  - Noise Reduction: Luminance Noise and Color Noise, 0–100%, starting at
    what the engine picks for the photo (it depends on the ISO); each shown
    only when the engine supports it for the camera.
  The tool opens on the settings in effect (the last RAW step's) or, with
  none, the camera's, and shows the engine's rendering at once, so the
  canvas switches from the camera's embedded JPEG (if that is what the
  viewer showed) to what the sliders change. Reset and a slider's
  double-click return to the camera's settings ("as shot"); Cancel returns
  to what was there before. Apply commits only a change, as one step,
  "Undo RAW Adjustments". Settings can be changed again later: reopening
  the tool starts from them, and the new step replaces them.
- **How: an operation that changes the source.** `EditOperation.rawDevelop
  (RawDevelop)` stores every setting the tool shows (nil only for settings
  the engine can't make for that camera, or a document from a later
  version). `EditGraph` passes the image through it untouched; instead,
  every `EditSource` (the decoded original) and `EditProxy` records the
  settings it was developed with (`develop`, nil for a decode by the
  viewer's rules), and each render compares them with what its operations
  ask for, `RawDevelop.inEffect` (the last RAW step's; files that aren't RAW
  ignore the step):
  - a full-resolution render, or any render once no RAW step is left (all
    undone), first makes the original again with those settings (the
    engine at full size, or the viewer's rules for none) and puts it on the
    document in place of the old one, which frees it; stages made from the
    old one go too. The two lanes share that decode
    (`EditRenderer.remadeSource`, `EditDocument.sourceRemake`): after an
    undo past the last RAW step both need the plain original, and the
    second waits for the first's decode instead of running its own. A
    render that finishes after the original was replaced keeps neither the
    stage nor the proxy it built from the old one, so no second full-size
    original stays in memory;
  - a preview whose original doesn't match (the tool's sliders moving)
    doesn't wait for that: the engine develops the file at exactly the
    preview's size through `CIRAWFilter.scaleFactor`, resampled with the
    HDR-safe Lanczos to the exact working size if it is a pixel off, and
    that image becomes the proxy for this and later previews with the same
    settings. A proxy is only used when its settings match.
  - So undo and redo are just a change of operations; the renders after
    them bring the original back in line. Save As renders from an original
    with the committed settings, developing one if the document's doesn't
    have them (`exportSource`); a document prepared again after a release
    develops straight away. Analysis renders (Auto Enhance, red-eye,
    perspective, the subject) develop first too (`source(for:showing:)`).
- **Live preview.** The file is opened in the engine once per document and
  kept (`RawDevelopFilter`, on `EditDocument.rawFilter`, freed with the
  document's original): opening a 24 MP NEF took 130–300 ms on M4, and a
  half-size render after it about 110 ms, while the same filter given new
  settings rendered again at half size in 65–78 ms. Draft mode measured no
  faster at those sizes, so it is off. Slider frames coalesce in the
  preview lane as for every tool, so a drag runs at roughly 10–15 updates a
  second at screen size.
- **HDR.** Developed images follow the viewer's RAW settings exactly as the
  first decode does: with "Render RAW files with extended dynamic range" on
  (and HDR display on), the engine renders with
  `extendedDynamicRangeAmount` from the RAW headroom setting into half
  float, and each developed proxy or original measures its own peak for
  the canvas's headroom (exposure +1 measured a peak of 2.16 against 1.27).
  With it off the result is SDR, as the viewer's renders are.
- **Memory.** Every engine render the editor makes (developed proxies and
  originals, and the existing full-size RAW decode for editing) takes one
  of the editor's RAW slots (`RawRenderer.withEditRenderSlot`, policy
  `concurrentEditRenders(physicalMemory:)`: one at a time on Macs with 8 GB
  or less, two elsewhere so a preview needn't queue behind a full render)
  and runs on the RAW Core Image context, so `RawRenderer.memoryTarget`'s
  512 MB limit applies on small Macs. Developed originals are half float
  (192 MB for 24 MP, twice an 8-bit SDR render), since later edits work in
  half float anyway. On Macs with 8 GB or less the viewer's RAW renders
  (`ImageLoader`, which allows one of its own) take the editor's slot too
  (`RawRenderer.withViewerRenderSlot`, policy
  `viewerSharesEditSlot(physicalMemory:)`), so the whole app renders one RAW
  at a time there: opening RAW Adjustments while the viewer is still
  rendering the photo waits for it, and the viewer's next photo waits for
  an edit render. Batch Convert renders RAW files through the editor's
  path, so it shares the slot as well. On larger Macs the viewer keeps its
  own slot, so a photo shown while the editor renders doesn't wait.
  `RawDevelopFilter` hands out the engine's image under a lock and renders
  it outside, which is right only if that image keeps the settings it was
  made with; `oneFilterRendersTwoSettingsAtOnceWithoutMixingThem` pins it
  (eight renders of two settings at once from one filter, on a Mac with
  two editor slots, each match a render alone), so a preview needn't wait
  behind a full render of the same file.
- **Limits.** Save can't write RAW files (as before), so the settings reach
  a file through Save As (or Copy). The engine's white balance picker
  (`neutralLocation`), sharpness, local contrast, detail, moiré and lens
  correction aren't offered. The canvas shows the engine's rendering while
  the tool is open even for a document that used the camera's embedded
  JPEG, and a RAW step makes every later render use the engine. If the
  engine's size or framing differs from the embedded preview's by a few
  pixels (the default "preview or render" plan edits the camera's
  full-size embedded JPEG), the first developed original changes the
  document's size by that much, and undoing the last RAW step brings the
  JPEG's size back; normalised operations follow, operations stored in
  absolute pixels (Canvas Size, Resize) keep their pixels and so sit a few
  pixels off. The RAW step still reports `changesGeometry == false`, since
  the change depends on the camera, not the settings. Fixing it would mean
  making every RAW original with the engine once a RAW step exists, or
  storing absolute operations relative to the size they were made at. The open filter's own memory (the RAW data it holds) stays while
  the document is edited. A full-resolution render while zoomed in during
  a drag costs a full development (about 0.6 s for 24 MP) each time the
  slider settles.
- **DESIGN.md, wiki and help changes.** DESIGN.md 1: the non-goals should
  say minivu is not a full RAW developer but offers the RAW engine's own
  settings. 4.2 (decode path): a RAW being edited can be developed with the
  RAW tool's settings. 4.5 (memory): the editor's RAW slots
  (`concurrentEditRenders`) beside the viewer's, and the kept
  `RawDevelopFilter`. 4.7 Editing: a new paragraph "RAW settings" (the
  operation that changes the source, developed proxies, how undo and Save
  follow; see `EditRenderer`'s documentation), and the operation list. 5,
  the menu-shortcut table: Image > Adjust > RAW Adjustments… (none).
  docs/wiki/Editing.md "Tone and colour" (or a new "RAW files" section),
  "The tools panel"; docs/wiki/Motivation.md's "not a RAW developer" line;
  docs/wiki/Limitations.md (what is and isn't offered, Save As only).
  Help: Editing.md "The tools" (RAW Adjustments, RAW files only); Settings.md
  could note that the HDR RAW setting also governs the RAW tool.

## G8: Remove Background and Copy Subject

- **What the user does.**
  - Image > Remove Background… (after Watermark…), or Remove Background in
    the tools panel's Retouch group (symbol `person.and.background.dotted`).
    The inspector opens at once with "Finding the subject…"; when Vision
    has found it the cut-out previews ("Subject found"), and otherwise it
    says "No subject found" with a hint, and Apply does nothing. Background:
    Transparent (default) or a colour well (opaque colours). Apply commits
    one step, "Undo Remove Background"; Reset returns to transparent.
  - Edit > Copy Subject (after Copy): the subject of the picture on screen,
    an open tool's change included, cut out and cropped to it, goes on the
    clipboard as PNG and TIFF; the document is not changed. Disabled while
    it works; beeps when there is no subject or the render fails, leaving
    the clipboard as it was. Enabled whenever Copy is in the viewer;
    disabled in the browser (nothing there implements it).
  - No key equivalents. ⌥⌘C is Colors; ⇧⌘C is free in the menus and
    could become Copy Subject if wanted, but none of the editing tools has
    a key, so none was added.
- **How.** `VNGenerateForegroundInstanceMaskRequest` (on device, macOS 14+;
  minivu needs 15) runs on a rendering of the picture as it stands at the
  operation's place, at most 1536 px (`EditRenderer.subjectPixelSize`):
  Vision's own instance mask is 512 px square (measured), so three times
  that keeps everything it has. Every instance counts (a person and their
  dog together). `generateScaledMaskForImage` gives coverage at the
  rendering's size, which is stored in the operation as an 8-bit greyscale
  PNG (`SubjectMask`, with the subject's bounding box). The document keeps
  the last answer per operation list (`subjectMaskCache`), so reopening
  the tool or copying after looking costs nothing, and no render ever runs
  Vision: the graph decodes the PNG once (cached in the mask object, shared
  by every copy of the operation) and stretches it over the image's working
  size with bilinear sampling, its edge pixels repeated first, then
  `CIBlendWithMask` mixes the image with transparency or the fill. Because
  the mask covers the whole picture it was found in, it lines up at every
  scale (tested at 1.0, 0.37 and 0.1, and preview against full
  resolution). Copy Subject appends the cut-out and a crop to the mask's
  bounds to the shown snapshot (`Snapshot.appending`) and renders through
  `renderForExport` in Copy's colour space.
- **HDR.** The blend is a per-pixel mix with no clamp, so what remains
  keeps values above 1 (in `hdrHighlightsSurviveEveryKindOfTool`, preview
  and full resolution). Copy Subject is SDR, tone mapped as Copy is.
- **Design decisions.** The mask is stored in the operation (tens of KB of
  PNG) rather than looked up by key, so undo, redo, Save, a snapshot taken
  for a background save and a reload all render the same cut without
  Vision. The analysis sees the committed edit (or the shown one for Copy
  Subject) at 8 bits, which detection doesn't mind. A step made before a
  geometry change keeps its mask (it was found for its own input); a new
  Remove Background after a crop finds the subject again. Each mask hashes
  its PNG once when made (`SubjectMask.digest`), so comparing operations on
  the main thread (tools checking for a change) tells different masks
  apart without comparing a few hundred KB of bytes, and masks with the
  same byte count no longer share a hash; only masks with equal digests
  compare bytes. Every copy of the operation still holds the PNG (shared
  `Data`, not copied); a Batch Convert preset that stores a Remove
  Background step would store the mask of the photo it was made on, which
  suits no other photo, so the batch wave should leave this operation out
  of presets or find the subject per file.
- **Limits.** All instances or nothing: no picking one subject, no brush to
  refine the edge, no feathering control. The edge is as soft as Vision
  makes it, stretched to the full size (soft rather than blocky on a
  24 MP photo, but not hair-accurate). A colour fill is opaque only. Vision
  may find no subject in landscapes and textures. Copying from a RAW with
  a live RAW tool change develops a full-size original for it first.
- **DESIGN.md, wiki and help changes.** DESIGN.md 4.7 "Effects, drawing and
  retouching" (or a new paragraph): the subject mask, found once, stored as
  PNG in the operation, stretched at render. 7 "Selection and the
  clipboard": Copy Subject (PNG and TIFF, cropped, the shown picture,
  document untouched). 5, the menu table: Image > Remove Background… (none),
  Edit > Copy Subject (none). docs/wiki/Editing.md "Retouch" (Remove
  Background) and the tools panel list; docs/wiki/Viewer.md wherever Copy
  is described; docs/wiki/Security-and-Privacy.md: Vision's subject
  lifting runs on the Mac, nothing leaves it. Help: Editing.md "The tools"
  (Remove Background), Viewer.md (Copy Subject), Privacy.md (on-device
  Vision). The keyboard shortcuts page needs nothing.
