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
  filter by stars, tag, Finder tag or name.
- **Culling:** 0–5 star ratings and a "tagged" mark, from the keyboard or
  the grid, kept in a local catalog that follows files renamed or moved.
- **File management:** drag and drop, Copy To and Move To with recent
  folders, rename in place, new folders and Move to Trash, all undoable.
  Replaced files go to the Trash.
- **Viewer:** windowed or instant full screen, zoom and pan at any size on
  the GPU, a magnifier, fly-out panels (filmstrip, tools, info and
  histogram, controls), PDF and multi-page TIFF pages, animated GIF, PNG,
  WebP and HEICS, and a compare window for up to four images. The
  full-screen viewer can open on another display.
- **Colour and HDR:** colour managed throughout; HDR photos, gain maps and
  RAW extended dynamic range shown in HDR on XDR and HDR displays, tone
  mapped on others.
- **Formats:** what macOS decodes: JPEG, PNG, GIF, HEIC/HEIF, AVIF, WebP,
  JPEG XL, JPEG 2000, TIFF, BMP, TGA, ICO, PSD, Apple's camera RAW list, PDF
  and SVG.
- **Editing:** non-destructive, with 50 steps of undo: resize with 11
  resampling filters, crop, straighten, rotate and flip, lighting, colours,
  curves, levels, sharpen and blur. Lossless JPEG rotation and comments in
  the browser. Save in place, or Save As with format options, a live size
  estimate and a quality comparison.
- **Effects and retouching:** grayscale, sepia, negative, drop shadow,
  frames, bump map, sketch, oil painting, lens, editable text and shapes,
  clone stamp, healing brush and red-eye removal.
- **Tools:** slideshow with eight GPU transitions and music, batch convert,
  batch rename with a live preview, printing with layouts, contact sheets,
  montage wallpaper, set as desktop picture, screen capture and external
  editors.
- **Help:** Help > minivu Help is bundled in the app, with search and a
  Keyboard Shortcuts page generated from the menus.

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
- To build: full Xcode (not only the Command Line Tools) with Swift 6.2.

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
bundle with its two resource bundles (the Metal shaders and the help
pages). It precompiles the shaders when the Metal toolchain is installed,
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
help is bundled. The sandbox limits it to the Pictures folder, the files and
folders you choose (remembered with app-scoped bookmarks) and its own
container, where it keeps its catalog, thumbnail cache and settings. It
changes your files only when you ask, writes each file in full before
putting it in place, and sends anything it replaces to the Trash. Help >
minivu Help > Privacy has the details.

## License

GPLv3; see `LICENSE`.

No third-party code: below the app there are only Apple's frameworks
(AppKit, SwiftUI, Metal, Core Image, ImageIO, PDFKit, AVFoundation,
ScreenCaptureKit, Vision and the system SQLite), so there is nothing to
vendor, update or reconcile with the GPL.

## Project layout

```
Package.swift            SwiftPM package (no Xcode project)
Sources/
  MinivuCore/            decoding, metadata, folders, file operations,
                         catalog, thumbnail cache, export, batch rename,
                         page and montage layout (no GPU, no windows)
  MinivuRender/          Metal: textures, canvas renderer, edit graph and
                         kernels, histogram, slideshow (Shaders/)
  Minivu/                the AppKit application
    App/                 app delegate, menu bar, Settings, snapshot harness
    Browser/             browser window: sidebar, grid, preview, files
    Viewer/              viewer window, fly-out panels, edit tools (Edit/)
    Canvas/, Compare/    the image canvas view; the compare window
    Save/                Save, Save As and the write queue
    Tools/               slideshow, batch, print, contact sheet, montage,
                         desktop picture, capture, external editors
    Help/                the Help window; its pages in HelpPages/*.md
    Common/              preferences, bookmarks, theme, shared views
Tests/
  MinivuCoreTests/       fast logic tests
  MinivuRenderTests/     GPU tests, on the real device
  MinivuTests/           the app: menus, windows, tools, help
scripts/                 make_app.sh, make_icon.swift and the sandbox
                         entitlements
Assets/                  the app icon: AppIcon.pdf (the original) and the
                         .icns and PNGs make_icon.swift draws from it
docs/wiki/               the source of the GitHub wiki
DESIGN.md                the spec: goals, architecture, UI, efficiency
                         rules, roadmap
```
