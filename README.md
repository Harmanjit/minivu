<p align="center"><img src="Assets/minivu-icon.png" width="160" alt="minivu icon"></p>

<p align="center"><a href="https://github.com/Harmanjit/minivu/actions/workflows/ci.yml"><img src="https://github.com/Harmanjit/minivu/actions/workflows/ci.yml/badge.svg" alt="CI build and test status"></a></p>

# minivu

A lightweight image browser, viewer and editor for Apple Silicon Macs, in
the spirit of FastStone Image Viewer, built natively with Swift, AppKit and
Metal. It opens a folder of thousands of photos without a stutter, shows
every image with correct colour and real HDR, and edits without touching
the original until you save.

## Features

- **Browser:** folder sidebar with favourites, a thumbnail grid that stays
  smooth with thousands of files, and a preview pane with file details and
  EXIF. Sort by name, dates, size, type, rating or your own custom order;
  filter by stars, tag, Finder tag, name, photos or videos, and More
  Filters (type, date taken, camera, lens, ISO, aperture, focal length,
  keywords, label, location, orientation, size). A flat view shows a folder
  and all its subfolders as one list.
- **Organising:** Find across folders (⌘F), smart folders that run a saved
  search again, and collections of images from any folders. Find
  Duplicates finds identical files and similar images and suggests which
  to keep.
- **Culling:** 0–5 star ratings, a "tagged" mark and Finder colour labels,
  from the keyboard or the grid, kept in a local catalog that follows files
  renamed or moved. Optionally written into the files as XMP; ratings
  other apps wrote into files show too.
- **Metadata:** edit the title, caption, creator, copyright, keywords and
  date taken of one image or many, and remove the location, written into
  the file without re-encoding or into an XMP sidecar.
- **File management:** drag and drop, copy and paste, Copy To and Move To
  with recent folders, rename in place, new folders and Move to Trash.
  Edit > Undo covers copies, moves, renames and new folders; Move to Trash
  isn't undoable (take the file back out of the Trash in Finder). A file
  that a copy or move replaces goes to the Trash. Share with AirDrop, Messages,
  Mail and the rest of the system share sheet.
- **Viewer:** windowed or instant full screen, zoom and pan at any size on
  the GPU, a magnifier, fly-out panels (filmstrip, tools, info and
  histogram, controls), PDF and multi-page TIFF pages, animated GIF, PNG,
  WebP and HEICS, and a compare window for up to four images. The
  full-screen viewer can open on another display. Live Text selects and
  copies text in the picture.
- **Videos:** shown among the photos with their length, played in the
  viewer (Space, P, M to mute), with Copy Frame and Save Frame As. minivu
  doesn't edit or convert videos.
- **Colour and HDR:** colour managed throughout; HDR photos, gain maps and
  RAW extended dynamic range shown in HDR on XDR and HDR displays, tone
  mapped on others.
- **Formats:** what macOS decodes: JPEG, PNG, GIF, HEIC/HEIF, AVIF, WebP,
  JPEG XL, JPEG 2000, TIFF, BMP, TGA, ICO, PSD, Apple's camera RAW list, PDF
  and SVG.
- **Editing:** non-destructive, with 50 steps of undo: resize with 11
  resampling filters, canvas size, crop, straighten, perspective, rotate
  and flip, RAW adjustments, lighting, colours, curves, levels, auto
  enhance, sharpen, blur and noise reduction. Lossless JPEG rotation and
  comments in the browser. Save in place, or Save As (JPEG, PNG, HEIC,
  AVIF, TIFF and more) with format options, Remove location, a live size
  estimate and a quality comparison. Save a photo's edits as a preset for
  Batch Convert.
- **Effects and retouching:** grayscale, sepia, negative, drop shadow,
  frames, bump map, sketch, oil painting, lens, vignette, editable text and
  shapes, watermark, clone stamp, healing brush, red-eye removal, and
  remove background (or copy the subject).
