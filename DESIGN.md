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
- No import step. Nothing is indexed ahead of time. A folder tree is read
  only when the user asks for it (the flat view, Find, a smart folder),
  off the main thread, and the read is cancelled when the user moves on.
  The only thing kept is what a search read, in the catalog, so the next
  search of the same files reads nothing.
- Readable in the user's language: the interface and the help pages ship
  in English and ten other languages (4.13).

**Non-goals** (decided 2026-09-13, widened where noted)

- iPad, iPhone, other operating systems.
- Network access of any kind. The sandbox has no network entitlement.
  The share sheet, Live Text and the Shortcuts actions keep this: share
  services run in their own processes and read the files minivu hands
  them; text recognition runs on the Mac; App Intents run inside minivu's
  own process and sandbox.
- Removable or external media: SD cards, USB drives, network volumes.
  `VolumePolicy` refuses them almost everywhere: browsing, file
  transfers, the Shortcuts actions, the slideshow video, the web gallery,
  Batch Convert and multi-page files. Save As and Contact Sheet don't
  check yet (section 8).
- Formats without a native macOS decoder (PCX, WMF, EPS, X3F, WMA).
- Portable mode, scanners, touch screens, email tools, multiple app
  instances.
- A full RAW developer. minivu offers the RAW engine's own settings
  (Image > Adjust > RAW Adjustments…) and nothing more: no curves, masks,
  profiles or lens corrections of its own (widened 2026-11-14, G10).
- Video editing, trimming, conversion or export of movies. Videos are
  shown and played; nothing writes them (widened 2026-11-14, G18).
- An AppleScript dictionary, Services menu entries or a Quick Look
  extension. Shortcuts actions (App Intents) are the automation surface
  (4.8, "Automation").

## 2. Platform

- **macOS 15 (Sequoia) minimum.** Every M1 Mac runs it, and it brings JPEG XL
  decoding, HDR gain-map decoding and `CGImage` content headroom.
- **Metal 3 feature set** (Apple7 GPU family), which M1 has. Nothing
  M3-only.
- **Swift 6.2 or later** (tools version 6.2), strict concurrency. The app
  target defaults to the main actor; background work is explicitly
  `nonisolated` or in actors.
