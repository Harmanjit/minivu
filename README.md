# minivu

A lightweight image browser, viewer and editor for Apple Silicon Macs, in
the spirit of FastStone Image Viewer, built natively with Swift, AppKit
and Metal.

- **Platform:** macOS 15 or newer, any Apple Silicon Mac (M1 onwards).
- **License:** GPLv3, see `LICENSE`. No third-party code: minivu uses only
  Apple's frameworks.
- **Privacy:** no network access. The App Sandbox has no network
  entitlement, so the app cannot open a connection.
- **Status:** in development. See `DESIGN.md` §7 for the roadmap.

## Build

Requires full Xcode (not only the command line tools):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then:

```bash
swift build            # debug build
swift test             # unit and GPU tests
scripts/make_app.sh    # build/minivu.app, sandboxed and ad-hoc signed
open build/minivu.app
```

The app is not notarised. On another Mac, right-click the app and choose
Open the first time.

## Layout

```
Sources/
  MinivuCore/     decoding, metadata, folders, catalog, thumbnail cache
  MinivuRender/   Metal: textures, canvas, kernels, transitions (Shaders/)
  minivu/         the AppKit application
Tests/           Swift Testing suites; GPU tests run on the real device
scripts/         make_app.sh and the sandbox entitlements
```

## Benchmarks

```bash
MINIVU_BENCH_DIR=~/Pictures/some-folder swift test -c release --filter DecodeBenchmark
```