- **Tools:** slideshow with eight GPU transitions and music, and export of
  a slideshow to H.264 or HEVC video; batch convert with presets, edits, a
  watermark and HDR gain maps; batch rename with a live preview; extract
  pages, multi-page files (TIFF, PDF, animated GIF and HEIC) and image
  strips; printing with layouts, contact sheets, HTML web galleries,
  montage wallpaper, set as desktop picture, screen capture and external
  editors.
- **Shortcuts:** Convert Images, Resize Images, Rename Images, Set Rating,
  Set Colour Label and Open in minivu actions for the Shortcuts app.
- **Languages:** English, German, French, Spanish, Italian, Portuguese
  (Brazil), Dutch, Polish, Japanese, Chinese (Simplified), Korean, Hindi,
  Punjabi, Bengali, Gujarati and Tamil. The translations are machine
  translations awaiting review by native speakers.
- **Help:** Help > minivu Help is bundled in the app, translated, with
  search and a Keyboard Shortcuts page generated from the menus.

## Status

Version 0.9 is a review release: every planned feature is in, and people
are trying it before 1.0. Download the app from
[Releases](https://github.com/Harmanjit/minivu/releases), or build it
yourself (below). If something goes wrong, please
[report it](#reporting-problems).

## Documentation

The [wiki](https://github.com/Harmanjit/minivu/wiki) is the full reference:
installing, every window and tool, settings, shortcuts, architecture,
limitations and troubleshooting. Its source is in `docs/wiki`. The app also
carries a shorter version in **Help > minivu Help** (⌘?).

## Requirements

- A Mac with Apple Silicon (M1 or later).
- macOS 15 Sequoia or later.
- To build: full Xcode (not only the Command Line Tools) with Swift 6.2 or
  later. `make_app.sh` also uses Xcode's App Intents metadata tool, so the
  Shortcuts actions appear in the Shortcuts app.

## Building

Point the command line tools at Xcode once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then:

```bash
swift build            # debug build: .build/debug/minivu
swift test             # unit, window and GPU tests
scripts/make_app.sh    # build/minivu.app: release, sandboxed, ad-hoc signed
open build/minivu.app
```

`scripts/make_app.sh` builds the release binary and assembles the app
bundle with its three resource bundles (the Metal shaders, the help
pages with the app's translations, and the core library's translations) and the Shortcuts actions' metadata. It precompiles the shaders when the Metal toolchain is installed,
and signs the app ad hoc with the hardened runtime and the entitlements in
`scripts/minivu.entitlements`. `scripts/make_app.sh --dev` leaves the
sandbox out, for testing with folders passed on the command line.

Every push to `main` and every pull request builds, tests and packages
minivu the same way on a macOS runner (`.github/workflows/ci.yml`), and
keeps the app bundle it made with the run.

**First launch on another Mac.** The app is signed ad hoc rather than with
a Developer ID, and isn't notarised, so Gatekeeper stops it the first time
it is opened from a download or a copy. Try to open it once, then open
**System Settings > Privacy & Security** and click **Open Anyway** next to
the message about minivu. (Since macOS 15, Control-click > Open no longer
skips this step.) The Mac that built the app opens it straight away.

### Snapshots and benchmarks

The debug build can picture its own windows without screen recording
permission; the doc comment in `Sources/Minivu/App/SnapshotHarness.swift`
lists the switches:

```bash
MINIVU_CATALOG=memory MINIVU_SNAPSHOT=/tmp/shot.png MINIVU_OPEN=/tmp/photos \
  MINIVU_ACTIONS="showKeyboardShortcuts:" .build/debug/minivu
```

Decode benchmark on a folder of your own:

```bash
MINIVU_BENCH_DIR=~/Pictures/some-folder swift test -c release --filter DecodeBenchmark
```

The whole benchmark kit runs in a release build, one suite at a time, and
collects the results in one file. The folder in `MINIVU_BENCH_DIR` is only
ever read. The comment at the top of `scripts/bench.sh` lists its options.

```bash
scripts/bench.sh results.txt                    # every benchmark
scripts/bench.sh results.txt CompareBenchmark   # one of them
```

`MINIVU_TRACE=1` prints the launch milestones to the terminal, and every
phase is a signpost (subsystem `com.minivu.app`, category `perf`) for
Instruments. `docs/PERFORMANCE.md` says what takes how long and the plan
to make minivu faster.

### Translations

The text is in String Catalogs (`Localizable.xcstrings`, one per target)
and the translated help pages are in `Sources/Minivu/Help/HelpPages/<language>/`.
After changing user-facing text, run `scripts/l10n-sync.sh`.
`docs/feature-notes/l10n.md` explains the conventions, and `docs/l10n`
holds each language's glossary for reviewers.

## Reporting problems

Open an [issue](https://github.com/Harmanjit/minivu/issues/new/choose) and
choose **Bug report**. The most useful details are what you did, what you
expected, the Mac and macOS version, the version from **minivu > About
minivu**, and the kind of file involved (format and, for RAW, the camera).
Please attach the file if you can share it; minivu itself never sends
anything anywhere.

## Privacy

minivu has no network access of any kind. It runs in the App Sandbox
without the network client or server entitlements, so it cannot open a
connection: no accounts, analytics, crash reports or update checks, and the
help is bundled. Live Text, subject lifting, face and rectangle detection
and similar-image search run on the Mac with Apple's Vision framework.
Sharing hands files to the system's share services. The sandbox limits it
to the Pictures folder, the files and folders you choose (remembered with
app-scoped bookmarks) and its own container, where it keeps its catalog,
thumbnail cache and settings. It changes your files only when you ask,
and writes each file in full before putting it in place. Copy, Move and
Batch Convert send a file they replace to the Trash; File > Save writes
over the original after asking, and that can't be undone. Save As, Batch
Convert and web galleries leave out the location by default. Help > minivu Help > Privacy has the details.

## License

GPLv3; see `LICENSE`.

No third-party code: below the app there are only Apple's frameworks
(AppKit, SwiftUI, Metal, Core Image, ImageIO, PDFKit, AVFoundation, AVKit,
ScreenCaptureKit, Vision, VisionKit, App Intents and the system SQLite), so
there is nothing to vendor, update or reconcile with the GPL.

## Project layout

```
Package.swift            SwiftPM package (no Xcode project)
Sources/
  MinivuCore/            decoding, metadata, folders, file operations,
                         catalog, thumbnail cache, export, batch rename,
                         search, duplicates, multi-page files, web
                         gallery, videos, page and montage layout (no GPU,
                         no windows)
  MinivuRender/          Metal: textures, canvas renderer, edit graph and
                         kernels, histogram, slideshow and its video
                         export (Shaders/)
  Minivu/                the AppKit application
    App/                 app delegate, menu bar, Settings, snapshot harness
    Browser/             browser window: sidebar, grid, preview, files
    Viewer/              viewer window, fly-out panels, edit tools (Edit/)
    Canvas/, Compare/    the image canvas view; the compare window
    Save/                Save, Save As and the write queue
    Tools/               slideshow, batch, multi-page, duplicates, print,
                         contact sheet, web gallery, montage, desktop
                         picture, capture, share, external editors
    Automation/          the Shortcuts actions (App Intents)
    Help/                the Help window; its pages in HelpPages/*.md,
                         translations in HelpPages/<language>/
    Common/              preferences, bookmarks, theme, shared views
Tests/
  MinivuCoreTests/       fast logic tests
  MinivuRenderTests/     GPU tests, on the real device
  MinivuTests/           the app: menus, windows, tools, help
  MinivuTestWatchdog/    ends a stalled test run rather than hanging
scripts/                 make_app.sh, make_icon.swift, bench.sh, the
                         l10n scripts and the sandbox entitlements
Assets/                  the app icon: AppIcon.pdf (the original) and the
                         .icns and PNGs make_icon.swift draws from it
docs/wiki/               the source of the GitHub wiki
docs/feature-notes/      design notes for each feature, and the limits
docs/l10n/               a glossary for each language
docs/PERFORMANCE.md      what takes how long, and the speed-up plan
DESIGN.md                the spec: goals, architecture, UI, efficiency
                         rules, roadmap
```
