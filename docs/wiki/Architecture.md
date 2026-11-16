# Architecture

Swift 6 with strict concurrency, built with SwiftPM and its Swift Build engine (the package needs Swift 6.2 or newer; it is developed with Swift 6.4.2). No Xcode project, and no third-party code: below the app there are only Apple's frameworks (AppKit, SwiftUI, Metal, Core Image, ImageIO, PDFKit, AVFoundation, AVKit, ScreenCaptureKit, Vision, VisionKit, App Intents and the system SQLite). The full spec, with the reasoning behind each rule, is [DESIGN.md](https://github.com/Harmanjit/minivu/blob/main/DESIGN.md); this page is the overview.

## Modules

Three modules, one process.

| Target | Role |
|---|---|
| `MinivuCore` | Decoding with ImageIO, PDF and SVG rendering, video stills and details with AVFoundation, metadata, folder listing and the folder watcher, file operations, the catalog, the thumbnail cache, encoding and safe file writes, lossless rotation, JPEG comments, metadata writing and XMP sidecars, ratings read from and written to files, batch rename, page and montage layout, the tree walk and search behind Flat View and Find (`Search/`), the duplicate finder (`Duplicates/`), multi-page files (`MultiPage/`), web gallery pages (`WebGallery/`), and the signposts. No GPU and no windows, so its tests run in milliseconds. |
| `MinivuRender` | Every Metal object: the device and shaders, textures, the texture cache and image loader, the canvas renderer, RAW rendering and the RAW tool's develop settings, the edit document, graph and kernels (watermark and subject masks included), the histogram, batch conversion with presets and HDR gain maps, slideshow transitions and the slideshow video writer, the picture Live Text reads. |
| `Minivu` | The AppKit application: the menu bar, the browser (sidebar with collections and smart folders, grid, preview pane, Find and filters), the viewer and its fly-out panels, video playback, Live Text, the edit tools, the compare window, Save and the write queue, the tools (slideshow and its video export, batch, multi-page files, Find Duplicates, print, contact sheet, web gallery, montage, desktop picture, capture, share, external editors), the Shortcuts actions (`Automation/`), Settings, the Help window and its pages, and the snapshot harness. |

Each module has its own String Catalog of translations (see **Localisation** below). A fourth, test-only C target, `MinivuTestWatchdog`, ends a test run that hangs (see **Tests**); it is never in the app.

The browser grid, folder tree and image canvas are AppKit: `NSCollectionView` recycles cells, `NSOutlineView` loads folder children lazily, and the canvas is an `NSView` backed by a `CAMetalLayer`, so the app decides exactly when a frame is drawn. SwiftUI, hosted in AppKit, is used where it isn't a hot path: the info panel, edit inspectors, Settings, dialogs and Help.

## From file to screen

1. **Open** a `CGImageSource` with caching off, and read the header: pixel size, orientation, pages, and whether the file carries HDR (a gain map, or a PQ or HLG transfer).
2. **Decode at the size shown.** A screen-sized request asks ImageIO for a thumbnail with a maximum pixel size, with EXIF orientation applied there. The size is snapped to 1/2, 1/4 or 1/8 of the image, whichever is the smallest that covers the need within 3%, because JPEG decoders make those fractions almost for free by skipping DCT coefficients; any other size is a full decode plus a resample. The GPU's mipmapped sampling hides the few percent.
3. **Convert colour once.** The image is drawn into memory minivu allocated page-aligned, in the working colour space, and ColorSync honours any embedded profile. SDR photos become 8-bit Display P3 (`bgra8Unorm_srgb`, so the GPU linearises on sampling and mipmaps filter in linear light). HDR images, images with more than 8 bits per channel and wider-than-P3 images become extended linear Display P3 in `rgba16Float`, where values above 1.0 are highlights brighter than white.
4. **Wrap without copying.** That memory becomes an `MTLBuffer` (`bytesNoCopy`) and a texture view of it. Apple Silicon's unified memory means the GPU reads the pages the CPU wrote.
5. **Mipmap on the GPU.** One blit copies into a private mipmapped texture and generates the mip chain, and the CPU memory is freed.
6. **Draw.** The canvas draws one full-screen triangle. The fragment shader maps each screen pixel into the image through a 3×2 matrix and samples trilinearly, so the cost follows screen pixels, not image pixels. The magnifier is the same shader with a second, more magnified transform inside its circle, and above 200% the shader can sample the nearest pixel (**Pixelated zoom above 200%**).
7. **Refine.** When the zoom or the magnifier needs more pixels than the screen-sized texture holds, the full-resolution decode runs in the background and replaces the texture; a preview and the full texture sit under the same zoom and pan.

