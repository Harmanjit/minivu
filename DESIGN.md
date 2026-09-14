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
  signs `build/minivu.app`, as in Latent.
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
  a MacBook Air.

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
  dirty.

### 4.5 Memory

- `TextureCache` holds decoded textures with a byte budget (default: 1/8 of
  RAM, at most 1.5 GB) and evicts least recently used.
- Thumbnails: an in-memory `NSCache` plus an on-disk SQLite cache in the
  app's Caches folder, keyed by path, size and modification date. In
  memory they are redrawn on the worker as 8-bit BGRA in the screen's
  colour space, so Core Animation has nothing to convert on the main
  thread; on disk they stay JPEG or PNG.
- Images above 16384 px on a side (Metal's texture limit on M1) are shown
  downscaled to fit the limit.
- RAW renders: one at a time, in a slot of their own beside the three
  decode slots, because the RAW engine adds about 1.6 GB of footprint per
  full-resolution 24 MP render (0.8 GB screen-sized) and holds it for about
  five seconds. Only the nearest RAW neighbour is prefetched as a render,
  and on Macs with 8 GB of RAM or less none is (embedded previews still
  are).

### 4.6 Catalog

One SQLite database (system `libsqlite3`, no wrapper library) in the app's
Application Support folder stores ratings, labels, tags and custom sort
order. Each row keeps the path and the file's APFS file identifier, so a
file moved in Finder is found again by identifier and its path healed.
Tags are also written as Finder tags so they show up in Finder and
Spotlight. JPEG comments are written into the file itself.

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
   (Lanczos) is made from it and cached.
2. While a slider moves, the graph runs on the proxy and renders straight
   into a mipmapped texture the canvas shows. Target: under 16 ms per
   update for colour and tone operations on a 24 MP photo.
3. When the slider settles, or the user zooms past the proxy, the graph
   renders at full resolution in the background and replaces the texture.
4. Saving renders at full resolution into a CGImage with the chosen colour
   profile and encodes with ImageIO.

**Resampling filters (11):** Box, Triangle (bilinear), Hermite, Bell,
B-Spline, Mitchell–Netravali, Catmull-Rom, Cosine, Quadratic, Lanczos 3,
Lanczos 8. One separable Metal kernel evaluates any of them: two passes
(horizontal, vertical), taps computed in the shader from the filter's
support widened by the downscale factor, weights normalised, filtering in
linear light.

**Undo:** the operation list with a cursor, capped at 50 steps. Undo is a
cursor move plus a re-render, so it costs no memory for pixels. Brush
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
After an in-place save the file holds the edits, so a document is never
decoded again from it (that would apply them twice); reloading means a new
document, and undo history starts over after a save. As a safety net each
document records the file's modification date and size at its first
decode, and the renderer refuses to decode a changed file for it again.
Quitting asks about unsaved edits and waits for queued writes to finish.
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

Known limits: saving an HDR photo in place writes tone-mapped SDR; Colors
and RGB changes made in one visit to the Colors tool are two undo steps.

## 5. User interface

Loosely FastStone's layout, in current macOS style (unified toolbar, SF
Symbols, sidebar materials, system appearance).

**Browser window:** folder sidebar (favourites, then the folder tree) |
thumbnail grid | preview pane with file info and EXIF. Toolbar: back,
forward, parent folder, sort, thumbnail size, filter, slideshow, compare.

**Ratings and tags.** Each image has 0–5 stars and FastStone's "tagged"
flag for culling. A grid cell shows its stars under the name (hollow stars
appear on hover, and a click rates; clicking the current rating clears it),
a checkmark badge on the picture's corner when tagged, and its Finder tag
dots after the name. The preview pane shows the lead photo's stars and a tag
button under it; the viewer's HUD shows both. Toggle Tag on a mixed
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
never replaced). The work runs off the main thread one file at a time,
with a progress sheet and Cancel for more than 20 files or anything still
running after half a second; the arrivals are selected afterwards.
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
(borderless, instant, on the current display). In full screen the edges
reveal fly-out panels on hover:

