# Motivation

FastStone Image Viewer is a good model for a photo tool: one window to browse a folder, a viewer that opens instantly and fills the screen, quick culling from the keyboard, the everyday edits (resize, crop, levels, a few effects), and batch tools for the chores. It is a Windows program.

minivu is that kind of tool for the Mac: a lean, native replacement that treats a folder as a folder, with no import step and no library to maintain, designed for Apple Silicon and nothing else.

## What it is for

- **Fast on huge folders.** The grid recycles its cells, so a folder of ten thousand files costs the same to show as fifty. Thumbnails are decoded small, at 256 or 512 pixels on the long edge, never at full size, and kept in a cache on disk. Moving to the next image in the viewer shows no decode delay, because neighbours are decoded ahead at screen size.
- **Correct colour and real HDR.** Every image is colour managed, with any embedded profile honoured. HDR photos, gain maps and RAW files rendered with extended dynamic range show real highlights on an XDR or HDR display and are tone mapped smoothly on other screens, by the same code path.
- **Non-destructive editing.** Edits are a list of steps, shown on the GPU as you make them. Nothing on disk changes until you save, and undo goes back 50 steps.
- **Small.** The release app is a few megabytes, translations included. There is no third-party code: below the app are only Apple's frameworks, so there is nothing to vendor, update or audit.
- **Private.** The app runs in the App Sandbox without the network entitlement, so macOS does not let it open a connection. No account, analytics, crash reporting or update check. The features that look inside your pictures (Live Text, Remove Background, red-eye detection, Find Duplicates) use Apple's frameworks on the Mac. See [Security and Privacy](Security-and-Privacy).
- **In your language.** The menus, windows and help are in English and ten other languages, for now machine translated. See [Languages](Languages).
- **Free software.** GPLv3.
- **Apple Silicon only.** The CPU and GPU share memory, so a decoded image becomes a Metal texture without being copied between CPU and GPU memory. minivu needs the Metal 3 feature set that every M1 has, and nothing newer.

## What that buys

Measured on an M1 Pro MacBook Pro:

| | |
|---|---|
| Warm launch to the browser window | ~131 ms |
| Next or previous image in the viewer | 9–17 ms |
| Scrolling a folder of 5000 thumbnails | smooth, peak memory ~186 MB |
| A 24 MP JPEG decoded for the screen | ~43 ms and 32 MB |
| Main thread blocked while the viewer opens | ~25–45 ms |

The JPEG figure is small because previews decode at the size the image is shown, using the codec's own downscaling. The full-resolution image is decoded, in the background, only when you zoom or use the magnifier past what the screen-sized one can show.

A fuller study in November 2026, on an M4 MacBook Air, measured every user-facing operation, found where minivu is still slow (renaming many files in the folder on screen, the first sort by rating of a folder of camera files, the RAW exposure slider, Batch Convert when it shrinks photos) and set out a plan to fix it. It also measured a higher memory peak for scrolling 5000 thumbnails (about 281 MB) than the figure above. It is in [PERFORMANCE.md](https://github.com/Harmanjit/minivu/blob/main/docs/PERFORMANCE.md).

## Design principles

From the spec, [DESIGN.md](https://github.com/Harmanjit/minivu/blob/main/DESIGN.md):

- **Every pixel that reaches the screen is drawn by Metal.**
- **Idle means idle.** No timers, no polling, no redraws when nothing changed. Frames are drawn on a display link that pauses itself.
- **No work on the main thread that can take more than a few milliseconds.** Decoding, thumbnailing, database writes and file operations happen off it.
- **Never decode more pixels than will be shown.**
- **Never copy pixels between CPU and GPU;** share the memory.
- **No dependencies.** If Apple's frameworks can do it, use them; if not, write the small piece that is needed.

## What it leaves out, on purpose

These were decided as non-goals in the spec, not left for later:

- **Formats without a native macOS decoder.** minivu shows what macOS decodes: JPEG, PNG, GIF, HEIC/HEIF, AVIF, WebP, JPEG XL, JPEG 2000, TIFF, BMP, TGA, ICO, PSD, Apple's camera RAW list, PDF and SVG, and the videos macOS plays, such as MOV and MP4. PCX, WMF, EPS and Sigma's X3F are not supported, and slideshow music is MP3, AAC/M4A, WAV or AIFF, not WMA.
- **Video editing.** Videos are shown and played among the photos, as in FastStone. Nothing trims, converts or edits them.
- **Network access of any kind.** The help is bundled, and there is no update check.
- **Removable and external media.** Memory cards, USB drives, disk images and network volumes are refused; copy the photos to a folder on the Mac's internal storage first.
- **Scanners, email tools, touch screens and a portable mode.** Settings live in the app's sandbox container, not beside the app.
- **Multiple app instances.** One copy of minivu runs, with one browser window showing one folder at a time.
- **Other platforms.** No Intel Macs, iPad, iPhone, Windows or Linux.

minivu is also not a RAW developer or a digital asset manager. RAW files are shown through Apple's own RAW engine, and **RAW Adjustments…** offers that engine's own settings (exposure, white balance, noise reduction) and nothing more: no masks, profiles or lens corrections. Stars and tags stay in a local catalog, and go into the files only if you ask (**Settings > General > Write ratings into files (XMP)**). Collections, smart folders and Find work on your folders as they are, with no import and no index. The edits are the FastStone kind rather than a raw processing pipeline. See [Limitations](Limitations).