Images larger than 16384 px on a side, Metal's texture limit, are shown downscaled to it. PDF pages and SVGs are rendered rather than decoded, at two pixels per point for actual size. A size a file declares is checked where it enters the app: an SVG or PDF that claims an absurd size is refused, and exports compare the claimed size with a budget of a quarter of RAM before decoding.

**Videos** take the same path for their still: AVFoundation decodes a frame (the first for the viewer, one a little way in for the thumbnail) on a GCD thread, and it becomes a texture like a photo, cached and prefetched. Nothing plays until asked; then an AVKit player view sits over the canvas, one at a time, and is released when you move on.

**The screen.** The canvas layer is `rgba16Float` in extended linear Display P3. EDR is turned on only while an HDR image is shown, on a screen that can show some of it, because EDR raises the backlight and costs power. Every frame knows the display's current headroom (1.0 on an SDR screen, more on an HDR one, most at lower brightness). When an image reaches higher than the screen can show, the present shader passes values below three quarters of the headroom through and rolls anything above off smoothly to the headroom, so one code path gives real highlights on an XDR screen and a tone-mapped image on an SDR one. The slideshow's shader calls the same function, and a test checks the shader against a Swift copy of the curve.

Frames are drawn on a display link that pauses itself whenever nothing has changed.

## The texture cache and prefetch

`TextureCache` keeps decoded textures on the GPU after they leave the screen, so going back costs nothing. Its budget is 1/8 of RAM, at least 256 MB and at most 1.5 GB, least recently used first out. A texture is keyed by file, modification date, page and size, so an edited file simply misses. A memory-pressure warning trims it to half the budget; a critical one keeps only the texture used last.

`ImageLoader` gets images onto the GPU:

- **One decode per image and size.** A request for something already decoding joins that job.
- **At most three decodes at once,** because a 24 MP decode holds about 100 MB until it is uploaded. Prefetches never take the last slot, so a jump to a distant photo starts at once.
- **One RAW render at a time,** in a slot of its own (see below).
- **Stale work stops.** When everyone who asked for a job has cancelled, a waiting job is dropped and a running one skips its upload.

The viewer prefetches two images ahead and one behind in the direction you are moving, at screen size only, and the next page of a PDF or multi-page TIFF first. Changing **Display HDR photos in HDR** or the RAW settings empties the cache, since textures made under the old settings are wrong.

## RAW

A RAW file shows the preview the camera embedded when it covers the size needed; that is fast and has the camera's colours. When it doesn't (many cameras store 1616 px, or you zoom past it), or **RAW files** is set to **Render RAW data**, or **Render RAW files with extended dynamic range** is on, the sensor data is rendered by Apple's RAW engine: `CIRAWFilter` builds the graph and a Core Image context on minivu's Metal queue renders it straight into a mipmapped texture, without visiting the CPU. Extended dynamic range reaches about twice SDR white, the most the engine gives.

