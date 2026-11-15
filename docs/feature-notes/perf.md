# Feature notes: the performance measurement kit (branch feature/perf)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section says where it should.

The kit answers one question with numbers: which user-facing operations
take how long, and where the time goes. It has three parts: signposts in
the app (for Instruments, and read back in memory by the benchmarks),
benchmark suites that print one machine-readable line per metric, and
`scripts/bench.sh`, which runs them all in a release build. Nothing in
this note is a measurement: the kit was only run small, in a debug build,
to show that every benchmark works. The real run is a later step, on a
quiet Mac.

## What a user (or a developer) can do

Nothing changes for someone using minivu: no menu, setting or shortcut.
The kit is for whoever measures:

- **Time a launch without Instruments.** Start the app from a terminal
  with `MINIVU_TRACE=1` set (as for the existing "Metal ready in …"
  line). Each launch milestone is printed to stderr with the time since
  the kernel started the process, so dyld and everything before `main`
  count too:

      launch: launch.didFinishLaunching at 92.4 ms
      launch: launch.catalogOpen at 95.0 ms
      launch: launch.thumbnailStoreOpen at 97.1 ms
      launch: launch.bookmarks at 97.9 ms
      launch: launch.browserWindowShown at 121.3 ms
      launch: launch.gpuReady at 140.2 ms
      launch: launch.firstFolderListed at 131.8 ms
      launch: launch.firstScreenful at 260.5 ms

  (Example of the format; not measured.) The order of the GPU line and
  the folder lines varies: the GPU warms up on a thread of its own.

- **See the phases in Instruments.** Record with the os_signpost (or
  Points of Interest / Logging) instrument and filter on subsystem
  `com.minivu.app`, category `perf`. Every phase below is an interval on
  the thread that ran it; launch milestones and counts are events.

- **Run the benchmarks.** `scripts/bench.sh results.txt` builds release
  with tests and runs every suite, one at a time, each in a process of its
  own, and writes every `BENCH` line to `results.txt` (the whole test
  output goes to `results.txt.log`). `scripts/bench.sh results.txt
  ViewerBenchmark` runs one entry only. See "Running" below.

## Signposts

`Perf` (Sources/MinivuCore/Perf.swift) wraps one `OSSignposter`
(subsystem `com.minivu.app`, category `perf`):

- `Perf.measure("name") { … }` (sync and async) and `Perf.begin("name")`
  / `.end()` for an interval; `Perf.count("name")` for an event that is
  also counted; `Perf.milestone("name")` for a launch milestone (event,
  plus the stderr line with `MINIVU_TRACE`).
- **Cost.** A signposter nobody records costs a flag check per call, so
  the intervals stay in release builds. On top of that, each call checks
  one atomic flag (relaxed load) for the in-memory recording below.
  Intervals are around phases (one per file at most), never per pixel or
  per row.
- **In-memory recording, for benchmarks.** Between `Perf.startRecording()`
  and `Perf.stopRecording()` every interval's duration and every count is
  kept, by name; the result's `total(name)` adds them up. The app never
  records. A recording is process-wide: two suites recording at once in one
  process mix their numbers, which is why the runner gives each suite its
  own process.

Names are `operation.phase`, one name per phase (never per file):

