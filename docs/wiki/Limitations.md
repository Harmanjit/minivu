# Limitations

An honest list. Some are design decisions, some are unfinished work, some are the price of using only what macOS provides.

## Files and formats

- **Internal storage only.** Memory cards, USB and external drives, disk images and network shares are refused, by design. Copy the photos to a folder on the Mac first.
- **Only what macOS decodes.** Formats without a native decoder, such as PCX, WMF, EPS and Sigma's X3F, don't open. The browser shows files by extension from one list, so a file with an extension that isn't on it doesn't appear, even if ImageIO could read it.
- **RAW support is Apple's camera list.** A camera macOS doesn't know shows only the preview it embedded, as large as the camera made it, and some files not at all.
- **Photoshop files are flattened.** Layers aren't shown separately.
- **Very large images are shown downscaled.** Anything over 16384 px on a side, Metal's texture limit, is displayed at that size.
- **No WebP, AVIF or JPEG XL output.** Save As and Batch Convert write JPEG, PNG, HEIC, TIFF, BMP, GIF, TGA, JPEG 2000 and ICO.
- **Save can't write some files back.** RAW, WebP, AVIF, JPEG XL, PDF, SVG and Photoshop files, animations, and files holding more than one image (a multi-page TIFF, an icon with several sizes, a HEIC collection) open Save As instead.
- **Lossless rotate and flip in the browser** work on JPEG, HEIC and HEIF, TIFF and PNG, by changing the orientation tag. RAW files are never changed; GIF, BMP and other formats without the tag are skipped and named afterwards. **Edit Comment…** is for JPEGs only.

## HDR

- **Save keeps HDR only for gain-map JPEG and HEIC originals.** PQ and HLG files, and gain maps in other formats, are saved tone mapped to SDR, and the "Replace the original?" alert says so. **Save As** is always SDR.
- **Everything that makes a new picture is SDR:** Batch Convert, thumbnails, prints, contact sheets, montages, desktop picture copies and screen captures.
- **RAW extended dynamic range** reaches about twice SDR white, the most Apple's RAW engine gives, and takes a moment per photo.
- **HDR shows only on screens that can show it.** Other screens get a tone-mapped image, and the room above white on an HDR screen shrinks as its brightness goes up.

## Editing and saving

- **50 steps of undo,** and the history starts again after a Save.
- **Save writes a new file in place of the old,** atomically. A hard link to the old file keeps the old picture, and a symbolic link is written through to the file it points at.
- **The record of minivu's own writes is by path.** If another application changes a file you are editing and you then write a comment to it in minivu, Save can replace that other version.
- **External editors and Keep My Edits.** After you choose Keep My Edits, the viewer keeps the file's old date and size for that edit session, so if you then revert the edits, the info panel and colour count lag until the editor saves again or you move to another image.

## File management

- **Stars and tags live only in minivu's catalog.** They aren't written to XMP sidecars or Finder tags, so other applications don't see them. Finder tags are read, shown and filtered by, never changed.
- **Marks follow a file moved in Finder only when you open the folder it went to** in minivu. A file missing from its folder for a year loses its marks.
- **On a case-sensitive volume, "A.jpg" and "a.jpg" in one folder share their marks,** because the catalog compares paths without case.
- **Captures, montages and desktop copies take a free name just before writing.** A file another application creates under that name in the same instant would be replaced.

## Tools

- **Batch Convert** converts only the first page or frame of multi-page and animated files.
- **Slideshow:** resuming after a pause waits a full interval. A caption longer than the space beside the control bar is cut short in the middle. Changing the HDR or RAW settings during a show changes what is on screen only at the next slide.
- **Print:** paper smaller than its unprintable edges gets empty cells, and Page Setup scales below 10% count as 10%. The preview is recognised by the class name of its graphics context; if macOS renames it, the preview decodes at print quality on the main thread.
- **Capture** writes 8-bit SDR PNGs. HDR capture isn't implemented.
- **Set as Desktop Picture** keeps the ten newest copies it made, but a copy set on another Space can be removed while still in use there.
- **Compare** shows at most four images.
- **Help:** without a Help Book, the search field in the **Help** menu finds menu items only, not the text of the help pages. The Help window's own search does that.

## Platform and distribution

- **Apple Silicon and macOS 15 only,** by design. No Intel Macs, no iPad or iPhone, no other operating systems.
- **Not notarised.** The app is signed ad hoc, without an Apple Developer ID, so every other Mac shows the Gatekeeper dialog once. See [Installation](Installation).
- **No network, so no update check.** A new version means building or copying a new app.
- **Left out on purpose:** scanners, touch screens, email tools, a portable mode and running several copies at once.
- **Building needs full Xcode** with Swift 6.2. Without Xcode's Metal toolchain the shaders compile when the app launches instead of at build time.

## Verification

- **Measured on few Macs.** minivu is developed and tested on an M1 Pro MacBook Pro, where the numbers in [Architecture](Architecture) were measured; many timings and memory figures in the code's comments come from an M4. Other Apple Silicon Macs may behave differently.
- **Two displays are tested only with simulated displays.** Full screen on another display, **Move to Next Display**, unplugging a display and notched screens are covered by tests that stand in for real screens, not on a real second display.
- **Benchmarks aren't part of the test run.** They are skipped by a plain `swift test`, and most need a folder of your own photos in `MINIVU_BENCH_DIR`.