The engine is heavy on memory: about 1.6 GB of footprint for a full-size 24 MP render and 0.8 GB for a screen-sized one, held for about five seconds. So renders run one at a time, and only the nearest RAW neighbour is prefetched as a render. On Macs with 8 GB of RAM or less none is (embedded previews still are), and there the Core Image context also gets a 512 MB memory limit, which lowers the footprint at some cost in speed. A camera the engine doesn't know shows its embedded preview, as large as the camera made it.

## Editing

An `EditDocument` holds the decoded original and an ordered list of `EditOperation` values; undo and redo move a cursor through the list, capped at 50 steps, so undo costs no pixel memory. Operations are plain `Codable` values with lengths in full-resolution pixels or as a fraction of the photo's short side, and positions normalised, so one operation renders the same on a screen-sized proxy and on the saved file.

`EditGraph` compiles the list into a Core Image graph, working in extended linear Display P3 half floats; nothing clamps unless the operation's purpose is to clip. `EditRenderer` renders it on Metal:

- The original is decoded once at full resolution. A screen-sized proxy is made from it with Lanczos, and slider renders run on the proxy straight into a texture the canvas shows.
- Each document has a preview lane and a full-resolution lane. A lane runs one render at a time and newer requests replace waiting ones, so a slider never builds a backlog. When the slider settles, or you zoom past the proxy, the full-resolution render replaces the preview.
- After a resize that makes the image smaller, the steps up to it are rendered once and later frames start from that.
- Saving renders at full resolution with the chosen colour profile and encodes with ImageIO. A gain-map JPEG or HEIC saved in place renders in half float with the original's headroom, and ImageIO writes a new SDR base and ISO gain map.

Some operations need more than a filter. **RAW Adjustments** changes the source rather than the graph: the original and proxy are developed again by the RAW engine with the step's settings. **Auto Enhance** stores the filter values it measured once, so a render never analyses again. **Remove Background** finds the subject once with Vision and stores the mask, as a small PNG, inside the operation, so undo, Save and a reload render the same cut without Vision. A **Watermark** keeps a read-only bookmark to its picture. **Batch presets** are operation lists that travel: steps that can't (a resize in pixels, a Remove Background mask) are left out, and Auto Enhance is measured again on each photo.

What Core Image lacks joins the same graph. The 11 resampling filters and oil painting are Metal compute kernels wrapped in `CIImageProcessorKernel`; bump map, sketch, frame, lens, clone, heal and red-eye are Core Image kernels compiled at runtime, each in a library of its own. Text and shapes stay vectors and are rasterised with Core Graphics and Core Text at the working resolution. Red-eye can find eyes with Vision's face landmarks, on the Mac.

## The catalog and thumbnails

**The catalog** is one SQLite database (the system `libsqlite3`, no wrapper) at `Application Support/minivu/catalog.sqlite` inside the app's container. It stores star ratings, the tag and Custom Order, and since schema version 3 also collections, smart folders (a saved search, as JSON) and a cache of the details the filters read from file headers; schema version 4 cleared that cache once so videos' details are read. Older catalogs are upgraded step by step when opened. A file has a row only while it has a rating or the tag (or stands over a rating the file carries itself, below), so the database grows with what you mark, not what you browse. Each row keeps the path (case-insensitive, in one Unicode normalisation) and the file's volume and file identifier, so a file moved in Finder is found again by identity the next time its folder is listed, and its path healed. Rows missing for a year are forgotten. The browser reads a folder's marks in one query with the listing, off the main thread; writes go through one serial queue, then `Catalog.didChange` names the files (and any moves and removals) and each window redraws only what they affect. A database SQLite reports as damaged is renamed aside, never deleted, and a fresh one starts.

**Collections** hold their members by file identity, like marks, so a member moved or renamed, by minivu or in Finder, stays in the collection; one moved to the Trash leaves it until put back.

