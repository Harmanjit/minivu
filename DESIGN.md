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
saving. Operations Core Image doesn't have (the eleven resampling filters,
oil paint, lens, clone, heal, red-eye) are Metal compute kernels wrapped in
`CIImageProcessorKernel`, so they join the same graph. Drawn objects (text,
lines, callouts) stay editable as vectors until the image is saved.

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
| Window | Minimize | ⌘M |

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
