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
  place (tested within two proxy pixels). Tiling repeats one bitmap (stamp
  plus gap) with `CIAffineTile`, anchored at the chosen position, so a tiled
  50 MP photo still costs one small bitmap.
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
  legibility over busy photos. Tiles form a straight grid (no diagonal or
  staggered rows). The picture is drawn at 8 bits, so an HDR logo is shown
  SDR.
- **DESIGN.md, wiki and help changes.** DESIGN.md 4.7 "Effects, drawing and
  retouching": the watermark's rendering and its bookmark; 5, the menu
  table row (Image > Watermark…, none); 4.8 Batch Convert once the later
  wave uses it. docs/wiki/Editing.md "Text and Shapes" neighbour section
  "Watermark"; docs/wiki/Security-and-Privacy.md: the watermark keeps a
  read-only bookmark to the chosen picture. Help: Effects.md, a new
  "Watermark" section after "Text and Shapes"; Privacy.md, the bookmark.