**Marks in files.** A file with no catalog row shows the rating and tag it carries itself, read lazily from its XMP or XMP sidecar (`FileMarksCache`). When the catalog has a row, the row wins. The first change to such a file copies its marks into a row first, so pressing 3 on a file another app tagged keeps the tag. With **Write ratings into files (XMP)** on, a catalog mirror writes each changed mark into the file, or its sidecar, through the write queue. Colour labels aren't in the catalog at all: they are the file's Finder colour tag.

**Thumbnails** are made at two fixed sizes, 256 and 512 px, so the size slider reuses what is cached. They go memory cache, then disk cache, then decode:

- In memory (an `NSCache` of about 200 MB), each is redrawn on the worker in the browser display's colour space as 8-bit BGRA, so Core Animation has nothing to convert on the main thread.
- On disk they are JPEG or PNG blobs in one SQLite file, `Caches/minivu/thumbnails.sqlite`, instead of thousands of small files. A row is valid only while the file's modification date and size match. The cache is trimmed to 1 GB at launch, and a damaged file is deleted and rebuilt.
- Requests run last in, first out, so the row you stopped scrolling on decodes first; cancelled requests are dropped unstarted. Workers number the CPU cores minus two, at least two.
- The same database keeps **Find Duplicates'** fingerprints: a SHA-256 of each file's bytes and a Vision feature print made from a 256 px decode, keyed by file identity, size and date. Clear Thumbnail Cache empties them too.

## Finding and lists

The browser can show a list instead of one folder: the flat view, search results, a smart folder, a collection, or Find Duplicates' results. `TreeEnumerator` (MinivuCore/Search) walks a tree breadth first with the browser's own listing call, never follows a symbolic link to a folder, applies the volume rule to every folder, and stops at 12 levels, 20,000 images or 5,000 folders. Partial results are sorted off the main thread and shown every quarter of a second. Find reads headers itself rather than asking Spotlight; the measurements behind that choice are in the feature notes. Entries in a list are known by path, not by name, since two folders can each hold an `IMG_1.jpg`.

**Find Duplicates** groups identical files by size and then by streamed SHA-256, and similar pictures by the distance between Vision feature prints, compared in blocks and joined into groups by single linkage, so the Similarity slider regroups without analysing again.

## Writing files