- **SwiftPM, no Xcode project.** `scripts/make_app.sh` assembles and
  signs `build/minivu.app`, as in Latent. It builds with Swift Build
  (`--build-system swiftbuild`, SwiftPM's default engine since Swift 6.2),
  and copies the three resource bundles (MinivuCore's and MinivuRender's
  String Catalogs and shaders, the app's help pages) into
  Contents/Resources, where `Bundle.module`, `Bundle.minivuRender` and
  `Bundle.minivuHelp` look first. It also:
  - copies the app bundle's `.lproj` folders into the main bundle, since
    SwiftUI's `Text("…")` looks in `Bundle.main`, and writes
    `CFBundleLocalizations` with all eleven languages (4.13);
  - runs `appintentsmetadataprocessor` over the compiler's
    `.swiftconstvalues` records and writes
    Contents/Resources/Metadata.appintents, which is how Shortcuts finds
    minivu's actions. It stops if the records or the actions are missing,
    so a toolchain change can't ship an app whose actions have vanished.
- **App Sandbox + hardened runtime**, ad-hoc signed. Entitlements: user
  selected files (read-write), app-scoped bookmarks, the Pictures folder,
  printing. No network. No entitlement was added for Share, Live Text,
  Vision, App Intents or the watermark's picture bookmark.

## 3. Formats

All decoding goes through Apple frameworks:

| Formats | Decoder |
|---|---|
| JPEG, PNG/APNG, GIF, HEIC/HEIF, AVIF, WebP, JPEG XL, JPEG 2000, TIFF, BMP, TGA, ICO, CUR, PSD (flattened) | ImageIO |
| CR2 CR3 CRW NEF NRW PEF RAF RWL MRW ORF SRW ARW SR2 SRF RW2 DNG, and the rest of Apple's camera list | ImageIO (Apple RAW) |
| PDF | PDFKit / CGPDFDocument |
| SVG | AppKit (`NSImage` SVG rep) |
| MOV, QT, MP4, M4V, 3GP, 3G2, MTS, M2TS, MPG, DV (videos) | AVFoundation (frames), AVKit (playback) |

`MinivuCore/ImageFormats.swift` is the single list of extensions the
browser shows. Anything ImageIO can open is viewable; the list only
decides what appears in folders. Videos are `ImageFormats.videoCandidates`
intersected with the movie types `AVURLAsset.audiovisualTypes()` reports
(`videoExtensions`, worked out once). Not everything AVFoundation reports
counts: subtitles, audio, "ts" (usually TypeScript) and AVI (whose codecs
it mostly can't play) are left out.

**Writing.** Save As and Batch Convert write JPEG, HEIC, AVIF, PNG, TIFF,
JPEG 2000, GIF, BMP, TGA and ICO. AVIF is offered only where ImageIO can
write it (`ExportFormat.isWritable`, asked once a launch); macOS 27 can.
ImageIO reads WebP and JPEG XL but can't write them. Create Multi-Page
File writes multi-page TIFF, PDF, animated GIF and animated HEIC (where
ImageIO lists `public.heics`). Animated AVIF is not offered: ImageIO
can't make a multi-image AVIF destination.

## 4. Architecture

```
minivu (app, AppKit + a little SwiftUI)
  ├── MinivuRender   Metal: textures, canvas presenter, kernels, transitions,
  │     │            edit renderer, batch converter, slideshow video writer
  │     └── MinivuCore
  └── MinivuCore     decoding, metadata, folders, catalog, thumbnail cache,
                     search, duplicates, web gallery pages, signposts
MinivuTestWatchdog   C, test-only: ends a test run whose cooperative pool
                     is starved (4.12)
```

Three modules, one process. `MinivuCore` has no GPU and no windows, so its
tests run in milliseconds. `MinivuRender` owns every Metal object. The app
owns windows, menus and the glue. Folders worth knowing:

- MinivuCore/Search: `TreeEnumerator`, `ImageSearch`, `SearchCriteria`
  (4.9).
- MinivuCore/Duplicates: `ContentHash`, `FeaturePrint`, `FingerprintCache`,
  `DuplicateFinder`, `SimilarityIndex` (4.8).
- MinivuCore/MultiPage, MinivuCore/WebGallery, MinivuCore/Export
  (`MetadataWriter`, `TIFFPageWriter`, `ImageEncoder`).
- MinivuRender/Batch: `BatchConverter`, `BatchEdits`, `BatchWorkExecutor`.
- Minivu/Automation: the Shortcuts actions (4.8).

### 4.1 AppKit first, SwiftUI for forms

The browser grid, folder tree and image canvas are AppKit:
`NSCollectionView` recycles cells and prefetches, so ten thousand files cost
the same as fifty; `NSOutlineView` loads folder children lazily; the canvas
is an `NSView` backed by a `CAMetalLayer` so we control exactly when a frame
is drawn. SwiftUI (hosted in `NSHostingView`) is used where it shines and
is not a hot path: the info panel, edit inspectors, preferences, dialogs,
the Find Duplicates window and the tool sheets.

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
   steps 3 to 5 don't apply. The "RAW files" setting (Embedded preview
   (faster) / Render RAW data) can render every time, and "Render RAW
   files with extended dynamic range" always renders, since embedded previews are SDR. A RAW file being
   edited with RAW Adjustments is developed with the tool's settings
   instead (4.7, "RAW settings").
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

**Videos** take the same path from step 3, with a frame in place of the
file's image. `VideoFrames` (MinivuCore) reads a video's size (turned by
the track's transform, so portrait phone videos are tall), length, frame
rate, codec, audio and HDR with AVFoundation's async `load`, and frames
with `AVAssetImageGenerator`, with `maximumSize` set to the size needed.
Callers are GCD threads (thumbnail workers, the image loader,
`BlockingWork`), which wait on a semaphore with a 10 s limit, so a damaged
file can't hold a worker. At most three frames decode at once
(`VideoFrames.frameSlots`). A thumbnail is a frame a little way in (a
second, or a tenth of a short clip), taken with a tolerance so a nearby
keyframe serves; the viewer's still is the exact first frame, where
playback starts. `VideoFrames.metadata` (data rate, recording date,
ISO 6709 location, make, model) is a separate read that only the info
panel and the filters pay for.

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
- **Videos:** with Settings > Viewer > "Display HDR photos in HDR" on,
  an HDR video's still is decoded with
  `dynamicRangePolicy = .matchSource` and shown with its highlights, like
  an HDR photo; otherwise it is tone mapped (`.forceSDR`). Thumbnails are
  always SDR. Playback HDR is AVKit's: `AVPlayerView` shows HDR on EDR
  screens. With that setting off, minivu asks for standard range with
  `preferredDisplayDynamicRange = .standard` on macOS 26 and later; macOS
  15 has no such API, and AVKit decides.
- **Live Text** reads an HDR texture tone mapped from its own content
  headroom (`CIToneMapHeadroom`), so text in bright highlights keeps its
  edges. That image is only analysed, never shown or written.
- **Output that stays SDR:** Save As, copies, Copy Frame, Save Frame As,
  multi-page files, image strips, web galleries (always sRGB), slideshow
  videos (Rec. 709, tone mapped by the slideshow shader at headroom 1) and
  captures. Save keeps gain-map HDR (4.7), and Batch Convert can (4.8).

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
- Layers above the canvas, bottom to top: the Live Text overlay
  (`ViewerContainerView.textOverlay`, 4.11), the video stage (the play
  button and, once asked for, the player, 4.10), then tool overlays, the
  HUD and the panels. The text overlay and the video stage pass clicks,
  drags, the wheel and press-and-hold through to the canvas wherever they
  have nothing of their own under the pointer.
- `ImageCanvasView.tracksPresentedFrames` (off in the app) adds a GPU
  completion handler per frame, so the benchmarks can wait for a photo to
  be drawn rather than set (4.14).

### 4.5 Memory

- `TextureCache` holds decoded textures with a byte budget (default: 1/8 of
  RAM, at most 1.5 GB) and evicts least recently used.
- Thumbnails: an in-memory `NSCache` plus an on-disk SQLite cache in the
  app's Caches folder, keyed by path, size and modification date. In
  memory they are redrawn on the worker as 8-bit BGRA in the screen's
  colour space, so Core Animation has nothing to convert on the main
  thread; on disk they stay JPEG or PNG. The same database (schema 2) holds
  a `fingerprints` table for Find Duplicates: SHA-256 hashes and Vision
  feature prints, keyed by file identity (volume UUID and file identifier,
  so a rename keeps them), valid while size and date match, at most 64 MB
  (oldest used dropped first). Settings > Thumbnails > Clear Thumbnail
  Cache empties both. Test runs and other private-catalog runs use a store
  of their own in the temporary folder (`AppServices.thumbnailStoreURL`),
  removed when the process ends.
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
- **Export budget.** Full-size decodes for export (Save of an original,
  Batch Convert, multi-page and strip outputs) are refused before decoding
  when the header is past a quarter of RAM (`exceedsExportBudget`). Batch
  Convert also refuses an output its operations would make past that, or
  past 32768² pixels (an enlarging resize, a frame or a shadow can grow it).
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
- The editor has RAW slots of its own (`RawRenderer.withEditRenderSlot`,
  `concurrentEditRenders`: one on Macs with 8 GB or less, two elsewhere, so
  a slider preview needn't queue behind a full render). On 8 GB Macs the
  viewer's RAW renders take the editor's slot too
  (`viewerSharesEditSlot`), so the whole app renders one RAW at a time
  there. Batch Convert renders RAW through the editor's path and shares it.
  RAW Adjustments keeps the file open in the engine for the document
  (`RawDevelopFilter`), freed with the document's original.
- The RAW Core Image context uses a 512 MB memory limit on Macs with 8 GB
  or less: footprint 20-26% lower, full render about 10% slower; lower
  limits cost much more time, 1024 MB saves nothing.
- **Videos:** no player exists until the user asks to play, and only one
  at a time (`VideoPlayback.liveCount`). Frames decode three at a time at
  most, whatever the number of thumbnail workers.
- **Find Duplicates:** feature prints are made one at a time on Macs with
  8 GB or less, two up to 16 GB, three above, each from a 256 px decode. A
  similarity search compares at most 10,000 images on 8 GB Macs and 20,000
  elsewhere (about 130 MB at 20,000).
- **Multi-page outputs:** TIFF pages are encoded one at a time and joined
  by `TIFFPageWriter`; PDF pages are written as each ends. ImageIO's GIF
  and animated HEIC encoders keep every frame until the end, so the whole
  animation is checked first: frames × width × height × 12 bytes must fit
  the export budget. An image strip is one bitmap plus one picture at a
  time, checked against 32768 px a side and the export budget.
- **Slideshow video:** three slides at most, each decoded at the video's
  size by `ImageLoader.decodeOnce`, outside the loader's cache (about
  400 MB at 4K, 100 MB at 1080p).

### 4.6 Catalog

One SQLite database (system `libsqlite3`, no wrapper library) in the app's
Application Support folder. Schema version 4 (`Catalog.schemaVersion`); an
older catalog is upgraded step by step in one transaction (1 → 2 → 3 → 4),
and tests open real version 1 and version 2 catalogs. Tables:

| Table | Holds |
|---|---|
| `files` | stars and the tag per file, with path, folder, volume, file identifier and `overrides_file` (schema 2) |
| `folder_order` | Custom Order: each folder's names and positions |
| `metadata` | header values read for filters and Find (schema 3; cleared by schema 4) |
| `collections`, `collection_items` | collections and their members by path and identity (schema 3) |
| `smart_folders` | a name and a saved search as JSON (schema 3) |

There are no foreign keys (SQLite enforces them only with a per-connection
pragma); deleting a collection deletes its members in the same
transaction.

**Marks and healing.** Each row keeps the path and the file's APFS file
identifier, so a file moved in Finder is found again by identifier and its
path healed. Healing runs with every folder listing, and also reattaches
collection members moved into that folder. It is paused while minivu itself
moves or renames files (`Catalog.pauseHealing`) until the moves are
reported: a listing in between (the folder watcher fires as files move)
would reattach the rows by identity first, and the report would then drop
them as a replaced file's. A lock (`healCommit`) makes each heal check for
a pause right before it commits. Ratings, tags and order changes still
queued when the app quits are written before it exits. Every Move to Trash
(browser, viewer, Compare, Find Duplicates, Replace) records its move in
the catalog (`FileWriteQueue.trash` → `Catalog.filesMoved`), so marks and
collection membership travel into the Trash with the file and come back
with it.

The browser reads a folder's marks in one catalog query, off the main
thread with the folder listing, so a grid sorted by rating arrives already
in order. Writes (a rating key, a tag, a drag that reorders) go through one
serial queue off the main thread (`BrowserModel.catalogWrites`), so quick
presses land in order; the catalog then posts `Catalog.didChange` naming
the files, with the moves (`movesKey`) and removals (`removedKey`) in its
user info, and each window redoes only what those files affect: the
visible cells showing them, the filter or sort when it depends on marks,
the preview pane, the viewer's HUD, and list entries whose file moved or
went (only those paths are checked on disk; a rating never touches it).
Finder tags (the coloured dots) are read from each file's extended
attribute after every listing, off the main thread, and never hold the
listing back.

**Marks in files.** Stars and the tag live in the catalog. Two things
connect them with the files:

- *Reading is always on.* A file with no catalog row shows the rating and
  tag it carries itself (embedded XMP, or for raws and sidecar formats the
  XMP sidecar first), so marks made in Lightroom, Bridge, digiKam or a
  camera appear, sort and filter like minivu's own. `FileMarksCache`
  remembers each file's marks with its size, date and sidecar date. The
  listing reads no file: it takes what the cache knows. The grid asks for
  the marks of cells as they are displayed (`wantFileMarks`), read at
  utility priority in chunks of 200. A rating sort or a rating or Tagged
  filter reads the whole folder the same way in the background.
- *Writing is opt-in*: Settings > General > "Write ratings into files
  (XMP)", off by default. `MarksFileWriter` is the catalog's
  `CatalogMirror`. It writes only the mark that changed (pressing T never
  rewrites a rating another app set), coalesces changes quiet for 0.8 s,
  mirrors only committed transactions, and goes through `FileWriteQueue`
  and `MetadataWriter` (embedded for JPEG, HEIC, PNG and TIFF, a sidecar
  for the rest). Quitting waits for pending writes.

The mapping (`MarksXMP`): stars to `xmp:Rating` (Bridge's -1 "Rejected" is
shown as no stars and kept); the tag to `digiKam:PickLabel` = 3
("Accepted"); a colour label to `xmp:Label` ("Red" … "Gray"), written
only, never read or shown. **The catalog wins:** when a row and the file
disagree, the row shows, and minivu never rewrites a file just because they
differ. The first change to a file without a row first copies the file's
marks into a new row (adoption), and a row standing over a file's own marks
is kept even when empty, so clearing a Lightroom rating in minivu sticks.

Colour labels are not catalog marks: a label is the file's standard Finder
colour tag, written into `com.apple.metadata:_kMDItemUserTags` through
`FileWriteQueue` as Finder writes it, keeping every other tag (4.7,
"Metadata"). JPEG comments are written into the file itself.

**Metadata cache.** The `metadata` table keeps each file's filter values
(`FilterMetadata`: date taken, camera, lens, ISO, aperture, focal length,
keywords, location, size) by path, valid while the file's size and
modification date are those recorded. minivu's moves carry rows, removals
drop them, and rows are dropped a year after they were written (the first
write of a launch prunes), so the table grows with what was searched, not
with what was browsed. Schema 4 cleared it once, because rows cached before
videos were read held no recording date, camera or location.

**Collections.** A member is kept by path, folder, volume UUID and file
identifier:

- renamed or moved by minivu (rename, Move To, drag, Batch Rename, a Batch
  Convert replacing its original, any undo): the member follows through
  `Catalog.fileMoved`/`filesMoved`, as marks do;
- moved or renamed in Finder: when the collection opens, a member not at
  its path is looked for by identity (`fsgetpath`), taken only where minivu
  can read the file and outside a Trash folder; healing is the fallback;
- moved to the Trash by minivu: left out of the list and the count, but
  kept, so moving it back brings it back; Finder's Put Back is found by
  identity; an emptied Trash stamps it missing;
- gone: left out and stamped missing, and dropped after a year missing;
- copies are new files and not members.

**Smart folders** store a `SearchQuery` as JSON. Every field decodes with a
default, and an unknown value drops only that condition, so a smart folder
saved by this minivu opens in a later one. A saved query with Other ticked
but no `videoGroup` marker gets Video added when read, so searches saved
before Video was its own type keep finding clips.

### 4.7 Editing

Non-destructive until saved. An `EditDocument` holds the decoded original
and an ordered list of `EditOperation` values; undo and redo move a cursor
through that list. The list compiles to a Core Image graph rendered on
Metal: at screen resolution while a slider moves, at full resolution when
saving. Operations Core Image doesn't have join the same graph: the eleven
resampling filters and oil paint are Metal compute kernels wrapped in
`CIImageProcessorKernel`; bump map, sketch, frame, lens, clone, heal,
red-eye, noise reduction (a bilateral filter), vignette and perspective
are Core Image kernels compiled at runtime. Drawn objects (text, lines,
callouts) stay editable as vectors: reopening the drawing tool on a
document whose last step is a drawing edits that step.

**Operations** are plain `Codable` values whose parameters are stored in
full-resolution pixel units (or normalised coordinates for crops and
points). Building the graph takes a `scale` so the same operation renders
correctly on a screen-sized proxy: a 10 px blur becomes a 2.5 px blur on a
quarter-size proxy. Every operation keeps HDR highlights or, for sketch and
negative, does what it means with them; `hdrHighlightsSurviveEveryKindOfTool`
checks each, preview and full resolution.

**Rendering an edit:**

1. The original is decoded once at full resolution. A screen-sized proxy
   (Lanczos) is made from it and cached. Until there is an edit to show (a
   tool just opened, or its change cancelled or undone) the canvas keeps the
   viewer's own texture, HDR included, rather than a render of the same
   picture; zooming in then renders full resolution from the decoded
   original. Edits all taken back put the viewer's texture back at the end
   of the event, so a tool changing the document in several steps (one
   Colors section taking over from another, one effect replacing another)
   never flashes the unedited photo between them. A render still running
   when the change came back arrives too late to matter: it shows the
   picture the viewer's texture already shows, so it is dropped rather than
   put over it, and the texture is asked for again in case an earlier
   render is still on the canvas. RAW files, whose viewer
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

**Measured operations.** Some operations need an analysis of the picture.
The analysis runs once, off the main thread, on a rendering of the
committed edit at a small size (`renderForAnalysis`), and its result is
stored in the operation, so every render, the saved file and the document
after a reload apply exactly the same thing and no render ever analyses:

- *Auto Enhance* stores the filters `CIImage.autoAdjustmentFilters`
  suggests at 1024 px, with their numbers. Only an allow-list of filters
  (`AutoEnhance.knownFilters`), each measured to pass HDR values, is ever
  made from a document; a filter a later macOS suggests is dropped until
  checked.
- *Remove Background* stores Vision's subject mask
  (`VNGenerateForegroundInstanceMaskRequest`, from a rendering of at most
  1536 px, every instance) as an 8-bit PNG with its bounding box
  (`SubjectMask`), stretched over the working size at render and mixed with
  `CIBlendWithMask`. Each mask hashes its PNG once (`SubjectMask.digest`),
  so comparing operations on the main thread never compares the bytes.
- *Perspective* Auto asks Vision for the most prominent rectangle and only
  moves the handles; the stored operation is the four corners
  (`PerspectiveQuad`, normalised), warped by a projective map. Red-eye's
  automatic search uses Vision's face landmarks the same way.

**Other operations of waves 1 and 2.** Noise Reduction is a bilateral
filter on encoded values (`effectsDenoise`), since `CINoiseReduction`
clips to 1 on macOS 27. Vignette is a gain in linear light on an ellipse
fitted to the image (`CIVignetteEffect` clips too). Canvas Size stores the
exact output size, a 3 × 3 anchor and a fill; a smaller canvas crops. The
watermark is below.

**RAW settings.** `EditOperation.rawDevelop` holds the RAW engine's own
settings (exposure, boost, highlight recovery, white balance, luminance and
colour noise; nil for what the engine can't do for that camera). The graph
passes the image through it untouched; instead the operation changes the
source. Every decoded original and proxy records the settings it was
developed with, and each render compares them with what its operations ask
for (`RawDevelop.inEffect`, the last RAW step's; files that aren't RAW
ignore it):

- a full-resolution render, or any render once no RAW step is left, first
  makes the original again with those settings and puts it on the document
  in place of the old one. The two lanes share that decode
  (`EditRenderer.remadeSource`), and a remake is kept only if the
  operations still ask for its settings when it finishes;
- a slider preview doesn't wait for that: the engine develops the file at
  exactly the preview's size through `CIRAWFilter.scaleFactor`, and that
  image becomes the proxy for later previews with the same settings;
- so undo and redo are just a change of operations, and the renders after
  them bring the original back in line. Save As develops an original with
  the committed settings if the document's doesn't have them. Analysis
  renders develop at the analysis size only.

Developed images follow the viewer's RAW HDR setting, as the first decode
does. Developed originals are half float.

**Watermark.** `Watermark` (text or a picture, size and margin as
fractions of the short side, opacity, a nine-place position, optional
tiling with spacing) draws its stamp with Core Graphics into a small 8-bit
bitmap at exactly its size, then composites it source-over, so the photo's
values pass through untouched where the stamp is transparent (HDR
included). Tiling repeats the stamp with `CIAffineTile`, so wide spacing
costs no more memory. A stamp too big for the photo is shrunk by the same
fraction at every scale (`WatermarkGraph.Layout`), so the saved file
never loses what the preview shows. The picture is kept as a read-only
security-scoped bookmark plus its name, so a saved preset renders it in a
later session; it is decoded at about the height drawn and the last six
are cached. A missing picture draws nothing.

**Batch presets.** A preset is an operation list (and, when saved from
Batch Convert, the sheet's output options). `BatchEdits` decides which steps
travel to other photos:

| Step | In a preset? |
|---|---|
| Lighting, Colors, Curves, Levels, Grayscale, Sepia, Negative, Sharpen, Blur, Noise Reduction, the effects, Vignette, Watermark, Rotate, Flip | yes |
| Crop, Perspective | yes, as fractions (left out after a left-out Canvas Size) |
| Auto Enhance | yes, measured again on each photo |
| RAW Adjustments | yes; ignored for files that aren't RAW |
| Resize, Canvas Size | left out: sizes in pixels for this photo |
| Text and Shapes, Clone Stamp, Healing Brush, Red-Eye, Remove Background | left out: placed on this photo's content |

Choosing a stored preset filters it through the same rules again. Auto
Enhance is re-measured per file from a small decode (the codec's downscale,
the embedded preview for RAW), never a render of RAW sensor data.

**Lossless actions:** rotating a JPEG in the browser changes its EXIF
orientation tag with `CGImageDestinationCopyImageSource`, never re-encoding
pixels. JPEG comments are rewritten in the COM segment without touching
image data. A browser selection rotates a few files at a time off the main
thread; files that can't turn without re-encoding (RAW, GIF, BMP, videos…)
are skipped and named in one alert afterwards, and batches run one after
another so two quick ⌘R presses turn a photo twice.

**Metadata.** Edit Metadata, the info panel's keyword editor and the marks
mirror all write through `MetadataWriter` (MinivuCore/Export). One
`MetadataEdit` holds only what changed (title, caption, creator,
copyright, keywords to add and remove, a date shift or a new date, remove
location, rating, tag, label), so mixed values in a selection stay intact.

- *In the file* for JPEG, HEIC, PNG and TIFF (camera raws excluded by
  extension and by content). Fields are written as XMP (dc:title,
  dc:description, dc:subject, dc:creator, dc:rights); ImageIO mirrors them
  into IPTC and TIFF/EXIF. Dates go in as photoshop:DateCreated and
  xmp:CreateDate, and are handled as a wall clock (`WallClock`), never
  through the Mac's time zone.
- The whole XMP view is passed back with merge off, because
  `kCGImageDestinationMergeMetadata` can't delete a tag in HEIC, PNG or
  TIFF (measured). Per format: JPEG splices only the EXIF, XMP and IPTC
  segments into the original header (image data compared byte for byte, so
  never re-encoded); HEIC takes ImageIO's copy (pixels and gain map
  carried byte for byte); PNG replaces its eXIf and XMP chunks from a blank
  image encoded with the new metadata, because ImageIO's copy leaves the
  old XMP's tail in the file; TIFF takes ImageIO's copy and `TIFFScrubber`
  zeroes every byte no directory points at.
- *Sidecars* ("basename.xmp", the Lightroom convention) for camera raws
  (never modified) and formats ImageIO can't rewrite. An existing sidecar
  is merged into. PDF, SVG and videos are refused (`Method.unsupported`).
- Every write goes through `SafeFileWriter` (atomic, creation date,
  permissions and extended attributes kept), is read back and refused if a
  changed field didn't take (`MetadataWriter.Error.didNotTake`), is
  recorded with `OwnWrites`, and is queued on `FileWriteQueue.shared` with
  `touching:` (metadata only).
- `MetadataRevisions` (a per-file counter) tells the info panel to read
  again after a sidecar write, which leaves the image's date alone.
- **Remove location** (`LocationMetadata`, one list shared by Save As,
  Batch Convert, Edit Metadata and the web gallery): the GPS dictionary,
  every `exif:GPS…` XMP tag and the IPTC place names with their XMP forms.
  It is stripped from both views ImageIO is given, since ImageIO writes a
  GPS directory from XMP tags alone.

Labels: a colour label is the file's standard Finder colour tag, named as
Finder names that colour (`NSWorkspace.fileLabels`) and stored with its
colour number, so it shows in colour in any language. Choosing one replaces
any other standard colour tag and keeps the rest. A file whose tags can't be
read is refused rather than overwritten.

**Saving:** Save (⌘S) writes over the original in its own format, colour
space and depth, with the options last used for that format and metadata
always kept (location included), after a "Replace the original?"
confirmation that can be turned off. Files minivu can't write back (RAW,
WebP, JPEG XL, PDF, SVG, PSD, animations, files holding more than one
image other than JPEG, such as a multi-page TIFF or an icon with several
sizes, and AVIF where ImageIO has no encoder) go to Save As instead. Save As is the system save panel
as a sheet, with an accessory for format, quality, colour profile,
metadata, Remove location (on by default), progressive, 16-bit (10-bit for
AVIF), TIFF compression and background; the options are remembered per
format. Save As onto the original itself counts as in place, so location
is kept there whatever the toggle says. The image is rendered once while
the panel is open (an edit through `EditRenderer`, an unedited original
decoded by ImageIO, or a video frame through `SaveImageSource.videoFrame`)
and shared by the live size estimate, the quality comparison
and the final write. Save Frame As hides the metadata options, since the
frame carries none of the movie's. The estimate is an exact full encode 150 ms after the
last change, one at a time; an encode slower than 400 ms first shows a
figure extrapolated from a 1024 px centre crop. AVIF quality is capped at
0.99, because ImageIO fails a lossless (1.0) AVIF encode. The quality comparison is a
separate window showing the original and the encoded result side by side
at 100/200/400%, re-encoding only the region on screen as the slider moves.
Every write to an image file (Save, Save As, a comment, a lossless rotate,
a metadata or label write) goes through one serial queue, so ⌘S, an edit and ⌘S again land in that
order, and a document is marked saved only by the last write of its file.
Moving a file away (Move to Trash, a rename including Batch Rename, a move
or its undo) waits for the writes queued for it, or for files inside a
folder being moved, so a save asked for just before lands first instead of
putting the file back at its old path. A capture, a montage and a desktop
copy choose their name inside the queue, so they name the folder they write
into rather than the file, which is the smallest thing they can name in
advance and enough for a wait on that folder to cover them. Long outputs
(multi-page files, image strips, slideshow videos, web galleries) are made
in a temporary file or folder first and only placed through the queue
(`enqueue(replacing:)`), so the work doesn't hold the queue and only a whole
file appears. Move to Trash of an image with unsaved edits in the viewer
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
writes of the file (an earlier Save, a comment, a metadata or marks write)
don't count: `OwnWrites` keeps the stamp each write left. A lossless
rotate does count, since the edits were made on the unrotated pixels.
Save keeps a gain-map JPEG, HEIC or AVIF HDR: the edit renders as half-float
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
- Never hand a `clampedToExtent()` image to a resampling filter or a
  sampling general kernel on macOS 27: it comes back clipped to 1 (see
  "Core Image on macOS 27"). A kernel that needs repeated edges holds its
  sample positions to the image's bounds itself (a `bounds` or
  `sourceBounds` argument). A Gaussian blur and a warp kernel may read a
  clamped image.
- Prefer a kernel of our own to a Core Image filter that hasn't been
  measured with HDR input: `CINoiseReduction` and `CIVignetteEffect` clip
  to 1.

### 4.8 Tools

Section 5 describes what each tool does; these are the implementation
rules a maintainer needs.

**Which images a tool takes.** In the browser, `toolImages` is the
selection, or every image shown when none is selected. Picture tools
(Batch Convert, Extract Pages, Create Multi-Page File, Image Strip,
Contact Sheet, Create Web Gallery, Montage, Print) take `toolStills`, which
leaves videos out; with only videos they are disabled. Start Slideshow
and Export Slideshow Video take `slideshowImages` (two or more selected
pictures, otherwise every picture shown, from the selected one), videos
left out (`SlideshowSequence.withoutVideos`). Share and Batch Rename take
videos. Menu validation works from counts and the selection, never a walk
of the folder. When the browser shows a list rather than a folder, a
tool's panel starts in `toolStartFolder` (the folder shown, else the lead
image's folder) and is titled `toolTitle` (the folder's name, else the
list's title).

**Batch Rename.** `RenamePattern` (MinivuCore) is text with tokens:
`{name}`; `{#}` or `{###}` for the counter (the digits setting is a
minimum; start and step can be set); `{date[:format]}` for the date taken
(EXIF DateTimeOriginal, else DateTimeDigitized, else the modification date,
in the camera's EXIF offset zone when one is recorded; a video's recording
date with its zone); `{modified[:format]}`;
`{width}` `{height}` as displayed; `{ext}`. `{page}` (or `{frame}`) exists
for Batch Convert and Extract Pages and is refused here as unknown, since
Batch Rename renames whole files. Keywords work in any case;
formats are Unicode date patterns (yyyy-MM-dd by default) in en_US_POSIX
and the Gregorian calendar, so names are the same on every Mac. Tokens come
first, then find and replace, then letter case; the extension goes on last
in its own case. Unknown tokens stay visible and block Rename. EXIF is read
only when the pattern needs it. Named presets keep the whole
`RenamePattern` (UserDefaults `batchRenamePresets`).

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
- **One rename at a time, app-wide.** Every batch rename, from any window or
  any shortcut, joins one queue (`BatchTools.queueRename`) and moves files
  only once the rename before it has finished.
- Undo is the same operation reversed: one step, "Rename N Items". Batches
  in a window run one after another, and an undo or redo reads the names to
  restore only when it starts. Afterwards only the folder shown is listed
  again; a list follows the renames (`BrowserModel.followMoves`).

**Batch Convert.** `BatchConvertSettings` (MinivuRender, Codable, defaults
for missing keys) holds the `ExportOptions` (Remove location among them,
on by default), the destination (beside the
originals, or a chosen folder's security-scoped bookmark, kept and
refreshed when stale), naming, the existing-file policy (skip, keep both,
replace to the Trash), resize (long side, width, height or percent, any of
the 11 filters, don't enlarge; 0, or past 32768 px or 1000%, disables
Convert), quarter turns and flips, a preset's edits, a watermark, Keep HDR
and the Pages choice. Operations run: edits → turn → flip → resize →
watermark. The watermark goes last so it is drawn crisply at the output
size.

- A format change with no operations encodes ImageIO's full decode with
  the orientation baked in (exact pixels, as Save As does). Operations, and
  every RAW file, go through an `EditDocument.Snapshot` into
  `EditRenderer.renderForExport` (RAW with the viewer's RAW setting). There
  is no second renderer. Colour is the chosen profile, or for Keep original
  the Save policy's render space; formats without profiles get sRGB.
  Metadata is kept or stripped by `ImageEncoder`, orientation reset to 1.
- **HDR.** Output is SDR, except with Keep HDR on (the default) for a
  JPEG, HEIC or AVIF output of an HDR raster original, with colour profile
  Keep original or Display P3 at 8 bits: then the file renders through
  `renderHDRForExport` and is written with an ISO gain map
  (`ImageEncoder.canWriteGainMap`). An explicit sRGB or Adobe RGB profile,
  or 10 bits, writes SDR, and the sheet says so. RAW stays SDR.
- `BatchConverter.prepare` reads the header, works out the operations,
  checks the memory budget (4.5) and measures Auto Enhance, all before any
  full decode. `encodedData` encodes through `BlockingWork`, so the
  converter is safe from any caller (4.12).
- `BatchOutputPlanner` settles every clash before anything is written.
  Outputs never share a name and never land on another source of the batch
  (recognised by path and by file identity); both are numbered ("photo
  2.jpg") whatever the policy. A folder is never replaced.
  `BatchReplacements` lists what the batch would send to the Trash, and the
  app asks once, naming up to three files: Replace, Keep Both (planned
  again for this run only) or Cancel, the default. A file that takes an
  output's name after planning was never named, so that output is written
  with Keep Both even under Replace.
- **Pages.** "Every page" writes all pages into one file for TIFF and GIF
  (keeping an animation's delays and loop count), and one numbered file per
  page for every other format. Extract Pages is a mode of the same sheet
  (all pages or a range, one file per page, PNG by default, its own
  remembered settings and pattern `{name}-{page}`). A page never replaces
  its own original: it is numbered like a clash. An output that is one page
  of a file and whose pattern lacks `{page}` gets "-NN". The job keeps the
  latest source's pages (`PageSequences`), so extracting every frame of an
  animation decodes each frame once. Multi-page outputs carry no metadata.
- `BatchConvertJob` converts 2 files at a time (1 on Macs with 8 GB or
  less) and at most one camera RAW at a time (about 1.6 GB per render).
  Work runs on GCD through `BatchWorkExecutor`, a task executor preference
  that keeps the async renderer off the cooperative pool. Encodes are
  parallel; writes go through `FileWriteQueue.shared`. `BatchFileWriter`
  writes a hidden sibling, fsyncs, and renames it into place with
  `RENAME_EXCL` (`commit(fileAt:)` for pages written elsewhere first); a
  name taken since planning gets the policy again. Replace
  writes the new file, trashes the old one, renames the new one in, and
  brings the old one back if that fails.
- Cancel stops new files (including a RAW waiting for its slot) and drops
  encodes that finish later; a queued write completes, so only whole files
  remain. The summary lists up to 8 failed and 8 skipped files; outputs in
  the folder shown, or in a list or flat view (`showsManyFolders`), are
  selected and their caches invalidated.
- Marks: an original replaced by its own conversion keeps its stars, tag,
  Custom Order place and location, following a case-only change of name.
  Any other replaced file takes its marks to the Trash, as Copy's Replace
  does.
- **Presets** (`BatchStores.swift`): `NamedPreset<Value>` in a
  `PresetList`, stored under `batchConvertPresets`; names compared ignoring
  case, cut to 80 characters. Each change re-reads the store first, so two
  open sheets never drop each other's presets, and a preset this minivu
  can't decode is kept unchanged when the list is written back. A preset
  saved from the viewer (File > Save Edits as Preset…) carries edits only.
- The Tools menu disables the sheet-opening tools while a sheet is up
  (`BatchTools.beginSheet/endSheet`, `canPerformTools`), and the batches
  also while a batch, copy or multi-page job runs. Start Slideshow, Open
  Folder and Add Folder to Sidebar are disabled under a browser sheet too.
  The Convert sheet focuses nothing when it opens and ends editing before
  converting.

**Multi-page files and image strips.** `MultiPageBuilder` reads every page
of each source (`PageSequence`: PDF and TIFF pages, animation frames) in
the order of the sheet's list and hands them to `MultiPageWriter`. TIFF
pages are each encoded by ImageIO and joined by `TIFFPageWriter`
(MinivuCore/Export), which appends each page's bytes with its offsets moved
and links the directories; it refuses BigTIFF, unknown types and anything
past 4 GB rather than guess. PDF goes through a Core Graphics PDF context
(JPEG pages embedded as JPEG data). GIF and animated HEIC frames are made
at the frame size and checked as a whole first (4.5). PDF pages are
rendered as the viewer renders them at full resolution (144 dpi, 4096 to
16384 px on the long edge). `ImageStripLayout` and its renderer draw a
strip (side by side, one above another, or a grid whose cells take the
pictures' middle aspect ratio) into one 8-bit or 16-bit Display P3 bitmap.
The output is made at `SafeFileWriter.temporaryFile` and put in place with
`SafeFileWriter.place` inside `FileWriteQueue.enqueue(replacing:)`; a
strip then opens in the viewer. Every output is SDR. `CancellationFlag`
(MinivuCore) is checked before every page.

**Find Duplicates.** The run is one `BlockingWork` job with a
`CancellationFlag` checked between files, chunks and blocks; progress
reaches the main actor at most a hundred times a phase (`ProgressRelay`).

- *Identical Files:* files are grouped by byte size (free, from the
  listing; empty files left out), and only files that share a size are
  read, through a streamed CryptoKit SHA-256 (`ContentHash`, 1 MB chunks).
  The same file reached twice is counted once. Videos are included.
- *Similar Images:* `VNGenerateImageFeaturePrintRequest` on the device,
  from a 256 px decode (the thumbnail cache tier when current, so a browsed
  folder costs no decode). Videos are left out before the memory cap: a
  poster frame would pair a Live Photo's movie with its photo.
  `SimilarityIndex` compares every print with every other by one
  Accelerate matrix product, 256 rows at a time, keeping each image's 16
  nearest pairs within the loosest threshold. Groups at a threshold are
  the connected pairs under it (single linkage), regrouped in about a
  millisecond when the slider moves. Thresholds (Euclidean distance,
  measured): copies 0.05 to 0.42, different pictures 0.56 and more; range
  0.05 to 0.80, default 0.45.
- Keep rules: Highest Resolution (a video by `VideoFrames.info`), Largest
  File, Oldest; ties to the next rule, then path order. After Stop, the
  shown files' dimensions are read before Highest Resolution suggests
  anything.
- Nothing is ever marked unless the user does it, and trashing goes only
  through `FileWriteQueue.trash` after `DuplicatePrompts.confirmTrash`.
  The browser then drops only the entries at the trashed paths
  (`BrowserModel.removeEntries` checks the full path).
- Prints and hashes are cached in the thumbnail database (4.5); losing the
  cache costs time, never data.

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
normal-level window on the display the full-screen viewer would use
(`Displays.fullScreenDisplay`, which follows Settings > Viewer > "Full-screen
viewer opens on"); menu bar and Dock hide while it is key.

- Between slides nothing renders: one `DispatchWorkItem` waits the interval,
  counted from the end of each transition, and the display link runs only
  during a transition. → and ← finish a transition at once and start a
  quick one (0.35 s).
- Neighbours load through `ImageLoader.shared` fitted to the picture area
  (below any camera housing), and only those textures are kept. Zoom's
  outgoing slide grows past fit only as it fades, so no larger decode. A move waits for a slide not yet
  decoded (cleared before the texture is requested, so a cache hit can't
  run it twice). Failed files are marked in `SlideshowSequence` and skipped
  both ways; if nothing loads, the show ends. Videos are never slides: from
  a video, the show starts at the next picture.
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
  playlist are fixed at the start. Volume ramps over 0.1 s, and Play music
  off mutes over 0.25 s.
- `SlideshowAudioPlayer` plays the music behind `SlideshowAudioPlaying`.
  AVFoundation is also imported by `VideoFrames` and `ImageFormats`
  (MinivuCore), the viewer's video playback, and the slideshow video
  writer (writing only). `SlideshowMusic` resolves bookmarks off the main
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

**Slideshow video.** Tools > Export Slideshow Video… plays one pass of the
slideshow into a movie with the live show's own shader and settings
(interval, transition, order, captions, music).

- *Timing in whole frames* (`SlideshowVideoTimeline`): the first picture
  fades in from black, each later one comes on with its transition, and the
  video fades to black after the last. Length = pictures × (transition +
  interval) + transition. Random never repeats the transition before.
- *Frame path:* `SlideshowRenderer` draws into a half-float
  (`kCVPixelFormatType_64RGBAHalf`) pixel buffer from a `CVPixelBufferPool`,
  seen by Metal through a `CVMetalTextureCache`; Core Image converts each
  frame into the writer's 8-bit BGRA buffer in Rec. 709. A frame identical
  to the one before hands the encoder the same buffer again, so the GPU
  draws only transition frames.
- *Encoding:* `AVAssetWriter`, H.264 (High profile) or HEVC, MPEG-4 or
  QuickTime, by bit rate (H.264 0.04 / 0.08 / 0.16 bits per pixel per
  frame for Low / Medium / High; HEVC 60% of that), a key frame every two
  seconds. Music: the playlist's songs one after another, cut at the end,
  faded in over 1 s and out over 1.5 s, AAC 48 kHz stereo 192 kbit/s;
  unreadable songs are left out. The Volume setting is not applied.
- *Threads:* planning and music resolution through `BlockingWork`, with
  Cancel checked before each header; frames and sound each fed by
  `requestMediaDataWhenReady` on their own serial queue. A
  `SlideshowVideoWatchdog` (250 ms) ends a track when Cancel is pressed or
  the writer has failed, so a failing writer can't wait for ever.
- *Placing:* the movie is written in a scratch folder on the destination's
  volume, removed on cancel or failure, and only a finished file is moved
  into place through `FileWriteQueue`. The destination's folder must pass
  `VolumePolicy` (the save panel greys out other volumes too).

**Web gallery.** Tools > Create Web Gallery… writes a folder:
`index.html` (the thumbnail grid), `style.css`, `pages/<stem>.html` (one
page per picture with Previous and Next), `images/`, `thumbnails/` and,
optionally, `originals/`.

- No JavaScript at all, no fonts, analytics or outside links: every `href`
  and `src` is a relative path. Each page has a Content-Security-Policy meta
  forbidding scripts, objects, frames, forms and `<base>`, and `referrer:
  no-referrer`.
- `WebGalleryHTML.escape` escapes every string from a file name or metadata
  in text and attributes; `WebGalleryHTML.link` percent-encodes each path
  component, so a name can't add a scheme, query, fragment or `/`. File
  names are made safe (`WebGalleryPlanner.safeName`, `nameProblem`) and
  unique ignoring case and normalisation (`BatchNameKey.uniqueName`).
- Pictures go through `BatchConverter.image` (Lanczos, never enlarging,
  SDR) and `ImageEncoder` in sRGB; AVIF is written with HEIC's rules
  through `ImageEncoder.encode(_:typeIdentifier:options:metadataSource:)`.
  Thumbnails are drawn at twice their CSS size and carry no metadata. One
  picture at a time, on GCD through `BatchWorkExecutor`.
- Originals are copied byte for byte, but unless the large pictures keep
  their location, each copy with a location is rewritten by
  `MetadataWriter` (remove location) and read back. An original whose
  location can't be removed (a camera raw, a format the writer doesn't
  rewrite) is left out and named afterwards. Sidecars are never copied.
- Everything is written into a scratch folder, then moved in with one
  exclusive rename (`FileOperations.moveExclusively`) through
  `FileWriteQueue`, so there is either no gallery or a complete one. The
  chosen folder must pass `VolumePolicy`.

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
minivu's own writes (`SavePresenter.didWrite`, `ExternalEditWatcher.noteOwnWrite`)
re-stamp watched files, so a Save or a marks write is never reported back.

**Share.** `FileSharing` (Tools/Share) hands file URLs to
`NSSharingServicePicker`, never pictures: the file as it is on disk, with
its metadata, as Finder shares it. With unsaved edits in the viewer the user
is told first that the last saved file is shared (Share Saved File /
Cancel), the same rule as external editors; minivu never writes a rendered
copy to share. The browser's toolbar button is AppKit's
`NSSharingServicePickerToolbarItem`, whose delegate returns the same
`shareURLs`. Tests use a fake presenter and never reach a share service.

**Automation (Shortcuts actions).** Six App Intents in
Minivu/Automation/AutomationIntents.swift, over the engine in
Automation.swift:

| Action | Engine |
|---|---|
| Convert Images, Resize Images | Batch Convert's planner and `BatchConvertJob`, into minivu's own `tmp/Automation/<run>/` folder |
| Rename Images | `RenamePlanner` and `BatchRenamer` through `BatchTools.renameWithoutWindow` |
| Set Rating | `BrowserModel.catalogWrites` |
| Set Colour Label | `ColorLabelCommand.write`, as Image > Label |
| Open in minivu | `AppDelegate.application(_:open:)`, the Finder path |

Convert, Resize and Open in minivu are also ready App Shortcuts. Rules:

- Titles, defaults and display names stay literals: the metadata
  processor reads them from the compiler's records, not by running code.
- Convert and Resize never write beside the originals: a shortcut's files
  come with permission to read, not to write in their folder. Outputs are
  marked `removedOnCompletion`, and run folders older than a day go when
  the next run starts. They use Batch Convert's defaults, not the
  remembered settings, so a shortcut does the same on every Mac.
- Every file is checked with `VolumePolicy` as it arrives
  (`AutomationInput.make`); one file on an external volume fails the whole
  action before anything is touched.
- All or nothing: a failed conversion removes the files that did convert.
  Rename checks every folder it would rename in first
  (`Automation.unwritableFolders`, access(2) with W_OK, which the sandbox
  answers), and Set Colour Label every file (`unwritableFiles`); one
  refusal and nothing changes. Rename registers no undo.
- Rename and Set Rating refuse files that arrive as data; Convert and
  Resize copy them into minivu's folder first.
- Taking the files and making or clearing run folders run on a GCD thread
  (`BlockingWork.run`). Only Open in minivu declares
  `openAppWhenRun = true`; the others leave it at its default, false.
- There is no Apple Events interface beyond AppKit's open-documents event,
  and no scripting dictionary.
- A launch made only to run an action shows no window
  (`IntentLaunch`): with nothing to open and minivu not active when
  launching finishes, it waits up to 300 ms. An activation, a reopen or a
  file shows the browser; an action's `perform()` (every one but Open in
  minivu's runs in `IntentLaunch.run`) keeps minivu windowless and
  `.accessory`; the timeout shows the browser (fail safe). Windowless, it
  quits through `NSApp.terminate`, so after queued writes, 60 s after the
  last action ends; the user opening minivu meanwhile cancels that.
  macOS gives no documented launch reason for intents
  (feature-notes/sys.md, "Launched by a shortcut").

### 4.9 Search, the flat view and lists

The browser shows either a folder or a list (`VirtualList`): a flat view,
search results, a smart folder, a collection, or Find Duplicates' Show in
Browser. A list is a place in Back and Forward.

- **The walk.** `TreeEnumerator` (MinivuCore/Search) walks breadth first
  through `FolderListing.contents`, the browser's own listing call, so each
  image arrives with the attributes the grid needs (no stat per file).
  Packages and hidden items are skipped as in the browser, symbolic links
  to folders are never followed, and every folder passes `VolumePolicy`.
  Limits (`TreeEnumerator.Limits.standard`): 12 levels, 20,000 images,
  5,000 folders; breadth first means a limit cuts off the deepest material.
  A walk stopped by a limit says so in the status bar.
- **Partial results.** Every 250 ms what has been found is sorted off the
  main thread and shown. A `CancellationFlag` is checked before each
  folder, and the model's generation number drops a late result.
- **Keys by path.** A folder's entries were known by name; a list's are
  known by path (`FolderSnapshot.keysByPath`, `BrowserModel.key(_:)`), and
  marks, Finder tags, filter metadata and the grid's index all use it.
- **Following changes.** Only the top folder of a flat view is watched;
  lists aren't. minivu's own renames, moves and Batch Rename rewrite a
  list's URLs and those in Back and Forward (`followMoves`); renames
  reported by the catalog from elsewhere in one folder (a shortcut, a
  Batch Convert replace that changes letter case) are followed too
  (`followRenames`). Entries whose file left are dropped.
- **Find.** `ImageSearch` walks the tree; it doesn't use Spotlight. Measured:
  the walk of 20,000 empty files took 128 ms, a header read 11 ms a file
  cold and nothing the second time (the catalog's cache), while Spotlight
  on the same folder had indexed neither the camera nor most of the files,
  and never knows minivu's marks, its sidecar keywords or files copied in
  moments ago. Tests per folder run cheapest first: name and type in
  memory, marks (one catalog query), label (one extended attribute each,
  only with a label condition), then headers only for files still in the
  running.
- **Conditions** are `MetadataCriteria`, shared by More Filters, Find and
  smart folders. Header values (`FilterMetadata`) are read in one pass per
  file with ImageIO (never a pixel), with the XMP sidecar overlaid for raws,
  and for videos from `VideoFrames.metadata` and `info`. Date taken compares
  the wall-clock day the camera recorded. Type groups include Video.

### 4.10 Video

minivu shows and plays the videos in the folders it browses. It is not a
video editor.

- **One `ImageKind`, `.video`.** Videos are listed, sorted, selected,
  rated, tagged, labelled, moved and trashed by the code that does it for
  photos. `ImageFormats.isImage` stays true for videos ("image" is the
  app's word for a non-folder item); `isVideo` and `entry.kind == .video`
  mark what differs.
- **Thumbnails and the still** go through `ImageDecoder.thumbnail` and
  `decode`, so the existing `ThumbnailService`, `ThumbnailStore` and
  `ImageLoader` cache and prefetch them like photos (4.2). The grid's
  detail line reads a video's size and length in one read
  (`PixelSizeCache` keeps a length beside the size).
- **Playback** is AVKit's `AVPlayerView`, not a layer with controls of our
  own: it brings the scrubber, time, volume, HDR, VoiceOver and the
  system's look. minivu hides its full-screen, picture-in-picture and
  sharing buttons and turns off Now Playing. No player exists until the
  user asks to play (`VideoPlayback`); moving on, trashing or closing
  stops it and releases it (`replaceCurrentItem(nil)`), and a hidden,
  minimised or covered viewer pauses it.
- **The keyboard stays with the viewer.** `VideoPlayerView` refuses first
  responder, and `ViewerWindow.makeFirstResponder` hands anything inside
  the player that would take the keyboard to the canvas
  (`keyboardRedirect(for:)`), so AVKit's own keys never apply.
- **Turned off for a video** through menu validation: every edit tool,
  Save, Save As, Revert, zoom, Live Text, Copy, Copy Subject, Histogram,
  Count Colors, Print, Set as Desktop Picture, Edit Comment and Edit
  Metadata. In a mixed selection, lossless rotate and Edit Metadata skip
  videos and name them.
- **Frames.** Copy Frame and Save Frame As take an exact frame where the
  player stands (`VideoFrames.still(of:at:)`, zero tolerance, the video's
  own size, SDR), decoded from the file rather than read back from the
  screen. Copy Frame writes the pasteboard only once the frame is decoded.
- **Compare** shows a video by its first frame through the same loader,
  and never plays it.

### 4.11 Live Text

`LiveTextController` (Viewer/LiveText.swift) schedules VisionKit's
`ImageAnalyzer` behind `LiveTextAnalyzing` (a fake in tests) and hosts an
`ImageAnalysisOverlayView` above the canvas.

- **What is analysed** is the texture the canvas draws, read back as an
  upright 8-bit sRGB image of at most 4096 px (`LiveTextImage`,
  MinivuRender): the page shown, an edit's render, a paused animation's
  frame. No decode.
- **When.** Only when the pointer moves over the picture itself (not a
  panel, the filmstrip or the control bar) or Copy Text asks, once the
  picture has been on screen for 0.4 s; at most one at a time; cancelled
  when the user moves on. Flipping through a folder analyses nothing. When
  a texture at least twice as sharp arrives for a picture already read
  (the user zoomed in), it is read once more, up to the 4096 px cap.
- A `LiveTextController.Subject` (file, date, page, edit operations,
  animation frame) is taken when each texture arrives, so an analysis is
  never filed under an edit whose render hasn't come yet. An edit tool
  opened and closed without a change brings the analysis back.
- **Privacy.** Only `.text` is requested. Visual Look Up (which asks
  Apple's servers), machine-readable codes and data detectors are never
  requested, the interaction type is `.textSelection` only, and the
  overlay's image-wide menu items are removed.
- **Coordinates.** VisionKit's unit space counts from the top left even
  though the overlay isn't flipped (measured; a real-recognition test pins
  it). The canvas calls `onTextOverlayViewChange` after every zoom, pan or
  resize.

### 4.12 Blocking work and the cooperative pool

Swift concurrency runs tasks on the *cooperative pool*: one thread per core
for each QoS (quality of service, the priority class GCD gives work).
Measured on macOS 27.2:

- A cooperative thread blocked in a wait keeps its place in GCD's thread
  budget for its QoS. While every cooperative thread of a QoS is blocked,
  GCD starts no thread for work at that QoS or below. A blocked GCD worker
  gives its place back; a blocked cooperative thread does not.
- Vision (`VNControlledCapacityTasksQueue`) and ImageIO's HEIF and AVIF
  encoders (CMPhoto, VideoToolbox) hand their work to GCD at the caller's
  QoS and wait for it. Called from enough cooperative threads at once, that
  work never starts: a deadlock at 0% CPU. This hung the MinivuCoreTests
  run.

**The rule:** never block a cooperative thread on Vision, a HEIF or AVIF
encode, or an AVFoundation wait, at any QoS. Call them through
`BlockingWork.run` (a GCD thread at user-initiated QoS by default) or under
`BatchWorkExecutor`. `BlockingWork` protects only because its QoS is above
the blocked pool's; a `qos:` at or below it protects nothing, and a blocked
user-initiated pool starves user-initiated work too. The synchronous
helpers stay synchronous; every production caller reaches them from GCD.

- **Debug check.** `BlockingWork.expectOffCooperativePool(_:)` sits at the
  top of each helper that waits on a framework's queue (`FeaturePrint.make`,
  `SubjectDetector.mask`, `PerspectiveDetector.detect`,
  `RedEyeDetector.detect`, `ImageEncoder`'s HEIC and AVIF encode,
  `MultiPageWriter.finish` for animated HEIC, `VideoFrames`' waits). Debug
  builds print once per helper when it runs on a cooperative thread
  (`isOnCooperativeThread`, read from the queue label); release builds
  compile it away. Inside `concurrentPerform` the label check is blind, so
  helpers that fan out (`DuplicateFinder.featurePrints`,
  `RenameSource.withImageMetadata`, `LayoutRenderer.drawPage`) check
  before they fan out.
- **Tests.** Suites that call these helpers on purpose, or write HEIC and
  AVIF fixtures, use the `.offCooperativePool` trait (a GCD-backed task
  executor). The test-only C target `MinivuTestWatchdog` starts a thread
  when the test bundle loads; once a second it queues an empty item at the
  default QoS, and after the stall limit (30 s × `TestTiming` slack, 120 s
  in debug) it ends the run with a failure instead of letting it hang.
  `MINIVU_TEST_WATCHDOG=<seconds>` changes the limit; `=0` turns it off.

### 4.13 Localisation

The interface ships in English (the source language) and German, French,
Spanish, Italian, Portuguese (Brazil), Dutch, Polish, Japanese, Chinese
(Simplified) and Korean. Every translation is a machine translation in the
catalog state `needs_review` until a native speaker checks it.

- **String Catalogs.** Each target has one `Localizable.xcstrings`.
  `defaultLocalization: "en"` in Package.swift makes Swift Build compile
  each into its resource bundle as `<lang>.lproj` strings and stringsdict
  files, with no script. The compiler writes `.stringsdata` extraction
  files; `scripts/l10n-sync.sh` merges them into the catalogs with
  `xcstringstool sync`, and `scripts/l10n-merge.py` enters translations.
- **Lookups.** Each target has an internal `localized(_:locale:)` taking a
  `LocalizedStringResource` (so the literal is extracted), which looks in
  the target's own bundle through `Bundle.localizedText` (MinivuCore).
  The common path is cheap: no locale means
  `String(localized:table:bundle:locale:)` in the bundle's interface
  language, the interface locale is cached per bundle, and each key's kind
  is worked out once (release build: 8 µs a literal, 21 µs interpolated,
  41 µs for a keyed string with arguments). Text set on every update but
  never changing (tooltips) is looked up once, into a `static let`.
- **Keys.** A literal is its own key. Where one English word means two
  things (Tag, Open, File, Zoom, Frame…), the rarer meaning gets a dotted
  key with the English as default value. Plurals are catalog plural forms,
  never chosen in code. Numbers, units and lists go through
  `percentText`, `unitText` and `listText` or Foundation's formatters.
- **Stable values.** Code that must recognise a title compares a stable
  value (`MetadataSection.key`, a menu's identifier such as `.tools`),
  never localized text; an `Identifiable` id is never a localized title.
- **Not translated:** names minivu writes to disk (minivu Captures, minivu
  Wallpapers), format names, defaults keys, SQL and JSON, metadata values
  written into files, Finder tag names, log text, App Intents phrases and
  parameter summaries, and the pages a web gallery writes.
- **Help pages.** Translations live in `HelpPages/<lang>/`;
  `HelpLibrary.markdown` takes the page from the first preferred language
  that has it, else English.
- **Working in parallel.** Only the integration branch writes catalogs; a
  catalog conflict is never resolved by hand (re-sync instead). The full
  conventions are in docs/feature-notes/l10n.md.

### 4.14 Measuring: signposts and the benchmark kit

- **Signposts.** `Perf` (MinivuCore/Perf.swift) wraps one `OSSignposter`,
  subsystem `com.minivu.app`, category `perf`. `Perf.measure`, `begin`/`end`,
  `count` and `milestone` mark phases named `operation.phase` (one name per
  phase, never per file): `folder.list`, `viewer.flip`, `thumb.decode`,
  `edit.render.preview`, `batch.encode` and so on. Intervals wrap phases,
  never pixels or rows, and cost almost nothing while nobody records, so
  they stay in release builds; each adds one relaxed atomic load.
- **Launch milestones.** With `MINIVU_TRACE=1`, each `launch.*` milestone
  (catalog open, thumbnail store open, bookmarks, browser window shown, GPU
  ready, first folder listed, first screenful) prints to stderr with the
  time since the process started.
- **In-memory recording.** Between `Perf.startRecording()` and
  `stopRecording()` every interval and count is kept by name, so the
  benchmarks report the phases Instruments shows. The app never records.
- **Benchmarks.** Suites in all three test targets print one line per
  metric: `BENCH <suite>.<metric> median_ms=… p90_ms=… runs=…`, plus counts,
  memory (`phys_footprint` peak) and main-thread busy time
  (`Bench.MainThreadMonitor`). `MINIVU_BENCH=1` runs the synthetic ones;
  `MINIVU_BENCH_DIR` names a photo folder, read only (anything that writes
  works on APFS clones); `MINIVU_BENCH_QUICK=1` checks the kit, with
  meaningless numbers. Window benchmarks end when the GPU has finished the
  frame, not when a texture is set. Every suite that records is nested in a
  serialized parent (`Benchmarks`, `AppWindowTests`).
- **`scripts/bench.sh`** builds release with tests and runs each entry in a
  process of its own, one after another, collecting the BENCH lines and
  noting failed, empty and skipped entries.
- docs/PERFORMANCE.md holds the study of 15 November 2026: what takes how
  long, the speed-up plan, and the budgets in section 6 below.

## 5. User interface

Loosely FastStone's layout, in current macOS style (unified toolbar, SF
Symbols, sidebar materials, system appearance).

**Browser window:** folder sidebar | thumbnail grid | preview pane with file
info and EXIF. The sidebar lists favourites, then the folder tree, then
**Smart Folders** (gear symbol) and **Collections** (stack symbol) once
there is one of each; dropping images on a collection's row adds them.
Toolbar: sidebar toggle, back and forward, enclosing folder, thumbnail
size, sort, filter, compare, slideshow, share, a "Filter by Name" search
field, and the preview pane toggle. The window's subtitle and the status
bar count videos apart from images ("4 images, 2 videos, 1 folder").
A folder deleted or moved in Finder relists its nearest existing parent's
sidebar row. Rows removed from the tree are detached, and late listings for
them are dropped. A folder the sandbox refuses shows a permission message
pointing to File > Open Folder….

**Lists.** View > Flat View (⌥⌘F, per window, not remembered) shows the
folder's images and those of every folder below it as one list; search
results, smart folders, collections and Find Duplicates' Show in Browser
are lists too. Each cell's tooltip shows its full path, VoiceOver reads
"IMG_1.jpg, in 2024-06-01…", and the status bar's path control shows the
lead image's folder. Everything works on a list except what needs one
folder: New Folder, Paste, dropping files on the grid and Custom Order step
aside (Custom Order falls back to name order, except that a collection
shows the order its images were added); Enclosing Folder is off for search
results.

**Ratings, tags and labels.** Each image has 0–5 stars and FastStone's
"tagged" flag for culling. A grid cell shows its stars under the name (hollow stars
appear on hover, and a click rates; clicking the current rating clears it),
a checkmark badge on the picture's corner when tagged, and its Finder tag
dots after the name. The preview pane shows the lead photo's stars and a tag
button under it; the viewer's HUD shows both. Tag on a mixed
selection tags all of it, and untags only when all were tagged. Image >
Label sets a colour label (None, Red, Orange, Yellow, Green, Blue, Purple,
Gray) on the selection, the viewer's image or Compare's focused pane; a
checkmark shows the label every selected image shares, and the grid's
right-click menu has the same submenu. The browser draws labels as Finder
tag dots; the viewer and Compare don't draw them. Ratings and tags other
applications wrote into a file show until minivu's own catalog has a row
for it (4.6).

**Keywords and metadata.** The info panel (preview pane and viewer) has a
Keywords section for any file whose metadata can be written: a token per
keyword with a remove button, and an "Add keywords" field (comma separated,
Return adds). Image > Edit Metadata… (⌘I) opens a sheet for the selection
or the viewer's image: Description (Title, Caption, Creator with names
separated by semicolons, Copyright), Keywords (every keyword any file has,
"2 of 5" when only some have it), Date Taken (Leave unchanged, Shift by, Set
to) and Location (Remove location, with how many files have one). A field
whose value differs shows "Mixed"; left empty it keeps each file's value.
More than one file shows a progress sheet with Cancel, and a summary lists
failures, skipped files and raws whose own location stays.

**Filter and sort.** The toolbar's Filter menu (and View > Filter) shows
everything, images rated at least 1 to 5 stars, tagged images only, or
Photos Only or Videos Only. The toolbar menu also lists the folder's Finder
tags; View > Filter doesn't. More
Filters… opens a sheet with Type (JPEG, HEIF and AVIF, PNG, RAW, TIFF, GIF,
WebP, Photoshop, PDF, SVG, Video, Other), Date Taken (from and to, a
video's recording date), Camera model and Lens (part of the name, case and
accents ignored), ISO, Aperture and Focal length ranges, Keywords (all of
them), Label, Location (has one, has none), Orientation and a minimum width
× height. The symbol fills while a filter is on and the status bar says
"12 of 340 shown"; Show All clears every filter and is ticked only when none
is on. Header conditions are read in the background, 200 files a hop, and
images appear as they are known to match, never shown and then taken away.
Filters apply to images, never folders, and stay as the
user moves between folders. Sort by Rating puts the most stars first (ties
by name); Custom Order is the user's own arrangement, per folder, with new
files after it by name. Each sort key remembers its own direction, as
Finder's columns do.

**Find.** Edit > Find… (⌘F) opens a sheet: Search in (Pictures, each
sidebar folder, and the folder shown: only folders the user has granted),
Include subfolders, Name contains, Rating, Tagged only, then every More
Filters condition. Results replace the grid as a list titled "“IMG” in
Pictures"; Back returns. File > Save as Smart Folder… puts the search in
the sidebar, where clicking it runs the search again; its row's menu has
Edit Search…, Rename… and Delete Smart Folder….

**Collections.** File > New Collection… makes one from the selection; File
> Add to Collection ▸ (also in the grid's right-click menu) and dropping
images on a collection's row add to one; File > Remove from Collection
takes images out of the collection shown, never out of their folders. The
row's menu has Rename… and Delete Collection… ("The images in it stay where
they are.").

**Files.** Dropping files on the grid copies or moves them into its folder,
on a folder cell or sidebar row into that folder, by Finder's rules: same
volume moves, another copies, ⌥ copies and ⌘ moves. Files already in the
folder do nothing, except in Custom Order, where the drop reorders them at
the gap shown. In the flat view a drop never moves a file up from its
subfolder. Whether files are already there, or a folder would go into
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
A file renamed in Custom Order keeps its place. File > Share… (and the
toolbar button, and the right-click menu) offers the selected files, or the
lead image, to the system's share sheet; folders are left out.

**Videos in the browser.** A video's thumbnail has a dark capsule in its
bottom-right corner with a play triangle and the length ("0:12"), and its
length joins the pixel dimensions on the detail line. The preview pane
shows the still with "▶ 0:12" beside the stars; double-clicking it opens
the viewer. The info panel's Video section gives dimensions, duration,
frame rate, codec, audio, HDR and data rate, with Camera, Dates and GPS
from the movie's metadata.

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

**Live Text.** In the viewer, text in the picture can be selected by
dragging over it once the pointer has rested over the picture (the pointer
becomes an I-beam over text). ⌘C copies selected text, else the picture.
Edit > Copy Text (⇧⌘C) copies all the text found. View > Live Text (a
checkmark, on by default) turns it off; off, nothing is analysed. Not
offered while an edit tool is open or an animation plays, and not in the
preview pane or Compare.

**Videos in the viewer.** A video opens on its first frame with a large
play button. Space, P, the button or Image > Play Video plays and pauses it;
AVKit's floating controls then appear. M or Image > Mute Video mutes, and
the choice carries to the next video while the app runs. The arrows,
Page Down/Up, Delete, Home, End, the filmstrip and the wheel move between
items as for photos, stopping the video. Full screen works while it plays.
The HUD shows "Video, 1:05". Edit > Copy Frame and File > Save Frame As…
take the frame on screen at the video's own size.

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
(next/previous image, or zoom). Pinch zooms. On selectable Live Text a drag
selects and a press-and-hold selects, as in Preview. Clicks on a playing
video go to AVKit.

**Keyboard (viewer):** ← → / Space / Backspace next and previous, Home and
End first and last, ⌥→ ⌥← and ⌥Page Down ⌥Page Up next and previous page
of a document, Page Down and Page Up a page first and then the next or
previous image at either end, P plays and pauses an animation, Return
toggles full screen, Esc back to the browser, `+` `-` zoom, `/` actual
size, `*` fit, 0–5 rating, T or `` ` `` (backquote) tag, ⌘Z / ⇧⌘Z undo and
redo. On a video, Space and P play and pause and M mutes; every other key
keeps its meaning.

**Keyboard (grid):** arrows move the selection, Return opens, typing a name
selects it, 0–5 rate the selection and `` ` `` tags it. A digit or
backquote typed within a second of a letter continues the name instead
(so "IMG_2" can still be typed), and T always types a name in the grid, as
letters do in Finder; ⌘T tags from anywhere. F2 renames.

**Compare:** Image > Compare Selected (⌥⌘K) shows 2 to 4 images side by
side with synchronised zoom. A video is compared by its first frame, and the
pane's second line reads "Video, 0:12".

**Menu shortcuts.** One table for the whole menu bar; a test checks that
no two items share a shortcut (display-only ones included) and that each
resolves to its item. Preview's shortcuts win where it has one, then
Photoshop's letters, moved to a free modifier when the plain one is taken.
Items marked "display" show their key only while the menu is open, so the
key reaches the grid, the viewer or a text field otherwise.

| Menu | Item | Shortcut |
|---|---|---|
| minivu | Settings… | ⌘, |
| | Hide minivu / Hide Others / Quit minivu | ⌘H / ⌥⌘H / ⌘Q |
| File | Open Folder… / Add Folder to Sidebar… | ⌘O / ⇧⌘O |
| | New Folder | ⇧⌘N (Finder) |
| | Open in Viewer / Close Window | ⌘↓ / ⌘W |
| | Save / Save As… | ⌘S / ⇧⌘S |
| | Save Frame As… | none |
| | Revert to Saved | none (as in every Mac app) |
| | Save Edits as Preset… | none |
| | Rename | F2 (Explorer, FastStone; Return opens and ⌘R rotates) |
| | Copy To > / Move To > (recent folders, Choose Folder…) | none |
| | New Collection… / Add to Collection > / Remove from Collection / Save as Smart Folder… | none |
| | Reveal in Finder / Share… / Move to Trash | ⌥⌘R / none / ⌘⌫ |
| | Page Setup… / Print… | ⇧⌘P / ⌘P |
| Edit | Undo / Redo | ⌘Z / ⇧⌘Z |
| | Cut / Copy | ⌘X / ⌘C |
| | Copy Text | ⇧⌘C |
| | Copy Subject / Copy Frame | none |
| | Paste / Select All | ⌘V / ⌘A |
| | Select Tagged / Invert Selection | none / ⇧⌘I |
| | Find… | ⌘F (Finder, Photos) |
| View | Sort By > (keys, Ascending, Descending) | none |
| | Show Hidden Files | ⇧⌘. |
| | Flat View | ⌥⌘F |
| | Filter > Show All, ★ or More … ★★★★★ or More, Tagged Only, Photos Only, Videos Only, More Filters… | none |
| | Theme > / Live Text | none |
| | Show Sidebar / Show Preview Pane / Enter Full Screen | ⌃⌘S / ⌥⌘P / ⌃⌘F |
| Image | Fit to Window / Actual Size / Zoom In / Zoom Out | ⌘9 / ⌘0 / ⌘= / ⌘- |
| | Rotate Left / Rotate Right | ⌘L / ⌘R (Preview) |
| | Flip Horizontal / Flip Vertical | none |
| | Resize/Resample… | ⌥⌘I (Photoshop's Image Size) |
| | Canvas Size… | none |
| | Crop… | ⌘K (Preview) |
| | Straighten… / Perspective… | none |
| | Adjust > RAW Adjustments… | none |
| | Adjust > Lighting… | ⌥⌘L |
| | Adjust > Colors… | ⌥⌘C (Preview's Adjust Color) |
| | Adjust > Curves… | ⇧⌘M (Photoshop's ⌘M is Minimize here) |
| | Adjust > Levels… | ⇧⌘L (Photoshop's ⌘L is Rotate Left here) |
| | Adjust > Auto Enhance / Sharpen… / Blur… / Noise Reduction… | none |
| | Effects > Grayscale / Sepia / Negative | none |
| | Effects > Drop Shadow… / Frame… / Bump Map… / Sketch… / Oil Painting… / Lens… / Vignette… | none |
| | Retouch > Clone Stamp… / Healing Brush… / Red-Eye Removal… | none |
| | Text and Shapes… / Watermark… / Remove Background… | none |
| | Play Animation / Pause Animation (Play Video / Pause Video on a video) | P (display) |
| | Mute Video / Unmute Video | M (display) |
| | Rating > Clear Rating, Rate 1–5 Stars | ⌃0–⌃5 (the grid and viewer also take bare 0–5) |
| | Tag / Remove Tag | ⌘T (no tabs or Fonts panel to clash with; bare `` ` `` in the grid and viewer, T in the viewer) |
| | Label > None, Red, Orange, Yellow, Green, Blue, Purple, Gray | ⌥⌘0–⌥⌘7 (no ⌥⌘ digit was taken; ⌥⌘8 is the system's Zoom) |
| | Compare Selected | ⌥⌘K (⌘K is Crop) |
| | Histogram | ⇧⌘H (⌘H and ⌥⌘H hide apps) |
| | Count Colors | none |
| | Edit Comment… | none |
| | Edit Metadata… | ⌘I (Finder's Get Info, Photos' Info) |
| Go | Next / Previous / First / Last Image | → ← Home End (display) |
| | Next Page / Previous Page | ⌥→ / ⌥← (display) |
| | Enclosing Folder / Back / Forward | ⌘↑ / ⌘[ / ⌘] |
| Tools | Start Slideshow | ⇧⌘F (Preview) |
| | Export Slideshow Video… | none |
| | Batch Convert… / Batch Rename… | ⌥⌘B / ⇧F2 (beside Rename's F2) |
| | Extract Pages… / Find Duplicates… | none |
| | Create Multi-Page File… / Image Strip… / Contact Sheet… / Create Web Gallery… / Montage Wallpaper… / Set as Desktop Picture | none |
| | Capture > Entire Screen / Window… / Selection… | none (the system keeps ⇧⌘3–⇧⌘5) |
| | Open in External Editor > editors…, Edit Editor List… | ⌘E for the first editor |
| Window | Minimize / Zoom | ⌘M / none |
| | Move to Next Display | ⌃⌥⌘→ (fn⌃ is window tiling, ⌃ is Spaces) |
| | Bring All to Front | none |
| Help | minivu Help / Keyboard Shortcuts | ⌘? (as in every Mac app) / ⌘/ |

**Editing tools.** The viewer's tools panel and the Image menu hold every
tool; each opens an inspector (or, for Auto Enhance, acts at once) and
applies as one undo step. New since Phase 6: RAW Adjustments (RAW files
only: exposure, boost, highlight recovery, white balance, luminance and
colour noise, starting at the camera's settings), Auto Enhance, Noise
Reduction (level and sharpness), Vignette (amount, radius, feather),
Perspective (four corner handles over the uncorrected picture, Auto, Show
result, numeric fields for VoiceOver), Canvas Size (a sheet with size,
anchor and fill), Watermark (text or a picture, size, opacity, position,
margin, tiling) and Remove Background (the subject found by Vision, a
transparent or coloured background). Edit > Copy Subject puts the cut-out
subject on the clipboard as PNG and TIFF without changing the document.
File > Save Edits as Preset… saves the photo's edits as a Batch Convert
preset, listing what is included and what is left out with the reason.

**Tools (Phase 7 and waves 1–2).** In the browser each tool works on the
selected images, or on every image shown when none is selected (4.8); a
slideshow of a single selected image plays the whole folder from it. In the
viewer they work on the image shown, and the slideshow plays the viewer's
list from it. Picture tools skip videos.

- *Slideshow:* full screen where the full-screen viewer would open (Settings >
  Viewer > "Full-screen viewer opens on"), black
  background, HDR as in the viewer. Eight transitions rendered by one Metal
  shader (cross-fade, fade through black, slide, push, wipe, zoom, iris,
  dissolve) or a random one per slide; interval, order (in order or
  shuffled), loop, captions (name, date, EXIF line), and a music playlist
  (MP3, AAC/M4A, WAV, AIFF chosen by the user) through AVFoundation that
  fades out at the end; volume and Play music changed in Settings apply to
  a show that is running. Space pauses, arrows step, Esc ends; the pointer
  hides and a small control bar appears when it moves. Next images decode
  ahead through the image loader. Videos are skipped.
- *Export Slideshow Video:* a sheet with Resolution (720p, 1080p, 4K or
  Screen size), Frame rate (24, 30, 60), Codec (H.264, HEVC), Quality (Low,
  Medium, High) and File (.mp4 or .mov), three lines saying what the video
  takes from Settings > Slideshow with a Slideshow Settings… button, and a
  summary ("12 pictures · 1:05 · 1920 × 1080"). Export… asks for the file,
  then shows progress with Cancel; Cancel leaves no file. Reduce Motion is
  not applied to the file, and the sheet says so.
- *Batch Convert:* a Preset row (Save, Rename, Delete Preset…), output
  format and its options (the Save As options, Remove location, Keep HDR
  for JPEG, HEIC and AVIF), an Edits section (the preset's steps, each
  removable for this batch) with a Watermark (Add…, Edit…, Remove), a Pages
  section (first page only or every page), destination folder (chosen, or
  beside the originals), file names from a rename pattern, and optional
  resize (long side, width, height or percent, with any of the 11 filters)
  and rotate/flip. Runs off the main thread, a few files at a time, with
  progress, Cancel and a summary of files that failed. Nothing goes to the
  Trash without being named first: replacing originals, or files that only
  share an output's name, is asked (Replace, Keep Both or Cancel).
- *Batch Rename:* a Preset row, a pattern of text and tokens (name, counter
  with start and digits, date taken, date modified, extension), find and
  replace, and letter case, with a live before/after list that flags
  clashes before anything changes; one undo step. Videos are renamed too.
- *Extract Pages:* the Batch Convert sheet in a mode of its own (all pages
  or a range; each page or frame a file of its own).
- *Find Duplicates:* one window. Look in (the selection, the folder or the
  images shown, or the folder and subfolders), Find (Identical Files or
  Similar Images), Find (Return) and Stop (Esc). Results are groups with a
  checkbox, thumbnail, name, folder, dimensions, size and date per file,
  and a Keep badge on the file the Keep rule (Highest Resolution, Largest
  File, Oldest) suggests. A Similarity slider regroups without analysing
  again. Mark Suggested ticks every file but each group's keeper; Move to
  Trash… asks first and warns when a whole group is marked. Show in Browser
  and Compare hand files to the browser and Compare.
- *Create Multi-Page File:* a numbered, reorderable list of pages (Move Up,
  Move Down, Reverse; every page of multi-page sources by default) and a
  format: Multi-Page TIFF (compression), PDF (page size, margin, lossless
  or quality), Animated GIF (frame delay, loops, frame size, background) or
  Animated HEIC. Save… asks for the file; pages that can't be read are left
  out and listed.
- *Image Strip:* the same list, Arrange (side by side, one above another,
  grid), sizes, spacing, margin, background and file format. The size is
  shown live; the saved strip opens in the viewer.
- *Print:* the system print panel with a layout accessory (images per page,
  fit or fill, margins, caption) and its live preview; Page Setup is the
  standard sheet. Images are drawn colour-managed at the printer's
  resolution, decoded only for the pages being drawn.
- *Contact Sheet:* columns, rows, cell spacing, captions, header text,
  page size in pixels and background, saved as JPEG, PNG, TIFF or a
  multi-page PDF, with a preview of the first page.
- *Create Web Gallery:* a sheet with Title, Pictures (thumbnail size,
  large picture size, include the original files), Layout (columns or
  "Fit the window", theme, order), Captions (file name, title and caption,
  date taken) and File (JPEG, HEIC or AVIF, quality, keep metadata, remove
  location). Create… asks for the folder the gallery goes in; the gallery
  is a new folder named after the title, never replacing anything.
- *Montage Wallpaper:* a collage of the images at the size of the display
  (grid, mosaic or scattered, spacing, background), saved to Pictures/minivu
  Wallpapers and set as that display's desktop picture. Set as Desktop
  Picture uses a single image: the file itself when it is a JPEG, PNG, HEIC
  or TIFF inside Pictures with no unsaved edits, otherwise a copy in
  Pictures/minivu Wallpapers (the newest 10 copies are kept).
- *Capture:* the entire screen, a window picked with the system's content
  picker, or a dragged selection, through ScreenCaptureKit, saved as PNG to
  Pictures/minivu Captures and opened in the viewer. Only Entire Screen and
  Selection need screen recording permission; picking a window is consent.
- *External editors:* a list in Settings > Editors of applications chosen
  by the user; each opens the selected images or the image shown, and the
  viewer reloads a file an editor saved. If the viewer has unsaved edits of
  that file it asks first: Reload (discarding them) or Keep My Edits, after
  which Save asks for a name, so neither version is lost.

**Shortcuts.** minivu's actions appear in the Shortcuts app: Convert Images
(format, quality, long side, remove location), Resize Images (by long side,
width, height or percentage), Rename Images (a Batch Rename pattern), Set
Rating, Set Colour Label and Open in minivu. A shortcut that receives images
from Quick Actions can be turned on as a Finder Quick Action. There are no
menu items or keys for them.

**Settings.** Panes: General, Viewer, Magnifier, Thumbnails, Slideshow,
Editors. General holds "Write ratings into files (XMP)" (off by default).
Batch presets, the slideshow video and web gallery choices are remembered
in their own sheets, not in Settings.

**Help.** Help > minivu Help opens a window of bundled pages (Getting
Started, Browser, Viewer, Editing, Effects & Retouching, Tools, Settings,
Privacy, Keyboard Shortcuts) with a page sidebar and search that filters the
pages and highlights matches. There is no Help Book and nothing is fetched.
Pages come in the user's language where translated (4.13).
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
   decoding, thumbnailing, header reads, database writes and file
   operations happen off it. A `Catalog.didChange` that names ratings
   touches no disk.
2. Never decode more pixels than will be shown.
3. Never copy pixels between CPU and GPU; share the memory.
4. Draw only when something changed.
5. Cancel work for things that scrolled away.
6. No dependencies. If Apple's frameworks can do it, use them; if not,
   write the small piece we need.
7. Never block a cooperative thread on Vision, HEIF or AVIF encoding or an
   AVFoundation wait. Use `BlockingWork` or `BatchWorkExecutor`. On the
   pool this doesn't only slow things down: it can deadlock (4.12).
8. Keep localized lookups off hot loops. Look up text that never changes
   once, into a `static let`, and never localise inside a per-pixel,
   per-row or per-file loop (4.13).
9. Nothing runs while idle and nothing is indexed ahead of time. Live Text
   analyses only on pointer movement over the picture or Copy Text; a video
   player exists only while asked for; a tree is walked only when asked
   for, within the walk limits (4.9).
10. A metadata condition reads each file's header once, ever; the catalog's
    cache answers the next search.
11. Signpost phases, never pixels or rows (4.14), and check a change that
    touches decoding, the browser, the viewer, editing or Batch Convert
    against the budgets below.

**Budgets** (docs/PERFORMANCE.md, section 5). Counts, meant to be checked in
CI, since they don't depend on how busy the machine is. This isn't wired up
yet, and the first two need test photos, which CI doesn't have:

| Check | Budget |
|---|---|
| File opens per viewer flip (not yet loaded) | ≤ 4 |
| Header reads in Find, first time | = number of files |
| Catalog transactions per copied or moved file | = 1 |
| Change notices when moving files into the shown folder | ≤ number of files + 2 |
| Thumbnail decodes on a warm first screen | = 0 |

Times, on the reference Mac (M4, 16 GB) against a saved baseline:

| Benchmark | Budget |
|---|---|
| `viewer.next_warm` | median < 16 ms |
| `viewer.open_jpeg` | median < 50 ms |
| `edit.slider_lighting` | median < 16 ms |
| `edit.slider_rawExposure` (dragging) | median < 33 ms, if reachable |
| `edit.cropDragFrame` | p90 < 16 ms |
| `files.rename1000` | main thread < 130 ms, longest freeze < 33 ms |
| `files.move1000Shown` | main thread < 30 ms |
| `folder10000.openInWindow` | median < 190 ms |
| `folder1000Photos.ratingSortOpen` | median < 1,200 ms |
| `batch.jpeg2048_20` | median < 1,000 ms, peak < 600 MB |
| any window benchmark | longest main-thread freeze < 50 ms |
| `memory.gridScroll5000`, `batch.heicFull_20`, `batch.avifFull_20` | peak ≤ 1.3 × the baseline |

Several of these are targets not yet met; PERFORMANCE.md section 4 is the
plan that meets them.

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

**Gap goals** (from the 2026-11-14 gap analysis; built in waves 1 to 3):

| Goal | What | Status |
|---|---|---|
| G1 | Metadata editing: title, caption, keywords, creator, copyright, date shift, remove location; batch | Done. Location can be removed, not edited |
| G2 | Ratings and the tag readable from and (opt-in) written to XMP | Done |
| G3 | Find across folders, flat view, More Filters, smart folders, collections | Done |
| G4 | Colour labels (Finder tags) and keywords | Done |
| G5 | Duplicate and similar image finder | Done |
| G6 | Batch presets with edits, watermark operation | Done |
| G7 | Live Text in the viewer | Done |
| G8 | Remove Background and Copy Subject | Done |
| G9 | Slideshow export to video | Done, SDR only. HDR video export is deferred |
| G10 | RAW Adjustments | Done |
| G11 | Auto Enhance, Noise Reduction, Vignette, Perspective, Canvas Size | Done. No separate Auto Levels |
| G12 | Shortcuts actions (App Intents) | Done. Quick Look extension assessed and not built; no Services entries |
| G13 | Localisation: ten languages, machine translated | Done; native review pending |
| G14 | AVIF export | Done (animated AVIF not possible) |
| G15 | Share sheet | Done |
| G16 | Lossless JPEG crop | Excluded by Harman |
| G17 | Multi-page builder, Extract Pages, image strip, every page in Batch Convert | Done |
| G18 | Videos in the grid and viewer | Done |
| G19 | Show on a map | Excluded by Harman |
| G20 | Signed and notarised build | Excluded by Harman |
| G21 | HTML web gallery | Done |
| G22 | Face recognition, semantic search, generative fill | Excluded by Harman |
| G23 | Panorama, HDR merge, focus stacking | Excluded by Harman |

Next: the speed-up plan in docs/PERFORMANCE.md section 4, starting with
phase 0 (making the measurements trustworthy).

### Selection and the clipboard

Edit > Select Tagged and Invert Selection act on the entries the grid is
showing, not on the folder: a filter is the user saying which images they
are working with. Select Tagged leaves folders out, since the tag is a
catalog mark on an image; Invert Selection takes them, as Select All does.

Copy in the browser writes the selected files to the pasteboard as the same
object the grid's drag source writes, so dragging out and copying agree.
Paste goes through the same transfer the drop uses, so it inherits the
name-conflict alert, the undo step, the catalog bookkeeping and the write
queue's waiting; it copies and never moves, because the pasteboard says
nothing about what was meant to happen to the originals. Copy in the viewer
copies selected Live Text when there is a selection; otherwise it renders
what the canvas is drawing, an open tool's unapplied change
included, in the colour space Save As would use, so a copy and a saved copy
are the same picture. No file URL goes with it: with unsaved edits that
would be a second, different answer to what was copied. Copy is off for a
video, whose still is not the video; Copy Frame copies the frame on screen
at the video's own size. Copy Subject copies the cut-out subject, cropped
to it, as PNG and TIFF. Copy Text copies every piece of text Live Text
found. Each writes the pasteboard only once its picture or text is ready,
so a failure beeps and leaves the clipboard as it was.

### Building with Xcode 26

Swift 6.3 cannot compile this module for release. Every Xcode 26 tried
(26.0.1, 26.3, 26.6) dies with signal 11 in the SIL optimiser's
EarlyPerfInliner on a class's deallocating deinit. It is not one class:
fixing the first only moved the crash to the next, and every class has a
deinit. It is not whole-module optimisation either, which was ruled out by
building without it. Debug builds and the whole test suite are fine on
6.3, and Swift 6.2 builds a release normally, so this is a compiler
regression rather than anything the app does.

Continuous integration therefore builds and tests but does not package;
`scripts/make_app.sh` is run on a machine with Swift 6.2 or later. The
steps to put back are named in the workflow. Xcode 26.2 ships Swift 6.2.3
and builds a release normally, and Swift 6.4 (Xcode 27) builds and
packages a release too.

Xcode 26 also makes the Metal compiler a separate download. Without it
`make_app.sh` says so and skips precompiling the shaders, and the app
compiles the bundled sources at launch instead; `xcodebuild
-downloadComponent MetalToolchain` puts the precompiled `default.metallib`
back in the bundle. The App Intents metadata step needs the Xcode
toolchain's `appintentsmetadataprocessor` as well.

### Core Image on macOS 27

Changes in macOS 27 cost HDR and opacity, and are worked around where
they bite. All were found by measurement, and the workarounds are written
so an OS without the change behaves as before. Every effect and tool is in
`hdrHighlightsSurviveEveryKindOfTool`, so a new site shows up as a failing
test.

The node `clampedToExtent` makes is materialised in an 8-bit buffer when
the context works in half float and a resampling filter consumes it in the
same graph, so values are clipped to 1 (and quantised) before the resample
runs. `CILanczosScaleTransform`, `CIBicubicScaleTransform` and
`CIUnsharpMask` all trigger it; a Gaussian blur and a plain affine do not,
and rendering the clamped image to a texture first avoids it at the cost
of a buffer. Every edit preview goes through the screen proxy, which is
Lanczos, so an HDR photo lost its highlights the moment a tool touched it
while full resolution kept them — the asymmetry that gave it away.
`EditRenderer.lanczos` now resamples the image as it stands and composites
the result over an affine copy of the clamped one, which is opaque
everywhere the kernel would otherwise have sampled transparent black, and
`EditGraph`'s sharpen drops the repeat the unsharp mask does not need.
Working in full float instead would fix every site at once, but doubles
every intermediate and costs about 13% on export.

A `clampedToExtent()` image read by a sampling general kernel (a `CIKernel`
with a sampler) is clipped to 1 the same way. The noise-reduction kernel
and the bump map therefore read the photo as it stands and hold their
sample positions to the image's bounds in the kernel (`bounds`); the bump
map's height field is blurred over repeated edges only by a Gaussian blur,
which doesn't clip. A warp kernel over a clamped image (lens, perspective)
does not clip. `CINoiseReduction` and `CIVignetteEffect` clip to 1 in this
context whatever their input, so both are kernels of our own.

A `CIImageProcessorKernel` is handed an input region a pixel larger on
every side than the one its `roi` asked for, and that ring is Core Image's
own transparent padding rather than rendered content. A kernel that clamps
a sample to its texture therefore repeats the padding instead of the
picture's edge. The oil paint kernel is given the picture's bounds inside
the texture (`sourceBounds`) and clamps to those.

The cooperative-pool deadlock (4.12) is another measured macOS 27
behaviour, in GCD rather than Core Image.

## 8. Known limits

- **Editing:** Save keeps HDR only for gain-map JPEG, HEIC and AVIF
  originals; PQ/HLG files and gain maps in other formats are saved tone
  mapped to SDR, and Save As is always SDR. Saving writes a new file in
  place of the old (atomically), so a hard link to the old file keeps the
  old picture, and a symbolic link is written through to the file it points
  at.
- **Edit tools:** Auto Enhance judges an 8-bit SDR rendering of an HDR
  photo (the adjustment itself keeps HDR), and running it twice stacks two
  steps. Perspective corners can't go outside the image, the true
  proportions are estimated from the longer edges, and bilinear sampling
  softens strong corrections a little. Canvas Size is in absolute pixels.
  The watermark is one line of text, with no rotation, outline or shadow,
  in a straight grid when tiled; a picture is drawn at 8 bits; a stamp too
  large for the photo is shown smaller than the Size slider says. Remove
  Background takes all subjects or none, with no brush, feathering or
  translucent fill, and the edge is as soft as Vision makes it; Vision may
  find nothing in landscapes and textures.
- **RAW Adjustments:** no white balance picker, sharpness, local contrast,
  moiré or lens correction. The settings reach a file only through Save As
  or Copy. A RAW step makes every later render use the engine, and if the
  engine's framing differs from the embedded preview's by a few pixels,
  operations stored in absolute pixels (Canvas Size, Resize) sit that far
  off. A full-resolution render while zoomed in costs a full development
  (about 0.6 s for 24 MP) each time the slider settles.
- **Files:** Save's own-write record is by path, so a comment written in
  minivu after another application changed a file being edited lets Save
  replace that version. Captures, montages and desktop copies take a free
  name just before writing, in the write queue; a file another app creates
  under that name in the same instant would be replaced.
- **Metadata:** camera raws keep their own location (minivu never modifies
  raws), and the grid, sort and Batch Rename still read a raw's own EXIF
  date, not its sidecar's. A raw and a GIF with the same base name share
  one sidecar. Only the x-default language of a title, caption or rights is
  edited. A PNG metadata write keeps only what XMP can express; a TIFF
  maker note pointing outside its own blob would lose what lies outside.
  A folder opened through a single file may not allow a sidecar. Writing
  to a hard-linked file replaces it with a new inode. A video's metadata,
  location included, is shown, never edited or removed.
- **Marks:** ratings are written into files only while the setting is on;
  turning it on doesn't write marks already in the catalog. To take a
  file's newer rating over a catalog row, rate it again in minivu. A change
  pending for a file moved within the 0.8 s quiet period is not written.
  `xmp:Label` is never read; Windows' EXIF rating tags and IPTC StarRating
  aren't read. Ratings and tags of videos stay in the catalog. The XMP
  mapping follows the other applications' documentation and was not checked
  against them on a Mac.
- **Labels:** images only, not folders; one colour label per file. The
  viewer and Compare don't draw labels, and the browser's dots refresh when
  it becomes key again. A file whose tags can't be read or written beeps
  and is logged.
- **Search and lists:** walks stop at 12 levels, 20,000 images or 5,000
  folders, and say so. The flat view and lists don't heal marks of files
  moved in Finder (their folders do when opened); only a flat view's top
  folder is watched and lists aren't. Without Spotlight, a metadata search
  of a huge tree reads every header once (about 11 ms a file cold). The
  metadata cache trusts size and date, so a file changed with its date kept
  shows old values. A collection member moved in Finder to a folder the
  sandbox can't see stays missing until it is granted; whether `fsgetpath`
  works under the App Sandbox in the packaged app is unverified (healing is
  the fallback). An older minivu opening a schema 4 catalog can cache empty
  video metadata again, and the newer build won't read those rows again.
- **Find Duplicates:** similar images are found within one run, at most
  10,000 (8 GB Macs) or 20,000. Single linkage can chain a long burst into
  one group at loose thresholds. Hard links count as identical files.
  Prints from a 256 px decode don't see small differences. A cached
  fingerprint follows its file by identity and trusts size and date.
- **Batch Convert:** every-page output is one file only for TIFF and GIF;
  multi-page outputs carry no metadata; HDR is kept only as a gain map
  (JPEG, HEIC, AVIF), with Keep original or Display P3 at 8 bits. No
  preview of a preset on the first image, and the batch watermark editor
  has no preview. Crop and Perspective use the same fractions on every
  photo; Resize and Canvas Size are left out of presets rather than made
  relative. RAW Adjustments in a preset carry absolute white balance. Save
  Edits as Preset… applies an open tool's change first, and Cancel doesn't
  take it back (Undo does). A preset saved while another window's Convert
  sheet is open appears there next time it opens.
- **Multi-page files:** animated GIF and HEIC are limited by memory as a
  whole, TIFF and PDF only by one page. Animated HEIC records no loop
  count and gives the last frame the delay of the one before (ImageIO,
  macOS 27). No animated AVIF. A PDF's pages are rendered, not their
  embedded images extracted. Multi-page TIFFs stop at 4 GB. Strips and
  multi-page files are SDR, have no live preview, and are not available
  from the viewer or Shortcuts.
- **Slideshow:** resuming after a pause waits a full interval. A caption
  longer than the space beside the control bar is truncated in the middle.
  Changing HDR or RAW settings mid-show changes the slide on screen only at
  the next slide. Videos are skipped.
- **Slideshow video:** SDR only (HDR video is a later step: HEVC Main10
  with HLG). Reduce Motion is not applied to the file. No per-video
  overrides of the slideshow settings; random transitions differ between
  exports. An export can't be paused, and quitting abandons it. The
  dialog's count can be higher than the video's if some headers turn out
  unreadable.
- **Web gallery:** pictures are made one at a time. Page text is fixed
  English. Three themes, no templates. HEIC galleries show only in Safari.
  Animations become stills and multi-page files give their first page.
- **Volumes:** Save As and Contact Sheet don't check `VolumePolicy` on
  their destination yet (the slideshow video, the web gallery and Batch
  Convert do).
- **Videos:** never edited, trimmed, converted or written. No frame
  stepping, speed or loop controls. Double-clicking a playing video doesn't
  close the viewer (AVKit takes the click). Before macOS 26, turning HDR off
  can't make AVKit play an HDR video in standard range. The grid's length
  comes from the container and may be a frame or two out. Compare shows a
  first frame only; Copy Frame and Save Frame As are in the viewer only,
  SDR and without metadata. Finder's Open With doesn't offer minivu for
  movies (`CFBundleDocumentTypes` lists images only), and the filmstrip
  shows a video without the grid's play mark.
- **Live Text:** on text, a drag selects rather than pans and
  press-and-hold selects rather than magnifies. A playing animation has no
  Live Text. Text too small to read at 4096 px is not found. Recognition
  languages are the system's.
- **Share:** the toolbar button shows the system's picker directly, so it
  doesn't go through `FileSharing` (fine in the browser, which has no
  edits). Many files are offered without a confirmation.
- **Shortcuts:** a shortcut run while minivu isn't open launches it with
  its browser window, and it stays running. Rename works only in Pictures
  and sidebar folders. Set Rating rates the file at the path it is given,
  which may be a temporary copy. Siri phrases are unverified (no phrase
  training) and phrases and parameter summaries are English only. Shortcuts
  itself could not be run by the agents that built this; the metadata in
  the bundle is what was checked.
- **Localisation:** every translation awaits native review. Units after a
  number field in Polish and nouns after a formatted number can't agree
  with every number.
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
- **Menus:** the viewer control bar's slideshow button sends its action
  straight to `NSApp`, so it may not be disabled while a viewer sheet is up.
- **Development:** the cooperative-pool check is debug-only and covers the
  helpers listed in 4.12; a new framework call that waits on GCD needs its
  own line. A suite that blocks the pool without the trait is caught late,
  at the watchdog's limit. `BlockingWork` below user-initiated QoS
  (`renderForExport` at low task priority, the full-size preview at
  `.utility`) relies on nothing blocking the pool. The check reads GCD's
  queue labels and goes quiet if Apple renames them.
