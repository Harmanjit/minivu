# minivu design

minivu is a lightweight image browser, viewer and editor for Apple Silicon
Macs, in the spirit of FastStone Image Viewer, built natively for macOS.
GPLv3. This document is the spec: what the app does, how it is put
together, and the rules that keep it small and fast.

## 1. Goals and non-goals

**Goals**

- Opens instantly, browses a folder of thousands of photos without a
  stutter, and flips between images with no visible decode delay.
- Correct colour on every Apple Silicon Mac: SDR and wide-gamut on every
  screen, real HDR highlights on HDR screens, graceful tone mapping on SDR
  ones.
- Every pixel that reaches the screen is drawn by Metal.
- Zero third-party code. Apple frameworks only, so the GPL has nothing to
  reconcile and there is nothing to vendor, update or audit.
- Idle means idle: no timers, no polling, no redraws when nothing changed.

**Non-goals** (decided 2026-09-13)

- iPad, iPhone, other operating systems.
- Network access of any kind. The sandbox has no network entitlement.
- Removable or external media: SD cards, USB drives, network volumes.
- Formats without a native macOS decoder (PCX, WMF, EPS, X3F, WMA).
- Portable mode, scanners, touch screens, email tools, multiple app
  instances.

## 2. Platform

- **macOS 15 (Sequoia) minimum.** Every M1 Mac runs it, and it brings JPEG XL
  decoding, HDR gain-map decoding and `CGImage` content headroom.
- **Metal 3 feature set** (Apple7 GPU family), which M1 has. Nothing
  M3-only.
- **Swift 6.2**, strict concurrency. The app target defaults to the main
  actor; background work is explicitly `nonisolated` or in actors.
- **SwiftPM, no Xcode project.** `scripts/make_app.sh` assembles and
  signs `build/minivu.app`, as in Latent, copying both resource bundles
  (MinivuRender's shaders, the app's help pages) into Contents/Resources,
  where `Bundle.minivuRender` and `Bundle.minivuHelp` look first.
- **App Sandbox + hardened runtime**, ad-hoc signed. Entitlements: user
  selected files (read-write), app-scoped bookmarks, the Pictures folder,
  printing. No network.

## 3. Formats

All decoding goes through Apple frameworks:

| Formats | Decoder |
|---|---|
| JPEG, PNG/APNG, GIF, HEIC/HEIF, AVIF, WebP, JPEG XL, JPEG 2000, TIFF, BMP, TGA, ICO, CUR, PSD (flattened) | ImageIO |
| CR2 CR3 CRW NEF NRW PEF RAF RWL MRW ORF SRW ARW SR2 SRF RW2 DNG, and the rest of Apple's camera list | ImageIO (Apple RAW) |
| PDF | PDFKit / CGPDFDocument |
| SVG | AppKit (`NSImage` SVG rep) |

`MinivuCore/ImageFormats.swift` is the single list of extensions the
browser shows. Anything ImageIO can open is viewable; the list only
decides what appears in folders.

## 4. Architecture

```
minivu (app, AppKit + a little SwiftUI)
  ├── MinivuRender   Metal: textures, canvas presenter, kernels, transitions
  │     └── MinivuCore
  └── MinivuCore     decoding, metadata, folders, catalog, thumbnail cache
```

Three modules, one process. `MinivuCore` has no GPU and no windows, so its
tests run in milliseconds. `MinivuRender` owns every Metal object. The app
owns windows, menus and the glue.

### 4.1 AppKit first, SwiftUI for forms

The browser grid, folder tree and image canvas are AppKit:
`NSCollectionView` recycles cells and prefetches, so ten thousand files cost
the same as fifty; `NSOutlineView` loads folder children lazily; the canvas
is an `NSView` backed by a `CAMetalLayer` so we control exactly when a frame
is drawn. SwiftUI (hosted in `NSHostingView`) is used where it shines and
is not a hot path: the info panel, edit inspectors, preferences, dialogs.

### 4.2 The decode path

One image goes from file to screen like this:

1. **Open** a `CGImageSource` with caching off.
2. **Decode at the size needed.** `CGImageSourceCreateThumbnailAtIndex` with
   a max pixel size decodes JPEGs using the codec's own downscaling (DCT
   scaling), which is several times faster than a full decode. EXIF
   orientation is applied here. RAW files use the camera's embedded
   preview when it covers the size needed; when it doesn't (many cameras
   store 1616 px, or the user zooms past it) the sensor data is rendered
   on the GPU by Apple's RAW engine (`CIRAWFilter` through a Core Image
   context on our Metal queue) straight into the mipmapped texture, and
   steps 3 to 5 don't apply. The "RAW files" setting (Embedded preview /
   Render RAW data) can render every time, and "extended dynamic range"
   RAW always renders, since embedded previews are SDR.
3. **Convert colour once.** The CGImage is drawn into a bitmap whose memory
   we allocated page-aligned, in the working colour space (4.3). ColorSync
   does the conversion, honouring any embedded ICC profile.
4. **Wrap without copying.** That memory becomes an `MTLBuffer`
   (`bytesNoCopy`) and a texture view of it. Apple Silicon has unified
   memory: the GPU reads the same pages the CPU wrote.
5. **Mipmap on the GPU.** One blit copies into a private, mipmapped texture
   and generates the mip chain. The CPU buffer is freed.
6. **Refine.** If the image is larger than the screen, the full-resolution
   decode runs in the background and replaces the texture when done, so
   zooming to 100% is sharp. Neighbours are prefetched at screen size only.

### 4.3 Colour and HDR

- **Working space for SDR images:** Display P3, 8 bits per channel, stored
  as `bgra8Unorm_srgb`. The GPU linearises on sampling, and mipmaps are
  filtered in linear light, which keeps downscaled views correct.
- **Wide-gamut, 16-bit and HDR images:** extended linear Display P3 in
  `rgba16Float`. Values above 1.0 are highlights brighter than paper white.
