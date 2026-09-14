# Agate design

Agate is a lightweight image browser, viewer and editor for Apple Silicon
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
  signs `build/Agate.app`, as in Latent.
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

`AgateCore/ImageFormats.swift` is the single list of extensions the
browser shows. Anything ImageIO can open is viewable; the list only
decides what appears in folders.

## 4. Architecture

```
Agate (app, AppKit + a little SwiftUI)
  ├── AgateRender   Metal: textures, canvas presenter, kernels, transitions
  │     └── AgateCore
  └── AgateCore     decoding, metadata, folders, catalog, thumbnail cache
```

Three modules, one process. `AgateCore` has no GPU and no windows, so its
tests run in milliseconds. `AgateRender` owns every Metal object. The app
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
   scaling), which is several times faster than a full decode. RAW files
   use the camera's embedded preview for this step. EXIF orientation is
   applied here.
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

`ImageCanvasView` (app) + `CanvasRenderer` (AgateRender):

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
  app's Caches folder, keyed by path, size and modification date.
- Images above 16384 px on a side (Metal's texture limit on M1) are shown
  downscaled to fit the limit.

### 4.6 Catalog

One SQLite database (system `libsqlite3`, no wrapper library) in the app's
Application Support folder stores ratings, labels, tags and custom sort
order. Each row keeps the path and the file's APFS file identifier, so a
file moved in Finder is found again by identifier and its path healed.
Tags are also written as Finder tags so they show up in Finder and
Spotlight. JPEG comments are written into the file itself.

### 4.7 Editing

Non-destructive until saved. An `EditDocument` holds the decoded original
and an ordered list of `EditOperation` values; undo and redo move a cursor
through that list. The list compiles to a Core Image graph rendered on
Metal: at screen resolution while a slider moves, at full resolution when
saving. Operations Core Image doesn't have (the eleven resampling filters,
oil paint, lens, clone, heal, red-eye) are Metal compute kernels wrapped in
`CIImageProcessorKernel`, so they join the same graph. Drawn objects (text,
lines, callouts) stay editable as vectors until the image is saved.

## 5. User interface

Loosely FastStone's layout, in current macOS style (unified toolbar, SF
Symbols, sidebar materials, system appearance).

**Browser window:** folder sidebar (favourites, then the folder tree) |
thumbnail grid | preview pane with file info and EXIF. Toolbar: back,
forward, parent folder, sort, thumbnail size, filter, slideshow, compare.

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
End first and last, Return toggles full screen, Esc back to the browser,
`+` `-` zoom, `/` actual size, `*` fit, 0–5 rating, ⌘Z / ⇧⌘Z undo and redo.

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