| Edge | Panel |
|---|---|
| Top | filmstrip of the folder |
| Left | edit and effect tools |
| Right | file info, EXIF, histogram |
| Bottom | zoom, navigation, slideshow controls |

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
| | Play/Pause Animation | P (display) |
| | Rating > Clear, 1–5 Stars | ⌃0–⌃5 (the grid and viewer also take bare 0–5) |
| | Toggle Tag | ⌘T (no tabs or Fonts panel to clash with; bare `` ` `` in the grid and viewer, T in the viewer) |
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
  fades out at the end. Space pauses, arrows step, Esc ends; the pointer
  hides and a small control bar appears when it moves. Next images decode
  ahead through the image loader.
- *Batch Convert:* output format and its options (the Save As options),
  destination folder (chosen, or beside the originals), file names from a
  rename pattern, and optional resize (long side, width, height or percent,
  with any of the 11 filters), rotate/flip and keep-metadata. Runs off the
  main thread, a few files at a time, with progress, Cancel and a summary of
  files that failed; never replaces an original unless asked.
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
  (grid or scattered, spacing, background), saved to Pictures/minivu
  Wallpapers and set as that display's desktop picture. Set as Desktop
  Picture uses a single image as it is.
- *Capture:* the entire screen, a window picked with the system's content
  picker, or a dragged selection, through ScreenCaptureKit, saved as PNG to
  Pictures/minivu Captures and opened in the viewer.
- *External editors:* a list in Settings > Editors of applications chosen
  by the user; each opens the selected images or the image shown, and the
  viewer reloads a file an editor saved.

**Themes:** Light, Gray, Dark, or follow the system.

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

| Phase | Deliverable |
|---|---|
| 1 | Skeleton: package, app bundle, sandbox, Metal shader loading, tests |
| 2 | The viewer: browser, thumbnails, canvas, zoom and pan, magnifier, full screen with fly-outs, EXIF, themes, preferences |
| 3 | Formats and HDR: RAW refinement, gain maps, PDF pages, SVG, animation, multi-page TIFF |
| 4 | Editing core: undo/redo, resize with 11 filters, rotate, flip, crop, sharpen, blur, lighting, colour, curves, levels, colour effects, Save As with quality preview, JPEG comments |
| 5 | Management: ratings, tags, drag and drop, rename, histogram with colour count, compare up to 4 |
| 6 | Effects, drawing, clone stamp, healing brush, red-eye |
| 7 | Tools: batch convert and rename, slideshow (8 transitions, music), contact sheet, montage wallpaper, print, screen capture, external editors |
| 8 | Polish: dual display, shortcuts, documentation |

## Appendix: Phase 7 implementation notes

Written by the implementer and the reviewer of each package when it was built. Section 5 has the user-facing summary.

### Batch Convert and Batch Rename

Proposed DESIGN.md text (section 5, Tools, or 4.7):

Batch Rename. A RenamePattern (MinivuCore) is text with tokens: {name}; {#}/{###} for the counter (the digits setting is a minimum, and the larger of it and the token's own count wins; start and step can be set); {date[:format]} for the date taken (EXIF DateTimeOriginal, else DateTimeDigitized, else the modification date, formatted in the camera's EXIF offset zone when one is recorded); {modified[:format]}; {width} {height} as displayed; {ext}. Keywords work in any letter case; the format is a Unicode date pattern, yyyy-MM-dd by default, with the en_US_POSIX locale and the Gregorian calendar so names are the same on every Mac. The order is: tokens, then plain-text find and replace (optionally case-sensitive), then the name's letter case; the extension (the original's, or the converter's) goes on last in its own case. Unknown tokens stay visible in the preview and block Rename. EXIF is read only when the pattern uses dates or sizes, once per sheet, several files at a time.

RenamePlanner checks everything before any change, one lstat per file and per new name: invalid names (FileOperations' rules), two files getting the same name (compared as APFS compares names: Unicode normalisation always ignored, letter case ignored on case-insensitive volumes), a name held by an item outside the batch, and a source that has gone. A name held by another file of the batch is allowed. The sheet plans off the main thread, and batches of 300 or more wait 150 ms after typing stops.

BatchRenamer carries out the renames with exclusive rename(2) through FileOperations.rename. A file waits until its new name has been freed; when a name is freed, the file waiting for it goes next. Only a cycle (a swap or a longer ring) can't be ordered: one file of the ring steps aside under a hidden temporary name and takes its final name last. So a crash part way leaves at most one hidden file per ring, and if a temporary file can't take its name it goes back under its own name, or a numbered one, never left hidden. A failure releases the files waiting on that file, which then fail rather than wait forever.

Catalog.fileMoved keeps stars and the Custom Order place for every step, temporary names included, so a swap swaps places. Undo is the same operation with every pair reversed, run with restoring (names checked only to be free): one undo step "Rename N Items" whose record is filled in when the work ends, as TransferRecord does.

Batch Convert. BatchConvertSettings (MinivuRender, Codable, defaults for missing keys) holds ExportOptions, destination (.besideOriginals or .chosenFolder with a security-scoped bookmark), naming (.keep or .pattern), the existing-file policy (skip, keep both, replace to the Trash), resize (long side, width, height or percent, any of the 11 filters, don't enlarge), quarter turns and flips. Operations run turn, then flip, then resize, so a width or long side is the output's. A format change with no operations decodes with ImageIO at full resolution with the orientation baked in and hands the pixels to the encoder (exact pixels, as Save As does for an unedited original). Operations, and every RAW file, go through an EditDocument.Snapshot into EditRenderer.renderForExport: EditGraph plus the resampling kernel, RAW through loadRaw with the viewer's RAW decoding setting, always SDR. Colour: a named profile, or for Keep original the Save policy's render space (the source's own, P3 for RAW and HDR); formats without profiles get sRGB. Metadata keep or strip goes through ImageEncoder (orientation reset to 1).

BatchOutputPlanner settles every clash before anything is written. Outputs of one batch never share a name, and an output never lands on another source of the batch; both cases are numbered as "photo 2.jpg" whatever the policy. An existing file follows the policy. Replacing the output's own source is flagged, and the app asks "Replace N originals?" with Cancel as the default button before starting. A folder is never replaced.

BatchConvertJob works on 2 files at a time (1 on Macs with 8 GB or less) and at most one camera RAW at a time on any Mac, because of the RAW engine's roughly 1.6 GB per render. Each file is decoded, rendered and encoded on GCD threads through BatchWorkExecutor, a TaskExecutor used as the task executor preference so the async renderer runs on dispatch threads and not Swift's cooperative pool. Encoding happens before queueing, so conversions stay parallel while the write itself goes through FileWriteQueue.shared (replacing: destination). BatchFileWriter writes the complete file to a hidden sibling, fsyncs it, then renames it into place with RENAME_EXCL. If something has taken the name since planning, the policy applies again. Replace writes the new file first, then moves the old one to the Trash, then renames the new one in, and brings the old one back if that last step fails. Cancel stops new files starting and drops any file whose encode finishes afterwards; a write already queued completes, and writes are atomic, so only whole files remain. The summary alert lists failed and skipped files with reasons, up to 8 of each. Outputs in the folder shown are selected afterwards, and caches are invalidated for every written file. The chosen folder stays security-scoped for the whole run.

Known limits: only the first page or frame of multi-page and animated files is converted. A replaced file's marks stay with the old file in the Trash (as with Copy and Replace). Each file's rename posts its own Catalog.didChange, so renaming thousands of files sends thousands of small main-queue updates.

Additions or corrections to the implementer's proposed DESIGN.md text (section 5, Tools):

- Marks when replacing. The Trash step moves only the file; the batch writer decides what happens to the marks. When the user has confirmed replacing an original with its own conversion, the new file keeps the stars, tag and Custom Order place under the same name, as Save does. If only the letter case of the name changed, the marks follow the new name. Any other replaced file (an earlier export, or a file that isn't part of the batch) takes its marks to the Trash, as Copy's Replace does. Moving marks twice deletes them: the second move finds the new file under the old path and clears its rows first.

- Sources by identity. The output planner recognises the other sources of the batch by path and by file identity. An output that would land on one of them gets a numbered name whatever the policy, even when the chosen folder is a source folder under another path. Only an output's own original can be replaced, and only after "Replace N originals?" is confirmed.

- Batch renames in a window run one after another. Each undo or redo waits for the batch before it and reads the names to put back only when it starts, so pressing ⌘Z ⇧⌘Z quickly never loses a step or renames the same files twice at once. After a rename, only the folder shown is listed again.

- Cancel also stops a camera RAW that is still waiting for the one-RAW slot, so it isn't rendered only to be thrown away.

- Convert sheet. A resize to 0 px or 0% (or past 32768 px or 1000%) disables Convert and says why. The chosen folder's security-scoped bookmark is kept rather than made again, and a stale one is refreshed while access is open.

- Known limits to add:
  - With the Replace policy, existing files outside the batch go to the Trash without a separate confirmation, and the summary doesn't count them.
  - Each rename is one catalog transaction and one Catalog.didChange. With the in-memory catalog, 5000 renames took 1.5 s and their undo 4.2 s, and the main thread never stalled more than about 120 ms.

### Slideshow

Suggested DESIGN.md text (section 5, the Tools > Slideshow bullet, and section 4):

- **Rendering.** `SlideshowRenderer` (MinivuRender/Slideshow) draws one full-screen triangle. A single fragment shader (`slideshowFragment` in Slideshow.metal) switches on a transition index; the order of `SlideshowTransition`'s cases is that index, and its raw values are what settings store. Each slide is aspect-fit in whole pixels on black. Small images follow the viewer's "enlarge small images" setting. Mip level comes from texels per screen pixel.
- **Where motion happens.** Slide, push and zoom move or scale the slide's rectangle on the CPU (`SlideshowGeometry`, unit tested). The shader only decides how much of the new slide each pixel shows:
  - slide and push: a half-pixel antialiased edge;
  - wipe and iris: a soft edge 3% of the short side wide, which starts beyond the screen so t=0 and t=1 show exactly one slide;
  - iris: measured in pixels, so the circle is round on any screen;
  - dissolve: two octaves of value noise from an integer hash, 9 cells across the short side, with a ±0.08 band.
- **Timing and HDR.** Progress is eased with smoothstep, so t=0.5 stays 0.5. Pixels that are wholly old or wholly new sample only one texture. Each slide is tone mapped to the display headroom with its own content headroom before mixing, so an HDR and an SDR slide each keep their look.
- **Cost.** 1.0–2.5 ms a frame at 5K on M4. `toneMapToHeadroom` now lives in Common.h so any shader file can use it.
- **Playback.** `SlideshowWindowController` opens a borderless, normal-level window on the originating window's screen. Menu bar and Dock are hidden while it is key, as in the viewer's full screen. The pointer hides until it moves.
  - Between slides nothing renders: one DispatchWorkItem waits out the interval, counted from the end of each transition. The display link runs only during a transition.
  - The next and previous slides load through `ImageLoader.shared.load` at the screen's long edge in pixels, and only those textures are kept.
  - If the next slide isn't decoded yet, the move waits for it. A file that fails is marked in `SlideshowSequence` and skipped in both directions; if nothing can load, the show ends.
  - → and ← finish any transition under way at once and start a quick one.
  - Caption metadata (MetadataReader.summary) is read ahead for the neighbours, off the main thread.
  - ProcessInfo.beginActivity([.idleDisplaySleepDisabled, .userInitiated]) runs for the life of the show.
  - EDR is on only while an HDR slide is on either side of a transition, Show HDR is on, and the screen can show some of it.
  - When the show ends the viewer moves to the last slide shown, through its normal navigation.
- **Order.** Shuffle puts the starting image first and the rest in an order fixed for the run; a loop repeats that order. A single image never transitions into itself.
- **Settings.** `SlideshowSettings` is one Codable value under the key "slideshowSettings" in `SlideshowSettingsStore`, which tests build on a scratch defaults suite. Each field falls back to its default when missing or unreadable, and numbers are clamped: interval 1–60 s, transition duration 0.3–3 s, volume 0–1. A running show reads interval, transition and caption style afresh for each slide; order, loop and music are fixed when it starts.
- **Music.** `SlideshowAudioPlayer` is the only file that imports AVFoundation, behind `SlideshowAudioPlaying`. `SlideshowMusic` resolves the playlist's security-scoped bookmarks off the main thread; a folder adds the MP3, AAC/M4A, WAV and AIFF files directly inside it, by name. It holds access until it stops, plays in order or shuffled round and round, drops songs that won't open, fades in over 1 s, pauses with the show, mutes with a 0.25 s ramp, and at the end fades out over 1.5 s before stopping and releasing the files. It outlives the closed window for that fade.
- **Settings pane.** The preview is a small Metal view using the same shader, between two drawn pictures. It rests at the halfway point; changing the transition or duration, or clicking it, plays it once, holds the new picture 0.7 s and settles back. Its display link runs only while playing.
- **Snapshot switches (debug only).** `debugFreezeSlideshowTransition:` reads MINIVU_DEBUG_TRANSITION (default iris), MINIVU_DEBUG_PROGRESS (default 0.5) and MINIVU_DEBUG_CAPTION (none, name, nameAndDate, exif), and pins the control bar up. `debugShowSlideshowSettings:` is on AppDelegate.
- **Known limits.**
  - Resuming after a pause waits a full interval.
  - A caption longer than the space left of the control bar is truncated in the middle.
  - Changing HDR or RAW settings mid-show refreshes the neighbours, but the slide on screen stays until the next one.

Suggested additions to the slideshow notes in DESIGN.md (on top of the implementer's):

- **When a show ends.** `SlideshowSequence.isOverAfterCurrent` decides it. A show ends after its last slide only when Loop is off, or when nothing can play at all. A looping show whose only playable slide is on screen (a single image, or every other file failed) keeps showing that slide, doing nothing, until the user leaves. The arrow keys at either end of a show that doesn't loop only bring up the controls.
- **Captions.** A caption that needs metadata (name and date, or EXIF) fades out until that slide's metadata has been read, usually ahead of time. The previous slide's caption never stays under a new slide, and a file name never flashes before the camera line.
- **Closing.** Esc, a click outside the control bar, the close button and File > Close Window (⌘W) all end the show. The borderless window enables Close Window itself, because AppKit only enables it for windows with a close button. The viewer's borderless full-screen window needs the same.
- **Control bar.** Its buttons never take keyboard focus, so Space always pauses and resumes, even with keyboard navigation turned on.
- **Music files.** Security-scoped access to playlist files is always paired: if the show ends while bookmarks are still resolving, the files are released as soon as resolution finishes, even though the music object is gone. Bookmarks that resolve stale (a moved or renamed song or folder) are made again while access is held and saved to Settings, as BookmarkStore does.
- **Stepping.** A move waiting for its image to decode is cleared before the texture is requested, so a cache hit that answers at once can't run the same move twice.
- **HDR.** Tests pin the slideshow's tone map to the canvas: an HDR slide at any display headroom looks exactly as the viewer shows it, and a cross-fade mixes each slide as it would look alone.
- **Known limit (shared with the viewer).** On notched displays the window covers the whole screen, so the camera housing can hide the top of a slide.

### Print and Contact Sheets

Suggested DESIGN.md notes (Phase 7, Print and Contact Sheet):

- PageLayout (MinivuCore/Layout) is the one piece of page geometry. It is pure and in page units (points for print, pixels for contact sheets), with a top-left origin and a `flipped` helper for Core Graphics. It covers the grid inside margins, header and footer bands, a caption band at the bottom of each cell, and fit or fill. Auto-rotate turns a picture when the turned shape covers more of the cell; that single measure (narrower aspect over wider) is both less empty space for fit and less crop for fill. Pages holding fewer pictures than cells can centre them (print does, contact sheets don't). Images-per-page choices become the exact grid whose cells are closest to square (portrait: 2 is 1×2, 6 is 2×3, 12 is 3×4, 20 is 4×5, 30 is 5×6).
- One CG renderer (Tools/Print/LayoutRendering.swift) draws a page into any y-up context: printer, bitmap or PDF. It decodes four cells at a time with concurrentPerform and draws each batch as it arrives, so memory is one page plus four pictures. LayoutImageProvider is a thread-safe LRU bounded by bytes. It reuses a decode from 0.97× to 2× the size wanted and uses ImageIO's thumbnail route up to 512 px (embedded RAW previews, fast HEIC), the display decode above that; HDR comes out as SDR. Captions are Core Text lines, shortened in the middle, in dark or light text depending on the background.
- Print uses a copy of NSPrintInfo.shared with zero margins, so Page Setup's paper, scale and printer apply and each page rect is the whole sheet. After a successful print the paper and printer chosen in the panel are written back to NSPrintInfo.shared. The page view's knowsPageRange, rectForPage and draw are nonisolated overrides that touch only a locked PrintJob, which is what makes canSpawnSeparateThread safe under Swift 6. Pages are stacked at a fixed 100 000-pt pitch so page rects never depend on the view's frame, which can't change off the main thread. The layout is rebuilt from the running operation's printInfo in knowsPageRange, so panel paper and orientation changes follow.
- Print decode sizes: the cell's draw rect × printer dpi/72 × scale, with dpi clamped to 150–600 (from PMPrinter, else 300) and the long edge capped at 6000 px. The preview never decodes on the main thread: it draws cached ≤384 px pictures and grey placeholders, decodes the missing ones in the background, then bumps the accessory's KVO `layoutRevision` (its keyPathsForValuesAffectingPreview) to redraw.
- The viewer prints the edited render (renderForExport in Display P3, 8-bit) when the document is dirty, otherwise the file and page shown.
- Contact sheets: A4 and Letter presets are 300 dpi, so a PDF's media box is the paper size; 4K and Custom are one point per pixel. Rows "Auto" puts every picture on one page. The preview renders page 1 at a 600 px long edge, 150 ms after the last change, cancelling any older render, with its own small cache. Saving asks with NSSavePanel for a PDF or single page and NSOpenPanel for a folder of pages. Page names ("<base> 1.jpg"…) are chosen so none exists, before anything is written. Pages are made in the volume's item-replacement folder and moved into place through FileWriteQueue. Cancel leaves nothing, and a file that appears in the meantime keeps its name. PDF pictures are JPEG-backed CGImages, which Quartz embeds as-is.
- Known limits: a print on paper smaller than the unprintable edges gets empty cells; Page Setup scales below 10% are treated as 10%.

Suggested additions to DESIGN.md (Phase 7, Print), on top of the implementer's notes:

- Print pagination facts, measured by printing to PDF through NSPrintOperation:
  - When a view answers knowsPageRange, AppKit puts each rectForPage rectangle's corner at the corner of the printable area, at 100%, whatever NSPrintInfo.scalingFactor says.
  - So the print view's page rectangle is exactly the printable part of the sheet, in sheet points, offset by the unprintable edge. Content drawn there lands where it is on paper.
  - draw applies Page Setup's scale itself: the layout is built at paper/scale and drawn scaled down.
  - The layout's margins are never smaller than the printer's unprintable edge.
  - PrintTests prints to a PDF with no printer or panel, to guard all of this.
- Page Setup after a print takes only the printer, paper, orientation and scale from the job. Copies, page range and destination (a PDF's file, Preview) stay with that job.
- LayoutImageProvider cache rule: an entry serves any request up to the size it was decoded for, and up to half its own long edge. Decodes more than twice the size asked are shrunk before they are kept. This makes a decode the preview asked for always a hit on its next redraw; without it a JPEG 1/8-scale snap or a small RAW preview made the preview decode forever. A thumbnail counts as full resolution only when the file itself is that small.
- Preview decodes run on one serial queue per print job, four pictures at a time.
- The panel draws previews only for the pages it shows.
- Contact sheet names:
  - The header text is made a safe file name before it names pages: "/" and ":" become "-", control characters and leading dots are removed, and the length is capped at 200 bytes.
  - A custom page size is exactly the width and height typed; Orientation applies to presets only.
  - PDF pages are capped at 14,400 pt (200 in) per side.
- Contact sheet dialog and saving:
  - Numbers typed out of range are clamped in the dialog, so what it shows is what is made.
  - Cancelling the save panel returns to the dialog.
  - If placing a page fails, the pages already placed by that save are removed. A file replaced after the user chose Replace stays in the Trash.
  - Moves and trashing run on GCD (BlockingWork) inside the FileWriteQueue job.
- Known limit: the print preview is recognised by the class name of its graphics context (NSPrintPreviewGraphicsContext). If a future macOS renames it, the preview decodes at print quality on the main thread.

### Montage, Desktop Picture, Capture and External Editors

Proposed additions for DESIGN.md, under "Tools (Phase 7)":

- *Montage Wallpaper:* three layouts, pure geometry in MinivuCore/Montage/MontageLayout. **Grid**: the columns and rows whose cell shape is closest to the photos' median shape, with the fewest spare cells; photos fill and are cropped to their cells, and spare cells repeat photos. **Mosaic**: justified rows (a photo joins a row while that brings the row's width closer to the target), each scaled to span the margins exactly with every photo keeping its shape. The row count is the one whose total height comes closest to the screen, and the rows are centred. When a few wide photos can't fill the height, photos repeat from the first, at most once each. **Scattered**: rows filled edge to edge with one cell per photo. Each print is 1.3× its cell, jittered, tilted up to 12°, has a border of 4% of its shorter side, and stays inside the margins. Placement, tilt and drawing order come from a SplitMix64 seed, which Shuffle replaces. Spacing is set in points and multiplied by each display's scale. The sheet's preview uses the browser's 256/512 px thumbnails (at most 200), redraws 50 ms after the last change, one at a time, and lays out off the main thread. The wallpaper is drawn with Core Graphics in 8-bit Display P3 at frame × backing scale. Photos are ImageIO thumbnails at the long edge their largest tile needs, decoded four at a time, drawn in order and released after their last tile. The result is a JPEG at quality 0.9, written through FileWriteQueue as "Montage yyyy-MM-dd at HH.mm.ss[ (n)].jpg", then set per display.
- *Set as Desktop Picture:* the wallpaper agent opens the file itself, later and after every restart. A JPEG, PNG, HEIC or TIFF inside Pictures (by real path) with no unsaved edits is used as it is. Anything else is exported to Pictures/minivu Wallpapers as "Desktop <timestamp> <name>.jpg" (HEIC when transparent), decoded in SDR no larger than twice the screen's long edge; unsaved edits go through renderForExport. Options are scale proportionally with clipping allowed. Only the newest 10 copies are kept, never one still on a screen, and montages are never pruned.
- *Capture:* ScreenCaptureKit behind `ScreenCapturing`. Tests and snapshot runs get a capturer that never records or asks. Entire Screen captures the display under the pointer at its pixel size, without minivu's own windows (matched by process ID). Window… uses SCContentSharingPicker in single-window mode and sizes the capture from the filter's contentRect × pointPixelScale. Selection… puts a borderless, transparent overlay at screen-saver level on every screen: 35% dim, crosshair, white outline, a size label in pixels, selection snapped outwards to whole pixels; Esc cancels, Return or mouse-up captures. The overlay closes before capture. The rectangle is converted to display-local top-left points for sourceRect, and its size × scale gives the output pixels. When permission is denied, an alert points to System Settings > Privacy & Security > Screen & System Audio Recording with an Open System Settings button; the first attempt may also show the system's own prompt. Captures are 8-bit PNGs, "Capture yyyy-MM-dd at HH.mm.ss.png" in Pictures/minivu Captures, and open in the viewer. HDR captures (float capture with a gain map) are future work.
- *External editors:* an ordered list in its own defaults key (name, bundle identifier, path, app-scoped bookmark when chosen in the open panel). The app is found by bookmark, then path, then bundle identifier. The menu is rebuilt when the list changes, not in menuNeedsUpdate, because AppKit looks up key equivalents without updating menus. Settings > Editors has icons, move up/down, drag reorder, remove, Add… (open panel in /Applications), and suggestions: apps that open JPEG and are either known image editors or claim the Editor role for images, excluding Apple's other apps and minivu. The browser opens the selected images or the lead image, never the whole folder, and asks above 20. The viewer opens the image shown and warns when unsaved edits won't reach the editor. Files sent to an editor are watched with one FSEvents stream per folder (the 8 most recent folders). When a watched file's date or size changes, its caches are dropped and the viewer reloads it if shown, keeping zoom when the size is unchanged. Unsaved edits made in minivu stay on screen, and a clean edit session is ended first.
- Known limit: after an external save the viewer's stored entry keeps the old date and size, so its info panel and colour-count cache lag until you move to another image.

Additions for DESIGN.md, under Tools (Phase 7), on top of the implementer's notes:

- *Montage rendering:* decoding and drawing both run on GCD. Each group of up to 4 tiles is decoded concurrently, then drawn in one BlockingWork job into the single bitmap context. One job at a time, so the context is never shared between threads; the final makeImage runs there too. The cooperative pool only coordinates.
- *Montage cancel:* a write already queued can't be stopped. Cancel is therefore checked again after each montage is written; on cancel or failure the files that run wrote are deleted through the write queue (minivu's own files that no desktop shows yet), so a cancelled montage leaves nothing in Pictures/minivu Wallpapers.
- *Harness:* debug actions that change a remembered choice (montage layout) don't save it, so snapshots are repeatable and the user's next sheet isn't changed.
- *Capture exclusion:* the capture lists all windows (not only on-screen ones) and excludes minivu as an application (SCContentFilter(display:excludingApplications:exceptingWindows:)), with its own windows as the fallback. The selection overlay and the menu that chose the command are ordered out moments before, and a window appearing mid-capture must be left out as well.
- *Permission:* when screen recording is denied, minivu explains with its own alert, except on the very first request (remembered in defaults), when the system shows its own prompt. The two are never stacked.
- *Selection overlay across screens:* the window under a new drag becomes key, so Return and Esc act on that rectangle. The crosshair uses cursorUpdate tracking areas, because cursor rects only work in the key window. The arrow is restored on close. Switching to another app cancels, so dimmed screens never outlive the user's attention.
- *External edit watcher:* stamps are read after the previous comparison has finished, so one save is reported once. A watched file that is missing (renamed, moved, deleted, or mid-save) isn't reported, and keeps its old stamp until it comes back changed.
- *Known limits:*
  - An in-place ⌘S after an editor saved over a file with unsaved minivu edits replaces the editor's version (the user was warned when the editor opened).
  - Desktop picture copies on other Spaces can be pruned.
  - The mosaic can leave or crop about 4% at the top and bottom, because photos keep their exact shapes.