- **The screen:** the canvas layer is `rgba16Float` in extended linear
  Display P3 with `wantsExtendedDynamicRangeContent`. Every frame knows the
  display's current EDR headroom (1.0 on an SDR screen, up to 16 on an XDR
  screen at low brightness). The present shader passes values below the
  headroom through and rolls off anything above it smoothly, so the same
  code path gives real HDR on a MacBook Pro and a clean tone-mapped image on
  a MacBook Air. A frame drawn while the headroom is low stays tone mapped
  to it, and the system's headroom notification can come before the new
  value is readable or not at all. So for two seconds after an HDR texture
  arrives, EDR comes on, the canvas resizes or the screen changes (and
  while the headroom keeps moving) each display refresh compares the
  headroom with the frame's and redraws if it moved; after that, as long as
  the frame has less headroom than the image could use (its own content
  headroom, or the screen's most), the check goes on four times a second,
  so a rise nobody announces is caught however late it comes. A frame that
  already shows everything the image has needs no checks.

### 4.4 The canvas

`ImageCanvasView` (app) + `CanvasRenderer` (MinivuRender):

- A `ViewportTransform` (zoom = screen pixels per image pixel, and the image
  point at the view centre) fully describes zoom and pan.
- The renderer draws one full-screen triangle; the fragment shader maps each
  screen pixel into the image through a 3×2 matrix and samples the
  mipmapped texture trilinearly. Cost is proportional to screen pixels, not
  image pixels, so a 100 MP image pans as smoothly as a 2 MP one.
- The magnifier is the same shader: inside a circle around the cursor it
  uses a second, more magnified transform.
- Frames are drawn on a display link that pauses itself whenever nothing is
  dirty, except that with EDR on it keeps checking the headroom for two
  seconds after the content, size or screen changed, and a few times a
  second while an HDR image is shown with less headroom than it could use
  (see 4.3): the one exception to idle meaning idle, and only while EDR,
  which costs far more, is on.

### 4.5 Memory

- `TextureCache` holds decoded textures with a byte budget (default: 1/8 of
  RAM, at most 1.5 GB) and evicts least recently used.
- Thumbnails: an in-memory `NSCache` plus an on-disk SQLite cache in the
  app's Caches folder, keyed by path, size and modification date. In
  memory they are redrawn on the worker as 8-bit BGRA in the screen's
  colour space, so Core Animation has nothing to convert on the main
  thread; on disk they stay JPEG or PNG.
- Images above 16384 px on a side (Metal's texture limit on M1) are shown
  downscaled to fit the limit, and a full-resolution decode asks ImageIO for
  that edge rather than for everything, since the upload would scale the
  rest away: a 40000 px scan decodes at 20000 px where the codec can halve
  it. Save, Save As, Batch Convert and export are unaffected and still keep
  every pixel, which is what `EditRenderer.tiledSource` exists for.
- The browser refuses to thumbnail a file whose header claims more than
  32768 x 32768 pixels, the cap Resize and Batch Convert already put on
  minivu's own output, and the thumbnail service remembers the refusal.
  ImageIO streams the rows of a thumbnail request rather than holding the
  image (a 144 MP PNG costs 11 MB, measured), so this is a backstop against
  a damaged or forged header, not a limit real work meets; the file still
  opens in the viewer, decoded once at screen size.
- Count Colors holds the image twice, as the decode and as the 8-bit bitmap
  it draws, so it refuses a raster or RAW file whose header is past a
  quarter of RAM at eight bytes a pixel, before decoding anything. A bitmap
  it cannot allocate is reported as a failure; reporting no colours would be
  a wrong answer.
- RAW renders: one at a time, in a slot of their own beside the three
  decode slots, because the RAW engine adds about 1.6 GB of footprint per
  full-resolution 24 MP render (0.8 GB screen-sized) and holds it for about
  five seconds. Only the nearest RAW neighbour is prefetched as a render,
  and on Macs with 8 GB of RAM or less none is (embedded previews still
  are).
- The RAW Core Image context uses a 512 MB memory limit on Macs with 8 GB
  or less: footprint 20-26% lower, full render about 10% slower; lower
  limits cost much more time, 1024 MB saves nothing.

### 4.6 Catalog

One SQLite database (system `libsqlite3`, no wrapper library) in the app's
Application Support folder stores ratings, labels, tags and custom sort
order. Each row keeps the path and the file's APFS file identifier, so a
file moved in Finder is found again by identifier and its path healed.
Stars and the tag stay in the catalog; nothing writes them into files or
Finder tags yet (`CatalogMirror` is the hook for XMP or Finder tags). Finder
tags are read, shown and filtered by, never changed. JPEG comments are
written into the file itself.

Healing runs with every folder listing. It is paused while minivu itself
moves or renames files (`Catalog.pauseHealing`) until the moves are
reported: a listing in between (the folder watcher fires as files move)
would reattach the rows by identity first, and the report would then drop
them as a replaced file's. Ratings, tags and order changes still queued
when the app quits are written before it exits.

The browser reads a folder's marks in one catalog query, off the main
thread with the folder listing, so a grid sorted by rating arrives already
in order. Writes (a rating key, a tag, a drag that reorders) go through one
serial queue off the main thread, so quick presses land in order; the
catalog then posts `Catalog.didChange` naming the files, and each window
redoes only what those files affect: the visible cells showing them, the
filter or sort when it depends on marks, the preview pane and the viewer's
HUD. Finder tags (the coloured dots) are read from each file's extended
attribute after every listing, off the main thread, and never hold the
listing back.

### 4.7 Editing

Non-destructive until saved. An `EditDocument` holds the decoded original
and an ordered list of `EditOperation` values; undo and redo move a cursor
through that list. The list compiles to a Core Image graph rendered on
Metal: at screen resolution while a slider moves, at full resolution when
saving. Operations Core Image doesn't have join the same graph: the eleven
resampling filters and oil paint are Metal compute kernels wrapped in
`CIImageProcessorKernel`; bump map, sketch, frame, lens, clone, heal and
red-eye are Core Image kernels compiled at runtime. Drawn objects (text,
lines, callouts) stay editable as vectors: reopening the drawing tool on
a document whose last step is a drawing edits that step.

**Operations** are plain `Codable` values whose parameters are stored in
full-resolution pixel units (or normalised coordinates for crops and
points). Building the graph takes a `scale` so the same operation renders
correctly on a screen-sized proxy: a 10 px blur becomes a 2.5 px blur on a
quarter-size proxy.

**Rendering an edit:**

1. The original is decoded once at full resolution. A screen-sized proxy
   (Lanczos) is made from it and cached. Until there is an edit to show (a
   tool just opened, or its change cancelled or undone) the canvas keeps the
   viewer's own texture, HDR included, rather than a render of the same
   picture; zooming in then renders full resolution from the decoded
   original. Edits all taken back put the viewer's texture back at the end
   of the event, so a tool changing the document in several steps (one
   Colors section taking over from another, one effect replacing another)
   never flashes the unedited photo between them. RAW files, whose viewer
   texture may be the camera's preview, originals decoded at another size
   than the viewer's (vectors), and files changed on disk since the
   original was decoded (the viewer would show the other version) show a
   render instead.
2. While a slider moves, the graph runs on the proxy and renders straight
   into a mipmapped texture the canvas shows. Target: under 16 ms per
   update for colour and tone operations on a 24 MP photo.
3. When the slider settles, or the user zooms past the proxy, the graph
   renders at full resolution in the background and replaces the texture.
4. Saving renders at full resolution into a CGImage with the chosen colour
   profile and encodes with ImageIO.

Each render lane caches an `EditStage`: committed operations up to the last
shrinking resize, rendered once at the render's scale; later frames start
from it (M4: 18-20 ms to 1.4-5.5 ms after a resize). A render the document
has moved away from (cancel, apply, section switch, undo) is dropped when a
newer render is queued or running; frames of a slider in motion are still
shown. Retouch strokes stay drawn until `EditDocument.deliveredOperations`
include them.

**Resampling filters (11):** Box, Triangle (bilinear), Hermite, Bell,
B-Spline, Mitchell–Netravali, Catmull-Rom, Cosine, Quadratic, Lanczos 3,
Lanczos 8. One separable Metal kernel evaluates any of them: two passes
(horizontal, vertical), taps computed in the shader from the filter's
support widened by the downscale factor, weights normalised, filtering in
linear light.

**Undo:** the operation list with a cursor, capped at 50 steps; a step is
one or more operations (a Colors visit that changed both sections is one
step). Undo is a cursor move plus a re-render, so it costs no memory for
pixels. Brush
operations (clone, heal, red-eye) record their strokes as parameters, so
they replay the same way.

**Lossless actions:** rotating a JPEG in the browser changes its EXIF
orientation tag with `CGImageDestinationCopyImageSource`, never re-encoding
pixels. JPEG comments are rewritten in the COM segment without touching
image data. A browser selection rotates a few files at a time off the main
thread; files that can't turn without re-encoding (RAW, GIF, BMP…) are
skipped and named in one alert afterwards, and batches run one after
another so two quick ⌘R presses turn a photo twice.

**Saving:** Save (⌘S) writes over the original in its own format, colour
space and depth, with the options last used for that format and metadata
always kept, after a "Replace the original?" confirmation that can be
turned off. Files minivu can't write back (RAW, WebP, AVIF, PDF, animations,
multi-page files) go to Save As instead. Save As is the system save panel
as a sheet, with an accessory for format, quality, colour profile,
metadata, progressive, 16-bit, TIFF compression and background; the
options are remembered per format. The image is rendered once while the
panel is open (an edit through `EditRenderer`, an unedited original decoded
by ImageIO) and shared by the live size estimate, the quality comparison
and the final write. The estimate is an exact full encode 150 ms after the
last change, one at a time; an encode slower than 400 ms first shows a
figure extrapolated from a 1024 px centre crop. The quality comparison is a
separate window showing the original and the encoded result side by side
at 100/200/400%, re-encoding only the region on screen as the slider moves.
Every write to an image file (Save, Save As, a comment, a lossless rotate)
goes through one serial queue, so ⌘S, an edit and ⌘S again land in that
order, and a document is marked saved only by the last write of its file.
Moving a file away (Move to Trash, a rename including Batch Rename, a move
or its undo) waits for the writes queued for it, or for files inside a
folder being moved, so a save asked for just before lands first instead of
putting the file back at its old path. A capture, a montage and a desktop
copy choose their name inside the queue, so they name the folder they write
into rather than the file, which is the smallest thing they can name in
advance and enough for a wait on that folder to cover them. Move to Trash of an image with unsaved edits in the viewer
(from the viewer, or the browser trashing that image) asks as moving on does.
After an in-place save the file holds the edits, so a document is never
decoded again from it (that would apply them twice); reloading means a new
document, and undo history starts over after a save. The viewer's entry then
takes the file's new date and size, as it does after another application's
save, so the info panel, the colour count and the filmstrip's thumbnail
describe what was just written; a save that leaves edits behind keeps the
old stamp until the save that clears them, since restamping under a live
edit session would cost it its renders. As a safety net each
document records the file's modification date and size at its first
decode, and the renderer refuses to decode a changed file for it again.
Save compares that stamp with the file before asking "Replace the
original?" and again in the write queue just before writing: a file
another application saved since the edits began is never replaced (the
viewer asks Reload or Keep My Edits, as for an external editor, and the
write fails if the change lands while the question is up). minivu's own
writes of the file (an earlier Save, a comment) don't count: `OwnWrites`
keeps the stamp each `ImageEncoder` or `JPEGComment` write left. A lossless
rotate does count, since the edits were made on the unrotated pixels.
Save keeps a gain-map JPEG or HEIC HDR: the edit renders as half-float
extended linear P3 with the original's headroom, and ImageIO (macOS 15,
`kCGImageDestinationEncodeToISOGainmap`) writes an SDR base and an ISO gain
map. PQ/HLG originals and gain maps in other formats are tone mapped to SDR
(PNG can't hold a gain map; ISO HDR tone maps), and the Replace alert says
which. The HDR decode for Save ignores the viewer's HDR setting. Save As
stays SDR. Stale hdrgm/HDRGainMap XMP is never carried.
Quitting asks about unsaved edits and waits for queued writes to finish;
a copy or move under way stops after the item it is on, and a batch rename
under way finishes (a swap hides a file under a temporary name meanwhile).
Writes into a folder minivu hasn't opened (Save As onto the Desktop) put
their temporary file in the volume's item-replacement folder, because the
sandbox grants the save panel's file but not its folder.

**Effects, drawing and retouching (Phase 6).** Every length is stored as
a fraction of the photo's short side or in full-resolution pixels, so a
proxy and the saved file agree. Drawn objects are rasterised with Core
Graphics and Core Text at the working resolution, in tiles for outputs
wider than a texture, and composited over the photo (highlights multiply).
Clone and heal strokes are dabs along a path; heal copies the texture and
matches it to its surroundings with a masked, normalised blur. Red-eye
darkens reddish pupil pixels inside feathered circles, found by hand or by
Vision's face landmarks. Tools of hand-made steps (strokes, objects) undo
one step at a time while open, and moving on to another command applies
them rather than dropping them.

Core Image rules learned the hard way, which every new kernel follows:

- A kernel whose image inputs are all `sample_t` is a colour kernel, and
  Core Image may fuse it with neighbours and move later transforms inside
  it. Anything that depends on position (`destination.coord()`, a
  generator image, a hard-edged patch) is a general kernel with samplers,
  or its positions come from a bitmap mask instead.
- A position-dependent kernel renders over an infinite extent and is then
  cropped, or a later transform lets it spill past the image.
- Patches are computed a little past their area and mixed by mask, so a
  later rotate never samples a hard edge between pixels.
- Each runtime kernel is compiled into a library of its own: two kernels
  from one library that first render at the same moment on two threads
  can swap for the rest of the process.
- Core Image submits its own command buffers when rendering to a texture;
  sharing one of ours broke tiled renders around processor kernels.

### 4.8 Tools

Section 5 describes what each tool does; these are the implementation
rules a maintainer needs.

**Batch Rename.** `RenamePattern` (MinivuCore) is text with tokens:
`{name}`; `{#}` or `{###}` for the counter (the digits setting is a
minimum; start and step can be set); `{date[:format]}` for the date taken
(EXIF DateTimeOriginal, else DateTimeDigitized, else the modification date,
in the camera's EXIF offset zone when one is recorded); `{modified[:format]}`;
`{width}` `{height}` as displayed; `{ext}`. Keywords work in any case;
formats are Unicode date patterns (yyyy-MM-dd by default) in en_US_POSIX
and the Gregorian calendar, so names are the same on every Mac. Tokens come
first, then find and replace, then letter case; the extension goes on last
in its own case. Unknown tokens stay visible and block Rename. EXIF is read
only when the pattern needs it.

- `RenamePlanner` checks everything before any change, one `lstat` per file
  and per new name: invalid names, two files getting one name (compared as
  APFS compares: normalisation ignored, case ignored on case-insensitive
  volumes), a name held outside the batch, a source that has gone. A name
  held by another file of the batch is allowed. Planning runs off the main
  thread; batches of 300 or more wait 150 ms after typing stops.
- `BatchRenamer` renames with exclusive `rename(2)`. A file waits until its
  new name is freed; only a cycle can't be ordered, and one file of the
  ring steps aside under a hidden temporary name. A crash leaves at most one
  hidden file per ring, and a temporary file that can't take its name goes
  back under its own (or a numbered) one. A failure fails the files waiting
  on it.
- Every move, temporary names included, reaches the catalog in one
  `Catalog.filesMoved` transaction when the renames are done (one
  `Catalog.didChange`), so stars and Custom Order places follow, and a swap
  swaps places. 5000 renames take about 1 s, and their undo the same (debug
  build, in-memory catalog).
- Undo is the same operation reversed: one step, "Rename N Items". Batches
  in a window run one after another, and an undo or redo reads the names to
  restore only when it starts. Afterwards only the folder shown is listed
  again.

**Batch Convert.** `BatchConvertSettings` (MinivuRender, Codable, defaults
for missing keys) holds the `ExportOptions`, the destination (beside the
originals, or a chosen folder's security-scoped bookmark, kept and
refreshed when stale), naming, the existing-file policy (skip, keep both,
replace to the Trash), resize (long side, width, height or percent, any of
the 11 filters, don't enlarge; 0, or past 32768 px or 1000%, disables
Convert), quarter turns and flips. Operations run turn, flip, resize.

- A format change with no operations encodes ImageIO's full decode with
  the orientation baked in (exact pixels, as Save As does). Operations, and
  every RAW file, go through an `EditDocument.Snapshot` into
  `EditRenderer.renderForExport` (RAW with the viewer's RAW setting), always
  SDR. Colour is the chosen profile, or for Keep original the Save policy's
  render space; formats without profiles get sRGB. Metadata is kept or
  stripped by `ImageEncoder`, orientation reset to 1.
- `BatchOutputPlanner` settles every clash before anything is written.
  Outputs never share a name and never land on another source of the batch
  (recognised by path and by file identity); both are numbered ("photo
  2.jpg") whatever the policy. A folder is never replaced.
  `BatchReplacements` lists what the batch would send to the Trash, and the
  app asks once, naming up to three files: Replace, Keep Both (planned
  again for this run only) or Cancel, the default. A file that takes an
  output's name after planning was never named, so that output is written
  with Keep Both even under Replace.
- `BatchConvertJob` converts 2 files at a time (1 on Macs with 8 GB or
  less) and at most one camera RAW at a time (about 1.6 GB per render).
  Work runs on GCD through `BatchWorkExecutor`, a task executor preference
  that keeps the async renderer off the cooperative pool. Encodes are
  parallel; writes go through `FileWriteQueue.shared`. `BatchFileWriter`
  writes a hidden sibling, fsyncs, and renames it into place with
  `RENAME_EXCL`; a name taken since planning gets the policy again. Replace
  writes the new file, trashes the old one, renames the new one in, and
  brings the old one back if that fails.
- Cancel stops new files (including a RAW waiting for its slot) and drops
  encodes that finish later; a queued write completes, so only whole files
  remain. The summary lists up to 8 failed and 8 skipped files; outputs in
  the folder shown are selected and their caches invalidated.
- Marks: an original replaced by its own conversion keeps its stars, tag and
  Custom Order place, following a case-only change of name. Any other
  replaced file takes its marks to the Trash, as Copy's Replace does.
- The Tools menu disables Batch Rename, Batch Convert, Print, Contact Sheet
  and Montage while a sheet is up (`BatchTools.beginSheet/endSheet`), and
  the two batches also while a batch or copy runs. The Convert sheet focuses
  nothing when it opens and ends editing before converting.

**Slideshow rendering.** `SlideshowRenderer` (MinivuRender/Slideshow) draws
one full-screen triangle with one fragment shader, `slideshowFragment`,
switching on the transition index: the order of `SlideshowTransition`'s
cases (its raw values are what settings store). Slides are aspect-fit in
whole pixels on black, small ones as "enlarge small images" says, with the
mip level from texels per screen pixel. Slide, push and zoom move the
slide's rectangle on the CPU (`SlideshowGeometry`); the shader only decides
how much of the new slide each pixel shows: a half-pixel edge for slide and
push, a soft edge 3% of the short side for wipe and iris (starting beyond
the screen, so t=0 and t=1 show one slide; iris measured in pixels), and
two octaves of hashed value noise for dissolve. Progress is eased with
smoothstep. Each slide is tone mapped with its own content headroom before
mixing (`toneMapToHeadroom` in Common.h), and tests pin it to the canvas's
tone map. 1.0–2.5 ms a frame at 5K on M4.

**Slideshow playback.** `SlideshowWindowController` opens a borderless,
normal-level window on the originating window's screen; menu bar and Dock
hide while it is key.

- Between slides nothing renders: one `DispatchWorkItem` waits the interval,
  counted from the end of each transition, and the display link runs only
  during a transition. → and ← finish a transition at once and start a
  quick one (0.35 s).
- Neighbours load through `ImageLoader.shared` fitted to the picture area
  (below any camera housing), and only those textures are kept. Zoom's
  outgoing slide grows past fit only as it fades, so no larger decode. A move waits for a slide not yet
  decoded (cleared before the texture is requested, so a cache hit can't
  run it twice). Failed files are marked in `SlideshowSequence` and skipped
  both ways; if nothing loads, the show ends.
- `SlideshowSequence.isOverAfterCurrent` ends a show after its last slide
  only when Loop is off or nothing can play. Shuffle puts the starting image
  first and fixes the order for the run. When the show ends the viewer moves
  to the last slide shown.
- Captions are read ahead off the main thread; one that needs metadata
  fades out until it is read. EDR is on only while an HDR slide is on either
  side of a transition. `ProcessInfo.beginActivity` keeps the display awake.
- Esc, a click outside the control bar, its close button and ⌘W end the
  show. The borderless window enables Close Window itself, as the viewer's
  full-screen window must too. Control bar buttons never take focus, so
  Space always pauses.
- `SlideshowSettings` is one Codable value in `SlideshowSettingsStore`
  (key "slideshowSettings"); missing fields default and numbers are clamped
  (interval 1–60 s, duration 0.3–3 s, volume 0–1). A running show reads
  interval, transition and caption afresh for each slide; order, loop and
  playlist are fixed at the start. Volume ramps over 0.1 s, and Play Music
  off mutes over 0.25 s.
- `SlideshowAudioPlayer` is the only file that imports AVFoundation, behind
  `SlideshowAudioPlaying`. `SlideshowMusic` resolves bookmarks off the main
  thread (remaking stale ones), adds the songs directly inside a chosen
  folder by name, and holds security-scoped access until it stops, released
  even if the show ended while resolving. Songs open through `BlockingWork`;
  a generation count drops a song that finishes opening after the show
  ended. It fades in over 1 s, and out over 1.5 s at the end, outliving the
  window for that fade.
- The Settings pane's preview is a small Metal view with the same shader;
  its display link runs only while it plays. Snapshot switches:
  `debugFreezeSlideshowTransition:` (MINIVU_DEBUG_TRANSITION,
  MINIVU_DEBUG_PROGRESS, MINIVU_DEBUG_CAPTION) and
  `debugShowSlideshowSettings:`.

**Print and contact sheets.** `PageLayout` (MinivuCore/Layout) is the one
piece of page geometry: pure, in page units (points for print, pixels for
sheets), top-left origin with a `flipped` helper. It places the grid inside
margins, header and footer bands and caption bands, fit or fill, and turns
a picture when the turned shape covers more of its cell. Images-per-page
choices become the grid whose cells are closest to square.

- One Core Graphics renderer (Tools/Print/LayoutRendering.swift) draws a
  page into any y-up context, decoding four cells at a time, so memory is
  one page and four pictures. `LayoutImageProvider` is a thread-safe LRU by
  bytes: an entry serves requests from half its long edge up to the size it
  was decoded for, and decodes more than twice the size asked are shrunk
  before they are kept (otherwise the preview decoded forever). ImageIO
  thumbnails up to 512 px, the display decode above; HDR comes out SDR.
- Print uses a copy of `NSPrintInfo.shared` with zero margins; afterwards
  only printer, paper, orientation and scale are written back. The page
  view's `knowsPageRange`, `rectForPage` and `draw` are nonisolated and
  touch only a locked `PrintJob`, which makes `canSpawnSeparateThread` safe.
  Pages are stacked at a fixed 100 000 pt pitch.
- Measured by printing to PDF, and guarded by PrintTests: with
  `knowsPageRange`, AppKit puts each page rectangle's corner at the
  printable area's corner at 100% whatever `scalingFactor` says. So a page
  rectangle is the printable part of the sheet, `draw` applies Page Setup's
  scale itself, and margins never go below the unprintable edge.
- Print decodes at cell × printer dpi/72 × scale (dpi clamped to 150–600,
  300 when unknown; long edge at most 6000 px). The print panel's preview is
  recognised by its context class (`NSPrintPreviewGraphicsContext`) and
  never decodes on the main thread: cached ≤384 px pictures and grey
  placeholders, decoded on one serial queue per job, then a KVO
  `layoutRevision` redraw. The viewer prints its edited render when it has
  unsaved edits, else the file and page shown.
- Contact sheets: A4 and Letter at 300 dpi (a PDF's media box is the paper),
  4K and Custom at one point per pixel; PDF pages at most 14,400 pt a side.
  The preview renders page 1 at 600 px, 150 ms after the last change. Page
  names come from the header made safe ("/" and ":" to "-", no control
  characters or leading dots, 200 bytes at most) and are chosen so none
  exists. Pages are made in the volume's item-replacement folder and moved
  in through `FileWriteQueue`; a failure removes the pages that save placed.

**Montage wallpaper.** Pure geometry in MinivuCore/Montage/MontageLayout.
Grid picks the columns and rows whose cells best match the photos' median
shape, with spare cells repeating photos. Mosaic builds justified rows,
picks the row count whose height is closest to the screen, then scales
every row by one factor to fill the height exactly (photos crop by those
few percent). Scattered gives each photo a cell, a print 1.3× the cell,
jitter, up to 12° of tilt and a 4% border, from a SplitMix64 seed that
Shuffle replaces. Rendering is Core Graphics in 8-bit Display P3 at the
display's pixel size: ImageIO thumbnails at each photo's largest tile, four
decoded at a time on GCD, drawn in one `BlockingWork` job at a time into the
single context. The JPEG (quality 0.9) goes through `FileWriteQueue` to
Pictures/minivu Wallpapers and is set per display. Cancel is checked again
after each write, and a cancelled or failed run deletes the files it wrote.
Harness debug actions never save remembered choices.

**Set as Desktop Picture.** The wallpaper agent reopens the file later and
after restarts, so a JPEG, PNG, HEIC or TIFF inside Pictures (by real path)
with no unsaved edits is used as it is. Anything else is exported to
Pictures/minivu Wallpapers ("Desktop <timestamp> <name>.jpg", HEIC when
transparent), SDR and no larger than twice the screen's long edge, edits
through `renderForExport`. The newest 10 copies are kept, never one still
on a screen; montages are never pruned.

**Capture.** ScreenCaptureKit behind `ScreenCapturing`; tests and snapshot
runs get a capturer that never records or asks. Entire Screen captures the
display under the pointer at its pixel size, excluding minivu as an
application (its own windows as the fallback), after ordering out the
overlay and the menu. Window… uses `SCContentSharingPicker` in single-window
mode without a permission check, since choosing a window is consent.
Selection… puts a borderless, transparent overlay at screen-saver level on
every screen; the window under a new drag becomes key, the crosshair uses
`cursorUpdate` tracking areas, and switching apps cancels. Entire Screen
and Selection check screen recording first: the very first request
(remembered in defaults) shows the system prompt, later denials minivu's
own alert; never both. Captures are 8-bit PNGs in Pictures/minivu Captures.

**External editors.** An ordered list in its own defaults key (name, bundle
identifier, path, app-scoped bookmark); the app is found by bookmark, then
path, then bundle identifier. The menu is rebuilt when the list changes, not
in `menuNeedsUpdate`, because AppKit looks up key equivalents without
updating menus. The browser opens the selection or its lead image (asking
above 20). Files sent are watched with one FSEvents stream per folder, for
the 8 most recent folders; stamps are read after the previous comparison
finishes, with cached resource values dropped, and a missing file isn't
reported. A changed file's caches drop and the viewer reloads it, keeping
the zoom when the size is unchanged; its entry takes the file's new date and
size first and is described again (info panel, colour count, filmstrip,
pages). The info panel reads again when the date changes, not only the URL,
so the browser's preview, whose listing already updates, follows too. With
unsaved edits the viewer asks as a sheet, after any other sheet ends: Keep
My Edits (the default) or Reload.
From the moment the change is seen, the session's `externalChange` turns
Save into Save As, even for a "Replace the original?" already on screen.
minivu's own writes (`SavePresenter.didWrite`) re-stamp watched files, so a
Save is never reported back.

## 5. User interface

Loosely FastStone's layout, in current macOS style (unified toolbar, SF
Symbols, sidebar materials, system appearance).

**Browser window:** folder sidebar (favourites, then the folder tree) |
thumbnail grid | preview pane with file info and EXIF. Toolbar: back,
forward, parent folder, sort, thumbnail size, filter, slideshow, compare.
A folder deleted or moved in Finder relists its nearest existing parent's
sidebar row. Rows removed from the tree are detached, and late listings for
them are dropped. A folder the sandbox refuses shows a permission message
pointing to File > Open Folder….

**Ratings and tags.** Each image has 0–5 stars and FastStone's "tagged"
flag for culling. A grid cell shows its stars under the name (hollow stars
appear on hover, and a click rates; clicking the current rating clears it),
a checkmark badge on the picture's corner when tagged, and its Finder tag
dots after the name. The preview pane shows the lead photo's stars and a tag
button under it; the viewer's HUD shows both. Tag on a mixed
selection tags all of it, and untags only when all were tagged.

**Filter and sort.** The toolbar's Filter menu shows everything, images
rated at least 1 to 5 stars, tagged images only, or one of the folder's
Finder tags; the symbol fills while a filter is on and the status bar says
"12 of 340 shown". Filters apply to images, never folders, and stay as the
user moves between folders. Sort by Rating puts the most stars first (ties
by name); Custom Order is the user's own arrangement, per folder, with new
files after it by name. Each sort key remembers its own direction, as
Finder's columns do.

**Files.** Dropping files on the grid copies or moves them into its folder,
on a folder cell or sidebar row into that folder, by Finder's rules: same
volume moves, another copies, ⌥ copies and ⌘ moves. Files already in the
folder do nothing, except in Custom Order, where the drop reorders them at
the gap shown. Whether files are already there, or a folder would go into
itself, is decided by file identity, not by path, so another spelling of
the same folder (a symbolic link, `/tmp` for `/private/tmp`) can never make
a file replace itself. Name clashes ask Replace, Keep Both or Skip (Apply
to All), all before anything moves, and Replace puts the old item in the
Trash rather than deleting it (an item that holds the file being moved is
never replaced); if the new item then can't arrive (unreadable, disk full)
the old one comes back from the Trash. A move to another volume copies to
a hidden name, renames into place and only then deletes the original, so
it never leaves a partial item under the real name. The work runs off the
main thread one file at a time, with a progress sheet and Cancel for more
than 20 files or anything still running after half a second; the arrivals
are selected afterwards.
Copy To and Move To choose a folder with an open panel and remember the
last five (as security-scoped bookmarks). Rename (F2 or the context menu)
edits the name in place with the base name selected: Return or a click
elsewhere commits, Esc cancels, and a name that can't be used is explained
and offered back to correct. New Folder makes "untitled folder" and starts
renaming it. Moves, copies, renames and new folders are undoable ("Undo
Move 3 Items"); undoing a copy or a new folder moves it to the Trash, and
undoing a transfer that replaced something brings that back from the Trash.
A file renamed in Custom Order keeps its place.

**Viewer:** opens on double-click or Return. Windowed or true full screen
(borderless, instant). Full screen opens on the display Settings > Viewer
chooses: the display with the browser (default), or another display
(FastStone's dual-monitor mode). With one display it falls back to that
display. A windowed viewer away from the browser's display goes full screen
where it is. Slideshows use the same rule, so a show from a full-screen
viewer plays over it. In full screen the edges reveal fly-out panels on
hover:

| Edge | Panel |
|---|---|
| Top | filmstrip of the folder |
| Left | edit and effect tools |
| Right | file info, EXIF, histogram |
| Bottom | zoom, navigation, slideshow controls |

**Displays.** Displays come from `Displays.provider` (`ScreenProviding`).
A full-screen window keeps its display's id: on a resolution change it
keeps covering the display, and if its display is unplugged it goes to a
remaining one chosen by the same rule. Move to Next Display goes left to
right and wraps; a titled window keeps its relative place on the new
display's usable area. On notched displays the viewer and slideshow fit
the image below `safeAreaInsets.top` (`auxiliaryTopLeftArea` height as a
fallback); the strip is black whatever the surround, and the HUD and top
panel sit below it (`MINIVU_DEBUG_SAFE_AREA_TOP` simulates a notch in DEBUG
builds; `debugShowViewerSettings:` opens that pane). `FullScreenPresentation`
is the one owner that hides the menu bar and Dock while any full-screen
viewer or slideshow window is key: it saves the options from before the
first hide and restores them on the next main-queue turn after the last
release, so key swaps between displays and a slideshow ending over a viewer
neither flash nor restore "hidden". Thumbnails use the colour space of the
browser window's display (the grid draws nearly all of them); following the
key window would empty the memory cache on every switch between displays.
The slideshow re-decodes its neighbours only when moved to a larger
display, and per-frame EDR reads use `headroom(of:)`: building a whole
`DisplayInfo` reads frames and safe area, about 50 µs.

**Mouse:** click toggles best fit and actual size at the clicked point;
press and hold shows the magnifier; drag pans; the wheel is configurable
(next/previous image, or zoom). Pinch zooms.

**Keyboard (viewer):** ← → / Space / Backspace next and previous, Home and
End first and last, ⌥→ ⌥← and ⌥Page Down ⌥Page Up next and previous page
of a document, Page Down and Page Up a page first and then the next or
previous image at either end, P plays and pauses an animation, Return
toggles full screen, Esc back to the browser, `+` `-` zoom, `/` actual
size, `*` fit, 0–5 rating, T or `` ` `` (backquote) tag, ⌘Z / ⇧⌘Z undo and
redo.

**Keyboard (grid):** arrows move the selection, Return opens, typing a name
selects it, 0–5 rate the selection and `` ` `` tags it. A digit or
backquote typed within a second of a letter continues the name instead
(so "IMG_2" can still be typed), and T always types a name in the grid, as
letters do in Finder; ⌘T tags from anywhere. F2 renames.

**Menu shortcuts.** One table for the whole menu bar; a test checks that
no two items share a shortcut (display-only ones included) and that each
resolves to its item. Preview's shortcuts win where it has one, then
Photoshop's letters, moved to a free modifier when the plain one is taken.
Items marked "display" show their key only while the menu is open, so the
key reaches the grid, the viewer or a text field otherwise.

| Menu | Item | Shortcut |
|---|---|---|
| minivu | Settings… | ⌘, |
| | Hide minivu / Hide Others / Quit | ⌘H / ⌥⌘H / ⌘Q |
| File | Open Folder… / Add Folder to Sidebar… | ⌘O / ⇧⌘O |
| | New Folder | ⇧⌘N (Finder) |
| | Open in Viewer / Close Window | ⌘↓ / ⌘W |
| | Save / Save As… | ⌘S / ⇧⌘S |
| | Revert to Saved | none (as in every Mac app) |
| | Rename | F2 (Explorer, FastStone; Return opens and ⌘R rotates) |
| | Copy To > / Move To > (recent folders, Choose Folder…) | none |
| | Reveal in Finder / Move to Trash | ⌥⌘R / ⌘⌫ |
| | Page Setup… / Print… | ⇧⌘P / ⌘P |
| Edit | Undo / Redo | ⌘Z / ⇧⌘Z |
| | Cut / Copy / Paste / Select All | ⌘X / ⌘C / ⌘V / ⌘A |
| View | Show Hidden Files | ⇧⌘. |
| | Filter > Show All, ★ or More … ★★★★★, Tagged Only | none |
| | Show Sidebar / Show Preview Pane / Enter Full Screen | ⌃⌘S / ⌥⌘P / ⌃⌘F |
| Image | Fit to Window / Actual Size / Zoom In / Zoom Out | ⌘9 / ⌘0 / ⌘= / ⌘- |
| | Rotate Left / Rotate Right | ⌘L / ⌘R (Preview) |
| | Flip Horizontal / Flip Vertical | none |
| | Resize/Resample… | ⌥⌘I (Photoshop's Image Size) |
| | Crop… | ⌘K (Preview) |
| | Straighten… | none |
| | Adjust > Lighting… | ⌥⌘L |
| | Adjust > Colors… | ⌥⌘C (Preview's Adjust Color) |
| | Adjust > Curves… | ⇧⌘M (Photoshop's ⌘M is Minimize here) |
| | Adjust > Levels… | ⇧⌘L (Photoshop's ⌘L is Rotate Left here) |
| | Adjust > Sharpen… / Blur… | none |
| | Effects > Grayscale / Sepia / Negative | none |
| | Effects > Drop Shadow… / Frame… / Bump Map… / Sketch… / Oil Painting… / Lens… | none |
| | Retouch > Clone Stamp… / Healing Brush… / Red-Eye Removal… | none |
| | Text and Shapes… | none |
| | Edit Comment… | none |
| | Play Animation / Pause Animation | P (display) |
| | Rating > Clear, 1–5 Stars | ⌃0–⌃5 (the grid and viewer also take bare 0–5) |
| | Tag / Remove Tag | ⌘T (no tabs or Fonts panel to clash with; bare `` ` `` in the grid and viewer, T in the viewer) |
| | Compare Selected | ⌥⌘K (⌘K is Crop) |
| | Histogram | ⇧⌘H (⌘H and ⌥⌘H hide apps) |
| | Count Colors | none |
| Go | Next / Previous / First / Last Image | → ← Home End (display) |
| | Next Page / Previous Page | ⌥→ / ⌥← (display) |
| | Enclosing Folder / Back / Forward | ⌘↑ / ⌘[ / ⌘] |
| Tools | Start Slideshow | ⇧⌘F (Preview) |
| | Batch Convert… / Batch Rename… | ⌥⌘B / ⇧F2 (beside Rename's F2) |
| | Contact Sheet… / Montage Wallpaper… / Set as Desktop Picture | none |
| | Capture > Entire Screen / Window… / Selection… | none (the system keeps ⇧⌘3–⇧⌘5) |
| | Open in External Editor > editors…, Edit Editor List… | ⌘E for the first editor |
| Window | Minimize | ⌘M |
| | Move to Next Display | ⌃⌥⌘→ (fn⌃ is window tiling, ⌃ is Spaces) |
| Help | minivu Help / Keyboard Shortcuts | ⌘? (as in every Mac app) / ⌘/ |

**Tools (Phase 7).** In the browser each tool works on the selected
images, or on every image shown when none is selected; a slideshow of a
single selected image plays the whole folder from it. In the viewer they
work on the image shown, and the slideshow plays the viewer's list from it.

- *Slideshow:* full screen on the display the window is on, black
  background, HDR as in the viewer. Eight transitions rendered by one Metal
  shader (cross-fade, fade through black, slide, push, wipe, zoom, iris,
  dissolve) or a random one per slide; interval, order (in order or
  shuffled), loop, captions (name, date, EXIF line), and a music playlist
  (MP3, AAC/M4A, WAV, AIFF chosen by the user) through AVFoundation that
  fades out at the end; volume and Play Music changed in Settings apply to
  a show that is running. Space pauses, arrows step, Esc ends; the pointer
  hides and a small control bar appears when it moves. Next images decode
  ahead through the image loader.
- *Batch Convert:* output format and its options (the Save As options),
  destination folder (chosen, or beside the originals), file names from a
  rename pattern, and optional resize (long side, width, height or percent,
  with any of the 11 filters), rotate/flip and keep-metadata. Runs off the
  main thread, a few files at a time, with progress, Cancel and a summary of
  files that failed. Nothing goes to the Trash without being named first:
  replacing originals, or files that only share an output's name, is asked
  (Replace, Keep Both or Cancel).
- *Batch Rename:* a pattern of text and tokens (name, counter with start
  and digits, date taken, date modified, extension), find and replace, and
  letter case, with a live before/after list that flags clashes before
  anything changes; one undo step.
- *Print:* the system print panel with a layout accessory (images per page,
  fit or fill, margins, caption) and its live preview; Page Setup is the
  standard sheet. Images are drawn colour-managed at the printer's
  resolution, decoded only for the pages being drawn.
- *Contact Sheet:* columns, rows, cell spacing, captions, header text,
  page size in pixels and background, saved as JPEG, PNG, TIFF or a
  multi-page PDF, with a preview of the first page.
- *Montage Wallpaper:* a collage of the images at the size of the display
  (grid, mosaic or scattered, spacing, background), saved to Pictures/minivu
  Wallpapers and set as that display's desktop picture. Set as Desktop
  Picture uses a single image as it is.
- *Capture:* the entire screen, a window picked with the system's content
  picker, or a dragged selection, through ScreenCaptureKit, saved as PNG to
  Pictures/minivu Captures and opened in the viewer. Only Entire Screen and
  Selection need screen recording permission; picking a window is consent.
- *External editors:* a list in Settings > Editors of applications chosen
  by the user; each opens the selected images or the image shown, and the
  viewer reloads a file an editor saved. If the viewer has unsaved edits of
  that file it asks first: Reload (discarding them) or Keep My Edits, after
  which Save asks for a name, so neither version is lost.

**Help.** Help > minivu Help opens a window of bundled pages (Getting
Started, Browser, Viewer, Editing, Effects & Retouching, Tools, Settings,
Privacy, Keyboard Shortcuts) with a page sidebar and search that filters the
pages and highlights matches. There is no Help Book and nothing is fetched.
Help > Keyboard Shortcuts opens the last page, which is generated: the menu
part from a fresh `MainMenu.make()` (display-only keys shown), then
`KeyboardShortcutsPage.directKeySections` for keys no menu item carries,
which HelpTests press through the grid's, viewer's and compare window's key
tables. The other pages are Markdown in Sources/Minivu/Help/HelpPages,
parsed off the main thread with `AttributedString(markdown:)` in full
syntax and split into blocks by presentation intent, because SwiftUI's
`Text` ignores block structure. Pages link to each other as `help:Browser`;
other links are refused. The window is a SwiftUI `NavigationSplitView` in
an `NSHostingController` with `sizingOptions = []` (otherwise the window
shrinks to its fitting size); `navigationSplitViewColumnWidth` must be the
last modifier on the sidebar (after `.searchable` and `.overlay`) or it is
ignored. The actions are `showMinivuHelp:` and `showKeyboardShortcuts:` on
an AppDelegate extension, never `showHelp:`, which NSApplication answers
first by looking for a Help Book. Under `defaultIsolation(MainActor)`
SwiftPM's `Bundle.module` is main-actor isolated and fatalErrors when
missing, so `Bundle.minivuHelp` searches Contents/Resources, beside the
executable and beside the test bundle. `KeyboardShortcutsPage.menuSections`
shows display-only shortcuts on the bar it is given, so it must get a fresh
`MainMenu.make()`, never `NSApp.mainMenu`. Harness action
`debugHelpSearch:` (`MINIVU_DEBUG_HELP_PAGE`, `MINIVU_DEBUG_HELP_SEARCH`).

**Themes:** System, Bright, Gray or Dark.

## 6. Efficiency rules

1. No work on the main thread that can take more than a few milliseconds:
   decoding, thumbnailing, database writes and file operations happen off
   it.
2. Never decode more pixels than will be shown.
3. Never copy pixels between CPU and GPU; share the memory.
4. Draw only when something changed.
5. Cancel work for things that scrolled away.
6. No dependencies. If Apple's frameworks can do it, use them; if not,
   write the small piece we need.

## 7. Roadmap

| Phase | Deliverable | Status |
|---|---|---|
| 1 | Skeleton: package, app bundle, sandbox, Metal shader loading, tests | Done |
| 2 | The viewer: browser, thumbnails, canvas, zoom and pan, magnifier, full screen with fly-outs, EXIF, themes, preferences | Done |
| 3 | Formats and HDR: RAW refinement, gain maps, PDF pages, SVG, animation, multi-page TIFF | Done |
| 4 | Editing core: undo/redo, resize with 11 filters, rotate, flip, crop, sharpen, blur, lighting, colour, curves, levels, colour effects, Save As with quality preview, JPEG comments | Done |
| 5 | Management: ratings, tags, drag and drop, rename, histogram with colour count, compare up to 4 | Done |
| 6 | Effects, drawing, clone stamp, healing brush, red-eye | Done |
| 7 | Tools: batch convert and rename, slideshow (8 transitions, music), contact sheet, montage wallpaper, print, screen capture, external editors | Done |
| 8 | Polish: dual display, shortcuts, documentation | Done |

## 8. Known limits

- **Editing:** Save keeps HDR only for gain-map JPEG and HEIC originals;
  PQ/HLG files and gain maps in other formats are saved tone mapped to SDR,
  and Save As is always SDR. Saving writes a new file in place of the old
  (atomically), so a hard link to the old file keeps the old picture, and
  a symbolic link is written through to the file it points at.
- **Files:** Save's own-write record is by path, so a comment written in
  minivu after another application changed a file being edited lets Save
  replace that version. Captures, montages and desktop copies take a free
  name just before writing, in the write queue; a file another app creates
  under that name in the same instant would be replaced.
- **Marks:** stars and tags live only in the catalog; they aren't written
  to XMP or Finder tags, so other apps don't see them.
- **Batch Convert:** only the first page or frame of multi-page and animated
  files is converted.
- **Slideshow:** resuming after a pause waits a full interval. A caption
  longer than the space beside the control bar is truncated in the middle.
  Changing HDR or RAW settings mid-show changes the slide on screen only at
  the next slide.
- **Print:** paper smaller than its unprintable edges gets empty cells; Page
  Setup scales below 10% count as 10%. The preview is recognised by the
  class name of its graphics context; if macOS renames
  `NSPrintPreviewGraphicsContext`, the preview decodes at print quality on
  the main thread.
- **Capture:** captures are 8-bit SDR PNGs; HDR capture is future work.
- **External editors:** after Keep My Edits, the viewer's entry keeps the
  old date and size while that edit session lasts, so if the edits are then
  reverted the info panel and colour count lag until the editor saves again
  or you move to another image.
- **Desktop picture:** copies set on other Spaces can be pruned while still
  in use there.
- **Help:** without a Help Book, the Help menu's search field finds menu
  items only, not the text of the help pages; the Help window's own search
  does that.