| Area | Intervals (I), events (E), counts (C) | What it covers |
|---|---|---|
| Launch | `launch.didFinishLaunching` E, `launch.catalogOpen` I+E, `launch.thumbnailStoreOpen` I+E, `launch.bookmarks` I+E, `launch.gpuWarmUp` I, `launch.gpuReady` E, `launch.browserWindowShown` E, `launch.firstFolderListed` E, `launch.firstScreenful` E | The catalog, thumbnail store and bookmarks are now opened one after the other in `applicationDidFinishLaunching` (before, on first use inside `AppServices.start`), so each is a phase of its own. First folder listed: the first successful `BrowserModel.finish`. First screenful: the first time every visible grid cell has its thumbnail. |
| Catalog | `catalog.open` I, `catalog.marks` I, `catalog.heal` I, `catalog.didChange` C, `sqlite.transaction` C | `marks(for:)` (the folder's one query), `heal(folder:)`, every `didChange` posted, every outermost SQLite transaction (catalog and thumbnail store). |
| Folder open | `folder.open` I (task start to finish), `folder.list`, `folder.marks`, `folder.fileMarks` (the lstat pass for files without a row), `folder.sort`, `folder.finish` (main thread; includes the grid's `reloadData` through `onChange`), `folder.applyFilter` (main, every call), `folder.resort`, `folder.fileMarksChunk`, `folder.metadataChunk` | `BrowserModel.load` and what follows it. |
| Flat view | `flat.open`, `flat.partialSort` (background, every 250 ms), `flat.showPartial` (main) | `BrowserModel.loadMany`. |
| Browser | `browser.catalogChanged` I (main), `grid.fillScreen` I (from a listing's entries arriving to every visible cell settled) | The cell's new `isThumbnailSettled` is true once its thumbnail arrived, failed, or it shows a folder. |
| Thumbnails | `thumb.produce`, `thumb.storeRead`, `thumb.decode`, `thumb.displayReady` (the redraw into the display's colour space), `thumb.encode`, `thumb.storeWrite` (waiting for the disk lock included) | `ThumbnailService.produce` on the workers. |
| Decode | `decode` (a whole `ImageDecoder.decode`), `decode.info` (header, HDR check included), `decode.hdrCheck` (`hasHDRContent`: gain map look-ups and the lazy image), `decode.pixels`, `decode.rawPreview`, `raw.render`, `file.open` C (every `CGImageSource` made by `ImageDecoder`, `MetadataReader`, `MarksXMP`, `PixelSizeCache`, `SavePolicy`) | `file.open` is what "how many times is the file opened per flip" counts. |
| Viewer | `loader.screen` / `loader.fullResolution` (an `ImageLoader` job, decode and upload), `upload` (`TextureUploader.upload`), `upload.draw` (the CPU colour conversion; a lazily decoded image decodes here), `upload.gpu` (commit and wait for the blit and mipmaps), `viewer.flip` (main: from `loadCurrentPage` to the texture on the canvas; a flip overtaken by the next ends early), `viewer.structureRead`, `viewer.exposureRead`, `viewer.fileMarksRead`, `info.read` | The side reads are the header reads each flip makes besides the decode. |
| Edit | `edit.prepare` (`.load`, `.proxy`), `edit.render.preview`, `edit.render.full`, `edit.render.rawDevelop`, `edit.render.texture`, `edit.export` (`.source`, `.render`), `edit.exportHDR` | `EditRenderer`. |
| Save | `save.preflight` (Save's header reads), `save.encode` (`ImageEncoder.write` for Save and Save As), `encode.prepare` (the pixel conversion before encoding), `encode.finalize` (`CGImageDestinationFinalize`), `write.fsync`, `write.queued` (waiting in `FileWriteQueue`), `write.job`, `trash.move`, `trash.catalog` | |
| Files | `transfer.preflight`, `transfer.items` (the whole loop), `transfer.item` (one item), `transfer.copyFile`, `transfer.moveFile`, `transfer.catalog`, `rename.perform`, `rename.invalidate` (main) | `FileTransfer.run`, `FileOperations.transfer`, Batch Rename. |
| Batch Convert | `batch.file` (one file, waits included), `batch.prepare`, `batch.render`, `batch.encode`, `batch.commit` | `BatchConvertJob`, `BatchConverter`. |

## Benchmarks

### Gating and format

As for the older benchmarks:

- `MINIVU_BENCH=1` runs the synthetic ones, which make their own files in
  a scratch folder under the test's temporary directory (the existing
  `TemporaryFolder`, `ScratchFolder` and `Fixtures.directory`).
- `MINIVU_BENCH_DIR` names a folder of real photos and also turns the
  synthetic ones on. **It is only ever read.** Anything that writes (Save,
  Batch Convert, copies) works on APFS clones made in the scratch folder
  (`Bench.clones`, `FileManager.copyItem`: no data copied, the original
  untouched). The photos used are `HSB_6548.jpg` (24 MP), `HSB_6548.heic`
  and `HSB_6548.NEF` when present, else the first file of each type. The
  PNG, the HDR gain-map JPEG and the video are made from them or from
  nothing, in the scratch folder.
- `MINIVU_BENCH_QUICK=1` makes every benchmark small and runs it twice:
  for checking the kit (a debug build, a busy Mac). Its numbers mean
  nothing.

Each metric is one line on stdout:

    BENCH <suite>.<metric> median_ms=<x> p90_ms=<y> runs=<n> [key=value ...]

Every benchmark warms up once (unless a warm-up would make the next run
warm when it must be cold; those say `warmups: 0`) and then repeats at
least five times. The extra keys are per run unless named otherwise:
counts, sizes, MB, and phase times taken from the signposts recorded
during the runs (averaged over the warm-up too, so they are a close guide,
not exact). `main_blocked_ms`, `main_longest_ms` and `main_stalls` come
from `Bench.MainThreadMonitor` (below).

The helper `Bench` is in each test target as BenchSupport.swift (a test
target can't share files); the three copies are alike, MinivuTests' adding
the main-thread monitor.

### Main-thread time and memory

- **Main-thread busy time** (`Bench.MainThreadMonitor`): a thread of its
  own asks the main queue to run an empty block, waits for it, sleeps a
  millisecond, and repeats. A block that waited `L` ms means the main
  thread was busy for about that long; waits of 2 ms or more are added
  up, during the timed runs only (setup between runs is left out).
  Resolution about a millisecond; a busy spell under 2 ms is not counted.
  It is the right measure of "what did the user feel": it counts AppKit's
  layout and Core Animation commits that no signpost covers. The
  signposts (`folder.finish`, `viewer.flip`, `browser.catalogChanged`)
  give the exact time of the parts they wrap.
- **Footprint** (`Bench.footprint`, `Bench.FootprintPeak`): the process's
  `phys_footprint` from `task_info(TASK_VM_INFO)`, what Activity Monitor
  calls Memory, sampled every 5 ms on a thread of its own for the peak.
  Reported as `start_mb`, `peak_mb`, `end_mb`. The runner gives each suite
  its own process; within a suite, earlier benchmarks' memory is still
  held, so compare a memory line with its own `start_mb`.

### The suites

MinivuCoreTests (CoreBenchmarks.swift, and additions to the older
SearchBenchmark and DuplicateBenchmark):

| Metric | What it measures |
|---|---|
| `catalog.marks{5000,20000}` | `Catalog.marks(for:)` of a folder's files, a quarter of them rated, catalog on disk. |
| `catalog.healFirst{N}`, `catalog.heal{N}` | `heal(folder:)` on a new catalog connection (the first heal of a launch also scans the Trash's rows), then again. |
| `thumbs.{jpeg,png,heic,nef,video}Cold` | A screenful (60 cells) of thumbnails through a real `ThumbnailService` (its default workers, `max(2, cores − 2)`, shown as `workers=`) into an empty store on disk. 60 clones of one photo: the file system cache is warm after the first, so this is the decode, not the disk. |
| `thumbs.{format}ColdDecodeEach` | Each thumbnail's `thumb.decode` during the last cold run; `write_ms_each` is its store write. |
| `thumbs.{format}Warm` | The same screenful from the filled store (a new service: empty memory cache). |
| `thumbs.storeWriteEach`, `thumbs.storeReadEach` | One thumbnail row written (autocommit INSERT) and read back, store on disk, a real photo's thumbnail. |
| `info.sectionsAndFields`, `info.summary`, `info.imageInfo`, `info.imageInfoHEIC` | The info panel's read, the viewer's exposure line, and the header read (HDR check included) that decode, Save and Batch Convert start with. |
| `colors.decode`, `colors.count` | Count Colors as the histogram panel runs it: header and full SDR decode, then the count (`peak_mb`, `colors`, `pixels`). |
| `find.walk{N}`, `find.byName{N}` | The tree walk of 200 folders of 100 empty files, and Find by name over it. |
| `find.metadataCold`, `find.metadataCached` | Find with a metadata condition (at least 4000 px wide) over ten folders of the test photos' clones: a new catalog each run, then the catalog that cached the headers. "Cold" is the catalog's cache; the file system cache is warm. |
| `duplicates.exactCold`/`Cached`, `similarCold`/`Cached`, `pixelSizes` | Find Duplicates on 200 generated 3000 × 2000 JPEGs (a quarter exact copies, a quarter lightly changed): hashing, then feature prints and the index, from an empty store and from a filled one. |

MinivuRenderTests (RenderBenchmarks.swift):

| Metric | What it measures |
|---|---|
| `edit.prepare_{jpeg,heic,nef}` | `EditRenderer.prepare` with a 3456 px proxy, a new document each run (`load_ms`, `proxy_ms`). |
| `edit.slider_lighting`, `edit.slider_rawExposure` | A slider frame: a new preview value, from the request to the frame delivered, at 3456 px. The RAW one develops the NEF in the RAW engine every frame. |
| `edit.fullRender_{lighting,rawExposure}` | The full-resolution render a zoom to 100% asks for while editing. |
| `slideshowVideo.export10` | Ten 24 MP slides to a 1080p, 30 fps H.264 movie, three seconds each, one-second dissolves, captions on (`peak_mb`). |

MinivuTests (FolderBenchmarks.swift, ViewerBenchmarks.swift,
OutputBenchmarks.swift); the window suites run with `AppWindowTests`:

| Metric | What it measures |
|---|---|
| `folder{1000,10000,20000}.list`, `.heal`, `.marks`, `.fileMarksCold`, `.fileMarksWarm`, `.sort_{name,modified,rating}` | Each step of a folder listing on its own, one-byte files, a quarter rated. `fileMarksCold` is the lstat pass with a `FileMarksCache` that has read nothing (every launch: the cache is memory-only); warm, after every file's marks were read. |
| `folder{N}.openColdLaunch` | The browser model end to end, as at launch: a new catalog connection (first heal) and an empty file-marks cache. |
| `folder{N}.reload` | Reloading the shown folder through the model; `finish_ms` and `applyFilter_ms` from the signposts, main-thread busy time. |
| `folder{N}.openInWindow` | Opening the folder in a real browser window, an empty folder in between: `finish_ms_median` is the main thread's `finish` with the grid's reload; the busy time adds the grid's layout and commit. |
| `flat20000.open` | The flat view of a 20,000-file tree: total, partial lists per open and their main-thread and sort time, and the final `finish`. |
| `pixelSizes.read500` | The grid's dimensions line: 500 header reads through a new `PixelSizeCache` (one serial queue). |
| `files.{copy,move}{100,1000}` | `FileTransfer.run` between two folders (moving within one folder is a no-op in minivu): per item, catalog time per file, transactions and notifications per file, main-thread time. |
| `files.move1000Shown` | The same into the folder a browser window shows: `browser.catalogChanged` calls and main time. |
| `files.rename1000` | Batch Rename of 1,000 through the window, to the grid showing the new names (`perform_ms`, `invalidate_main_ms`). |
| `files.trash100Of1000` | Move to Trash of 100 selected out of 1,000 through the window. The write queue's `putInTrash` test seam moves them into a folder in the scratch folder: nothing reaches the user's Trash. |
| `viewer.open_{jpeg,heic,nefPreview,nefRaw,hdrGainMap}` | Opening the viewer on a photo never decoded (a clone each run), from the call to the texture on the canvas; `show_call_ms` is the synchronous part, `opens` header opens per open, main-thread time, texture size, HDR. `nefRaw` sets the RAW setting to Render RAW data. The HDR JPEG is made from the 24 MP photo with a gain map a stop brighter. |
| `viewer.next_warm`, `viewer.next_cold`, `viewer.previous` | → with the neighbour prefetched (after the loader went idle), → with it thrown out of the cache just before, and ←. `flip_signpost_ms` is `viewer.flip`; `opens_per_flip` counts header opens per move, the next neighbour's prefetch and the side reads included; `decode_ms`/`upload_ms` are the loader's per move. |
| `viewer.actualSize_{jpeg,heic,nef}` | Actual Size from fitted: the command to the full-resolution texture on the canvas (`loader_ms`). |
| `memory.viewerFlip20` | Footprint while moving through 20 photos (JPEG and HEIC) as fast as they arrive; each move's time. |
| `memory.gridScroll5000` | A browser window scrolled a screen at a time through 5,000 thumbnails (clones of the 24 MP photo, or flat pictures without the photo folder), each screen waiting for its thumbnails: footprint and time per screen. |
| `save.inPlace_{jpeg,heic}` | Save of an edited photo: Save's header reads, then the write through `FileWriteQueue` (render, pixel conversion, encode, fsync, rename), the document prepared beforehand as the viewer's would be. |
| `save.saveAsAVIF` | Save As AVIF of the unedited 24 MP photo (decode at full size and encode). Skipped where ImageIO has no AVIF encoder. |
| `batch.{jpeg2048,heicFull,avifFull}_20` | Batch Convert of 20 photos with the app's `BatchConvertJob` at its default concurrency (shown), into a new folder each run: per-file phase times and `peak_mb`. |
| `webGallery.export20` | A web gallery of 20 photos at the default sizes. |

### Running

    scripts/bench.sh ~/perf-results.txt

- Builds `swift build -c release --build-tests -Xswiftc -enable-testing`,
  then runs each entry with `swift test -c release -Xswiftc -enable-testing
  --skip-build --filter <entry>`, one after another (never in parallel),
  with `MINIVU_BENCH=1`, `MINIVU_BENCH_DIR=${MINIVU_BENCH_DIR:-~/latent/TestAssets}`
  and `MINIVU_CATALOG=memory`. Release tests work: both commands were
  checked on this branch.
- The results file starts with `#` lines: date, commit, Mac model, chip,
  memory, macOS, build, photo folder; a suite that failed is marked
  `# FAILED`.
- After the study's suites it runs the older print-only benchmarks
  (DecodeBenchmark, EditBenchmark and the rest), whose lines go to the
  log only; `MINIVU_BENCH_OLDER=0` leaves them out.
- `MINIVU_BENCH_DEBUG=1 MINIVU_BENCH_QUICK=1` checks the kit quickly;
  `SKIP_BUILD=1` reuses the build; `BENCH_JOBS=4` limits the build.
- On a shared machine, run it through the throttle like any test run.

Window benchmarks open real windows in the test process (never the app
binary), as AppWindowTests do: the Mac should be left alone while they
run, and the screen awake.

### Caveats

- **Cold and warm.** "Cold" in these benchmarks means minivu's own caches
  are empty (thumbnail store, texture cache, catalog's metadata cache,
  file-marks cache). The operating system's file cache is usually warm:
  clones share their data with the original, and every run reads the same
  photos. A truly cold disk read (after a reboot) is not measured; on an
  internal SSD it adds little to decode-bound work, more to header-bound
  work (Find, folder open of a never-seen folder).
- **First use in a process.** Core Image, Metal pipelines and ImageIO
  codecs set themselves up on first use; the warm-up run absorbs it. The
  real first-use cost after launch is what the launch milestones and a
  `viewer.open_*` in a fresh process show.
- **The thumbnail cache in test runs.** Test runs (and any run with a
  private catalog) now use a thumbnail store of their own in the temporary
  folder (`AppServices.thumbnailStoreURL`), so the grid benchmarks start
  from an empty store and never fill the user's cache.
- **Displays.** Viewer textures are sized to the canvas, which depends on
  the screen the window opens on; the texture size is printed with each
  open. Compare runs on the same display arrangement.
- **Main-thread resolution** is about a millisecond (above).
- **Numbers in quick mode** are meaningless by design.

## Design decisions

- **Signposts in MinivuCore**, so all three modules use one helper without
  a new dependency; `OSSignposter` because it costs nothing unrecorded
  and Instruments shows it per thread.
- **The in-memory recording** lets the benchmarks report the same phases
  Instruments shows, measured by the code itself, instead of each
  benchmark re-implementing the app's steps (which would drift from it).
  It is off unless a benchmark turns it on; its only cost in the app is an
  atomic load per signpost.
- **Benchmarks drive the app's own code** (the browser model and window,
  the viewer window, `FileTransfer`, `BatchConvertJob`, `SavePresenter`,
  `WebGalleryExport`) wherever it can run in the test process, so a
  number is what the user waits for, not a lab copy of it.
- **One process per suite** in the runner: recordings and memory are
  process-wide.
- **Medians and the 90th percentile**, at least five runs: robust to the
  odd slow run without hiding a bimodal one.

## Product changes in this branch (beyond signposts)

- `AppDelegate.applicationDidFinishLaunching` opens the catalog, the
  thumbnail store and the bookmarks in that order explicitly (they were
  opened on first use, in `AppServices.start`); the work is the same.
- `ThumbnailCell.isThumbnailSettled` and `onThumbnailSettled`, and
  `GridViewController.checkScreenFilled`, for `grid.fillScreen`. The check
  runs only while a fill interval is open (after a listing arrives, until
  the screen is full), so scrolling costs nothing.
- `AppServices.thumbnailStoreURL`: a private catalog
  (`Catalog.usesPrivateCatalog`, now public) also means a private
  thumbnail store in the temporary folder.
- No entitlement, network code or dependency was added.

## Tests

- `PerfTests` (MinivuCoreTests): recording keeps intervals and counts only
  while on; the launch time is since the process started; thumbnail
  phases and catalog reads are signposted.
- `PerfSignpostTests` (MinivuTests): test runs keep thumbnails in the
  temporary folder; the grid times filling a screen and the viewer its
  flips (with file opens counted).
- Every benchmark ran once in a debug build with `MINIVU_BENCH_QUICK=1`
  and the test photos.

## Where the docs should change

- **DESIGN.md section 6 (Efficiency rules)** or a new **4.9 Measuring**:
  the signposts (subsystem and category, naming, cost), `MINIVU_TRACE`
  launch milestones, the benchmark gating and `scripts/bench.sh`. Section
  4.5 (Memory) may cite the memory benchmarks once measured.
- **DESIGN.md 4.6 (Catalog)**: nothing changes; the numbers measured
  later may replace the old ones quoted there.
- **README or a developer page of the wiki** ("Building and testing"):
  how to run the benchmarks and the environment variables above,
  including that `MINIVU_BENCH_DIR` is read only.
- **Help pages and the keyboard-shortcuts page**: nothing (no user-facing
  change).