Every write minivu makes to an image file (Save, Save As, a JPEG comment, a metadata edit, a mark written into a file, a colour label, a lossless rotate, Batch Convert's outputs, contact sheets, captures, montages, desktop copies, multi-page files, strips, slideshow videos and web galleries) goes through one serial queue, `FileWriteQueue`, in the order it was asked for. So ⌘S, another edit and ⌘S again land in that order, and a document is marked saved only by the newest write of its file. Moving a file away (Move to Trash, a rename, a move or its undo) waits for the writes queued for it.

A file is written whole under a hidden temporary name, flushed to disk, and only then swapped into place, so an interrupted save never leaves half a file. Copy, Move and Batch Convert send a file they replace to the Trash. Metadata is written without re-encoding the pixels, by rewriting the file's metadata blocks; camera RAW files, and formats that can't be rewritten that way, get an XMP sidecar instead, and the result is read back to check it. A web gallery is written in a scratch folder on the same volume and moved into place with one rename. Batch renames, from any window or any Shortcuts action, run one at a time. Each edit session records the file's modification date and size at its first decode; Save checks that stamp before asking and again in the queue just before writing, so a version another application saved in the meantime is never replaced. Quitting asks about unsaved edits, then waits for queued writes.

## Concurrency

The app target defaults to the main actor (`defaultIsolation(MainActor.self)` in `Package.swift`); background work is explicitly `nonisolated`. The rules that keep the interface responsive:

- Nothing that can take more than a few milliseconds runs on the main thread: decoding, thumbnailing, database writes and file operations happen off it.
- Blocking work runs on Grand Central Dispatch through `BlockingWork`, not on Swift's cooperative pool, which has one thread per core and expects work to suspend. A few long decodes there would keep a 2 ms folder listing waiting. On macOS 27 it is worse than slow: Vision and the HEIF and AVIF encoders wait on GCD work of their own, and enough of those waits on the pool's threads can deadlock it for ever. Debug builds report a call to one of those helpers made from the pool ("minivu: … blocked a cooperative thread"); release builds compile the check away.
- Types shared across threads (the GPU, caches, the catalog) guard their state with locks.
- Idle means idle: no timers, no polling, no redraws when nothing changed. Folders are watched with FSEvents.

## Localisation

Every user-facing string is in a String Catalog, one per module (`Localizable.xcstrings`), with English as the source language. Swift Build compiles each catalog into its module's resource bundle; `scripts/make_app.sh` copies the bundles into the app and lists the shipped languages in `Info.plist` (`CFBundleLocalizations`), which is what lets macOS choose one. Code reaches the strings through one small `localized(…)` helper per module. Code never compares a translated title: menus are found by identifier, and lists and sections have stable ids. `scripts/l10n-sync.sh` brings new strings from the code into the catalogs, and `scripts/l10n-merge.py` adds translations; the help pages are translated as Markdown files per language. Every translation is entered as needing review. The rules are in [docs/feature-notes/l10n.md](https://github.com/Harmanjit/minivu/blob/main/docs/feature-notes/l10n.md); for users, see [Languages](Languages).

## Shortcuts actions

The six Shortcuts actions are App Intents in `Sources/Minivu/Automation`. Shortcuts learns what an app offers from `Contents/Resources/Metadata.appintents`, without launching it. Xcode normally makes that file; here `scripts/make_app.sh` runs Xcode's `appintentsmetadataprocessor` over the records the compiler writes about App Intents types, and stops if the records or the actions are missing. The actions are thin: they check the files they are given (internal volumes only) and call the same code as the menus (Batch Convert's converter, Batch Rename's planner, the catalog). They run inside minivu's process, with its sandbox. Convert and Resize write into a folder in minivu's container and hand the files back to the shortcut.

## Measuring

Every user-facing operation is marked with signposts, intervals named by phase, in the subsystem `com.minivu.app`, category `perf`, so Instruments can show them on a timeline. `MINIVU_TRACE=1` prints launch milestones to standard error, counted from the moment the process started. Benchmark suites, skipped in a normal test run, print one `BENCH` line per measurement; `scripts/bench.sh` builds a release build and runs them one at a time. The November 2026 study made with them, and the plan that follows from it, is [PERFORMANCE.md](https://github.com/Harmanjit/minivu/blob/main/docs/PERFORMANCE.md).

## Tests

Over 1,500 tests, all written with Swift Testing, in three targets:

- `MinivuCoreTests`: decoding sizes, metadata, folder listing, file operations, the catalog, the thumbnail store, encoding, lossless rotation, rename patterns, layouts. Fast.
- `MinivuRenderTests`: textures, the canvas pipeline, HDR, RAW rendering, the edit graph and every effect, the texture cache and loader, the slideshow renderer. These run on the Mac's real GPU.
- `MinivuTests`: the app itself: menus (no shortcut used twice, every action declared), windows, Save and the Trash, tools, displays, the Shortcuts actions, and Help, including that the Keyboard Shortcuts page lists every menu shortcut and that its direct keys match the grid's, viewer's and compare window's key tables. `LocalizationTests` checks that every language is complete, keeps every placeholder and plural form, and really shows its own text, and that every translated help page renders.

Run them with:

```bash
swift test                          # everything
swift test --filter CatalogTests    # one suite
```

Test runs use a private catalog in memory and a private thumbnail store, so they never read or change your ratings or cache, and a screen capturer that never records or asks for permission. Suites that call Vision or encode HEIC or AVIF carry the `.offCooperativePool` trait, which runs them on GCD threads. If a test run's shared thread pool is starved anyway, the `MinivuTestWatchdog` target ends the run with a message rather than letting it hang: after 120 seconds in a debug build and 30 in a release build. `MINIVU_TEST_WATCHDOG=<seconds>` changes the limit, and `0` turns it off. Two-display behaviour is tested through simulated displays. Benchmarks are skipped unless asked for: `MINIVU_BENCH_DIR` points them at a folder of your own photos, and `MINIVU_BENCH=1` runs the slideshow benchmark.

```bash
MINIVU_BENCH_DIR=~/Pictures/some-folder swift test -c release --filter DecodeBenchmark
```

The tests can't reach some things, such as the Shortcuts app, the sandboxed app on real volumes, and how translations fit on screen. They are checked by hand before a release, from these lists:

- [w2-integration.md](https://github.com/Harmanjit/minivu/blob/main/docs/feature-notes/w2-integration.md), "Manual checks for Harman".
- [sys.md](https://github.com/Harmanjit/minivu/blob/main/docs/feature-notes/sys.md), "Checks by hand": Shortcuts, volumes, the Rename refusal and the Quick Action.
- [batch.md](https://github.com/Harmanjit/minivu/blob/main/docs/feature-notes/batch.md), the Set Colour Label checks.
- [l10n.md](https://github.com/Harmanjit/minivu/blob/main/docs/feature-notes/l10n.md), "Checking by hand": truncation, plurals and CJK text.

## The snapshot harness

Debug builds can picture their own windows and quit, without screen recording permission, by asking views to render into a bitmap (Metal views composite their own content on top). A release build neither reads these variables nor carries the code that sends actions. The doc comment in [SnapshotHarness.swift](https://github.com/Harmanjit/minivu/blob/main/Sources/Minivu/App/SnapshotHarness.swift) is the reference.

| Variable | Effect |
|---|---|
| `MINIVU_SNAPSHOT=/tmp/shot.png` | Turns the harness on; the PNG to write |
| `MINIVU_OPEN=~/Pictures/Trip` | Opened as if from Finder |
| `MINIVU_VIEWER=…/a.jpg` | Opens the viewer on this file, without the browser |
| `MINIVU_COMPARE=…/a.jpg,b.NEF` | Opens the compare window on these files |
| `MINIVU_WINDOW_SIZE=1400x900` | Content size in points |
| `MINIVU_ACTIONS="openInViewer:;zoomIn:"` | Actions sent down the responder chain, 0.4 s apart |
| `MINIVU_SNAPSHOT_DELAY=2` | Seconds to wait before capturing (default 1.5) |
| `MINIVU_SNAPSHOT_WINDOW=settings` | Captures the Settings window instead |

A run gives up after 30 seconds. Snapshot runs use the in-memory catalog; `MINIVU_CATALOG=memory` does the same for any run. Some debug actions take further `MINIVU_DEBUG_…` switches, documented where the action is defined. `MINIVU_TRACE`, in any build, prints how long Metal took to get ready and the launch milestones (see **Measuring**).

```bash
swift build
MINIVU_SNAPSHOT=/tmp/shot.png MINIVU_OPEN=/tmp/photos \
  MINIVU_ACTIONS="showKeyboardShortcuts:" .build/debug/minivu
```

## Numbers

Measured on an M1 Pro MacBook Pro, before the November 2026 study; that study, on an M4, has many more numbers and a few that differ, such as a peak of about 281 MB for scrolling 5000 thumbnails. See [PERFORMANCE.md](https://github.com/Harmanjit/minivu/blob/main/docs/PERFORMANCE.md).

| | |
|---|---|
| Warm launch to browser window | ~131 ms |
| Next or previous image | 9–17 ms |
| Scrolling 5000 thumbnails | smooth, peak memory ~186 MB |
| 24 MP JPEG decoded for the screen | ~43 ms and 32 MB |
| Opening the viewer | blocks the main thread ~25–45 ms |

The JPEG number is small because the decode happens at the size the image is shown (step 2 above), not at 24 MP.
