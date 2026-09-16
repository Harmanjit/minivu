# Installation

## Requirements

- A Mac with Apple Silicon (M1 or later). Developed and tested on an M1 Pro MacBook Pro.
- macOS 15 (Sequoia) or newer.
- To build: **full Xcode** from the App Store, not just the Command Line Tools, with Swift 6.2 or newer (Xcode 26 or later). The package has no Xcode project; it builds with SwiftPM from the command line, and Xcode must be the active developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Run that once after installing Xcode.

- Optionally, Xcode's Metal toolchain, so the build can precompile the shaders. Xcode 26 ships it as a separate download (`xcodebuild -downloadComponent MetalToolchain`). Without it the app compiles its bundled shader sources when it launches, on a background thread, which takes a fraction of a second; the window doesn't wait for it.

Nothing else is needed. minivu has no third-party dependencies, so there is nothing to install with Homebrew and nothing is downloaded during the build.

## Build from source

```bash
git clone https://github.com/Harmanjit/minivu.git
cd minivu
scripts/make_app.sh            # release build, assembles build/minivu.app, signs it
open build/minivu.app
```

Drag `build/minivu.app` to Applications to keep it. To open images with it from Finder, Control-click one and choose **Open With**.

`scripts/make_app.sh`:

1. Builds the release binary with `swift build -c release`.
2. Replaces `build/minivu.app` with a fresh bundle, copies the binary in and strips its local symbols, which halves its size.
3. Copies the two resource bundles into `Contents/Resources`: the Metal shaders, and the pages for **Help > minivu Help**.
4. Precompiles the shaders into a Metal library when the Metal toolchain is installed, and otherwise says they will compile at launch.
5. Writes `Info.plist`, which registers minivu as an alternate editor for images, camera RAW files, PDF and SVG, and lets you drop a folder on its Dock icon.
6. Signs the bundle ad hoc with the hardened runtime and the sandbox entitlements in [`scripts/minivu.entitlements`](https://github.com/Harmanjit/minivu/blob/main/scripts/minivu.entitlements), verifies the signature, and prints the bundle's size, about 5.7 MB.

The script takes an optional version number, which goes into `Info.plist` (the default is 0.1.0):

```bash
scripts/make_app.sh 0.2.0
```

## The Gatekeeper dialog

The app is signed ad hoc, not with an Apple Developer ID, and isn't notarised, so Gatekeeper stops it the first time it is opened from a download or a copy on another Mac. The Mac that built it opens it straight away.

1. Try to open the app once and dismiss the dialog.
2. Open **System Settings > Privacy & Security**, scroll to the message about minivu, and click **Open Anyway**.

Since macOS 15, Control-click > Open no longer skips this step. Alternatively, remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/minivu.app
```

This is a one-time step per Mac. The app is sandboxed and hardened regardless of the dialog; see [Security and Privacy](Security-and-Privacy).

## Updating

```bash
cd minivu
git pull
scripts/make_app.sh
```

Quit minivu first, then replace the copy in Applications with the new `build/minivu.app`. The script deletes and rebuilds `build/minivu.app` each time, so a copy you run from `build/` is replaced too.

Settings, the catalog of stars and tags, and the thumbnail cache live in the app's container, outside the app bundle, so replacing the app leaves them in place.

## Uninstalling

1. Quit minivu and move `minivu.app` to the Trash.
2. To remove its data too, delete its container, `~/Library/Containers/com.minivu.app`. In Finder, choose **Go > Go to Folder…** and type `~/Library/Containers`. Everything minivu keeps for itself is inside:

| What | Where, inside the container |
|---|---|
| Catalog: star ratings, tags, custom sort orders | `Data/Library/Application Support/minivu/catalog.sqlite` |
| Thumbnail cache | `Data/Library/Caches/minivu/thumbnails.sqlite` |
| Settings, sidebar folders, the last folder shown, recent Copy To and Move To folders, the options last used in Save As and the tools, slideshow music, external editors | `Data/Library/Preferences/com.minivu.app.plist` |

Stars and tags exist only in the catalog, not in your files, so deleting the container loses them. The thumbnail cache alone can be emptied from the app with **Settings > Thumbnails > Clear Thumbnail Cache**.

Two folders it may have made in Pictures are yours to keep or delete: **minivu Captures** (screen captures) and **minivu Wallpapers** (montages, and copies made for **Set as Desktop Picture**). If you used **Tools > Capture > Entire Screen** or **Selection…**, you can also remove minivu from **System Settings > Privacy & Security > Screen & System Audio Recording**.

## Development builds

```bash
swift build                    # debug build: .build/debug/minivu
swift test                     # unit, window and GPU tests
scripts/make_app.sh --dev      # the bundle without the sandbox
```

`swift test` runs the 1013 automated tests. The GPU tests run on the real device, and tests use a private catalog in memory, never yours.

The bare `.build/debug/minivu` executable isn't sandboxed and has no bundle identifier, so it doesn't use the container: its catalog, thumbnail cache and settings go to `~/Library/Application Support/minivu`, `~/Library/Caches/minivu` and `~/Library/Preferences/minivu.plist`. It opens a folder or image given on the command line:

```bash
.build/debug/minivu /path/to/folder
```

The sandboxed bundle can't reach an arbitrary path that way, which is what `--dev` is for: `open build/minivu.app --args /path/to/folder`. External drives are refused in every build.

Debug builds can also picture their own windows for screenshots, and a decode benchmark runs on a folder of your own; the [README](https://github.com/Harmanjit/minivu/blob/main/README.md) shows how.
