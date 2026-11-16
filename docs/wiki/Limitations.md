# Limitations

An honest list. Some are design decisions, some are unfinished work, some are the price of using only what macOS provides.

## Files and formats

- **Internal storage only.** Memory cards, USB and external drives, disk images and network shares are refused, by design. Copy the photos to a folder on the Mac first.
- **Only what macOS decodes.** Formats without a native decoder, such as PCX, WMF, EPS and Sigma's X3F, don't open. The browser shows files by extension from one list, so a file with an extension that isn't on it doesn't appear, even if ImageIO could read it.
- **RAW support is Apple's camera list.** A camera macOS doesn't know shows only the preview it embedded, as large as the camera made it, and some files not at all.
- **Photoshop files are flattened.** Layers aren't shown separately.
- **Very large images are shown downscaled.** Anything over 16384 px on a side, Metal's texture limit, is displayed at that size.
- **A file claiming more than 32768 x 32768 pixels gets no thumbnail** in the browser, the same cap Resize and Batch Convert put on minivu's own output. It still opens in the viewer. **Count Colors** also refuses an image too large to count on this Mac, rather than spending minutes paging, and says so. Exports refuse a file whose claimed size is past a quarter of the Mac's memory; see [Security and Privacy](Security-and-Privacy).
- **No WebP or JPEG XL output.** Save As and Batch Convert write JPEG, PNG, HEIC, TIFF, BMP, GIF, TGA, JPEG 2000 and ICO, and AVIF where this Mac's ImageIO can write it. Where it can't, AVIF isn't offered, and a remembered AVIF choice falls back to JPEG.
- **Save can't write some files back.** RAW, WebP, JPEG XL, PDF, SVG and Photoshop files, animations, files holding more than one image (a multi-page TIFF, an icon with several sizes, a HEIC collection), and AVIF on a Mac that can't write it open Save As instead.
- **Lossless rotate and flip in the browser** work on JPEG, HEIC and HEIF, TIFF and PNG, by changing the orientation tag. RAW files are never changed; GIF, BMP, videos and other formats without the tag are skipped and named afterwards. **Edit Comment…** is for JPEGs only.

## Videos

- **minivu plays videos; it doesn't edit them.** Nothing trims, converts, exports or writes a video, and a video's metadata, its location included, is shown but never edited or removed.
- **No frame stepping, playback speed or loop controls.** The player has play and pause, a scrubber, the time, volume and mute.
- **Clicks on a playing video go to the player**, which shows or hides its controls. Double-clicking a playing video doesn't close the viewer, as double-clicking a photo does; double-clicking the still before it plays does.
- **Finder doesn't offer minivu for videos.** **Open With** and dropping a movie on minivu's Dock icon work for images only. Open the folder in minivu instead.
- **The tools that make pictures skip videos:** Slideshow and its video export, Batch Convert, Print, Contact Sheet, Montage Wallpaper, Set as Desktop Picture, Create Multi-Page File, Image Strip, Extract Pages and Create Web Gallery. **Find Duplicates > Similar Images** leaves videos out; **Identical Files** still finds copies of a clip. Batch Rename includes videos.
- **Compare shows a video's first frame only**, and never plays it.
- **Saved and copied frames** (**File > Save Frame As…**, **Edit > Copy Frame**) are SDR and carry none of the video's metadata. Both work in the viewer only.
- **The length in the grid** is read from the file's container without reading the whole file, so for a few files with unusual containers it may be a frame or two out.
- The viewer's filmstrip shows a video's thumbnail without the grid's play mark.
- Before macOS 26, turning off **Display HDR photos in HDR** can't make an HDR video play in standard range; its still is tone mapped either way.

## HDR

- **Save keeps HDR only for gain-map JPEG, HEIC and AVIF originals.** PQ and HLG files, and gain maps in other formats, are saved tone mapped to SDR, and the "Replace the original?" alert says so. **Save As** is always SDR.
- **Batch Convert keeps HDR only as a gain map.** With **Keep HDR** on, JPEG, HEIC and AVIF outputs keep HDR highlights as a gain map, but only with **Color profile** set to **Keep original** or **Display P3** and 8 bits. With sRGB, Adobe RGB or 10 bits, HDR photos are written SDR, and the sheet says so. A PQ or HLG original becomes a gain-map file. The Shortcuts **Convert Images** action follows the same rule.
- **Everything else that makes a new picture is SDR:** thumbnails, prints, contact sheets, montages, desktop picture copies, screen captures, multi-page files, image strips, web galleries, slideshow videos, frames saved from a video and **Copy Subject**.
- **RAW extended dynamic range** reaches about twice SDR white, the most Apple's RAW engine gives, and takes a moment per photo.
- **HDR shows only on screens that can show it.** Other screens get a tone-mapped image, and the room above white on an HDR screen shrinks as its brightness goes up.

## Editing and saving

- **50 steps of undo,** and the history starts again after a Save.
- **Save writes a new file in place of the old,** atomically. A hard link to the old file keeps the old picture, and a symbolic link is written through to the file it points at. Metadata edits do the same.
- **The record of minivu's own writes is by path.** If another application changes a file you are editing and you then write a comment to it in minivu, Save can replace that other version.
- **External editors and Keep My Edits.** After you choose Keep My Edits, the viewer keeps the file's old date and size for that edit session, so if you then revert the edits, the info panel and colour count lag until the editor saves again or you move to another image.
- **Auto Enhance** measures an 8-bit SDR rendering, so on an HDR photo it judges the SDR version; the adjustment itself keeps HDR. Running it twice adds two steps.
- **Perspective…** can't know the true proportions of the rectangle photographed, so it estimates them from the longer edges. The corners stay inside the image.
- **Canvas Size…** is stored in pixels, so it isn't carried by a Batch Convert preset.
- **Watermark…** is one line of text, with no rotation, outline or shadow. A watermark too large for the photo is shown smaller than **Size** says, to fit inside the margins. Tiles form a straight grid. A picture used as a watermark is drawn in SDR.
- **RAW Adjustments…** offers the RAW engine's own settings only: exposure, boost, highlight recovery, white balance and noise reduction. There is no white balance picker, sharpening, local contrast, moiré or lens correction. Save can't write RAW files, so the result is kept with **Save As…**. While the tool is open the viewer shows the engine's rendering, not the camera's embedded preview. If the engine frames the photo a few pixels differently from that preview, the first RAW step changes the image's size by those few pixels, and steps stored in pixels (Resize, Canvas Size) then sit that far off.
- **Remove Background…** keeps every subject Vision finds, or none: you can't pick one subject or refine the edge with a brush. The edge is as soft as Vision makes it, a colour fill is opaque only, and landscapes and textures may have no subject at all.
- **Live Text** reads text in what is shown, up to 4096 px on the long side, so tiny text in a very large photo may need zooming in first. On text, dragging selects instead of panning, and pressing and holding selects instead of showing the magnifier. A playing animation has no Live Text until paused. It isn't offered in the preview pane or the Compare window. It recognises the languages macOS recognises.

## Metadata

- **Edit Metadata…** can't remove a camera RAW file's own location, since RAW files are never modified. The date it writes to a RAW file's sidecar shows in the info panel, but the grid, the sort and Batch Rename's `{date}` still use the date inside the RAW file.
- **A RAW file and a GIF with the same name share one XMP sidecar**, as the sidecar naming convention has it.
- **Titles and captions in several languages:** only the default one is edited; the others keep the old text.
- **PNG** keeps only what XMP can express, so a PNG's maker note, if it has one, is lost when its metadata is edited.
- **Ratings in files** (**Settings > General > Write ratings into files (XMP)**) are written only for changes made while it is on; marks set before stay in the catalog only. A file's own rating shows only until you rate it in minivu: from then on minivu's rating wins, and there is no command to take the file's newer one back. The XMP label (`xmp:Label`) isn't read, and neither are Windows' own EXIF rating tags or IPTC StarRating; `xmp:Rating`, which Windows also writes, is. How each application reads these tags comes from its documentation; it wasn't checked against the applications themselves.
- **Colour labels** apply to images only, not folders, and a file has one at a time: choosing one removes any other standard colour tag. The browser shows them; the viewer and Compare window don't. A file minivu may not change beeps, with nothing else said.

## File management

- **Stars and tags live in minivu's catalog,** and reach the files only while **Write ratings into files (XMP)** is on. Other applications don't see them otherwise. Colour labels are Finder tags, so Finder and Spotlight see them.
- **Marks follow a file moved in Finder only when you open the folder it went to** in minivu. A file missing from its folder for a year loses its marks.
- **On a case-sensitive volume, "A.jpg" and "a.jpg" in one folder share their marks,** because the catalog compares paths without case.
- **Captures, montages and desktop copies take a free name just before writing.** A file another application creates under that name in the same instant would be replaced.
- **Ratings need their database.** If the ratings database can't be opened, minivu says so at launch and the stars, tags and Custom Order you set then last only until it quits.

## Finding and organising

- **Flat View and Find walk at most 12 levels down, 20,000 images and 5,000 folders.** They stop at the deepest level first, and the status bar says "limit reached, not every image is shown".
- **Find Duplicates has the same limits.** Looking in the folder and its subfolders, it leaves out the deepest levels first. Looking in the folder shown, it compares the first 20,000 images by name. Either way its window says "A folder limit was reached: not every image was compared."
- **Flat View and lists don't bring back the marks of files moved in Finder;** opening the file's new folder does.
- **Only the top folder of a flat view is watched** for changes; lists such as search results aren't watched. minivu's own changes show at once.
- **Find doesn't use Spotlight,** so the first search of a large tree by camera details reads every file's header once, which takes a while.
- **Sorting by rating, and filters on camera details, read every file's header** the first time on a folder, which on a thousand camera files takes a few seconds.
- **A collection member moved in Finder** to a folder minivu can't see stays missing until that folder is opened in minivu; one moved to the Trash in Finder stays out until it is put back.
- **The details cache is keyed by path and date,** so a file whose details change while its date is kept shows the old values until it changes again.
- **Find Duplicates** compares at most 10,000 images for similarity on a Mac with 8 GB of memory, 20,000 on others. At loose settings a long burst of slowly changing shots can join into one group. Hard links to one file count as identical files, so trashing one frees no space. **Similar Images** looks at a 256-pixel version, so it doesn't see a dust spot or a small retouch; **Identical Files** is exact.

## Tools

- **Batch Convert** converts only the first page or frame of multi-page and animated files unless **Pages** is set to **Every page**, which keeps the pages together only for TIFF and GIF and writes one file per page for other formats.
- **Presets** have no preview in the Convert sheet. Crop and Perspective steps use the same fractions on every photo, which suits a series shot from one place. Resize and Canvas Size steps are left out of presets. RAW Adjustments carry fixed white balance numbers, which can look different on another camera. The batch's watermark editor has no preview.
- **Multi-page files:** an animated GIF or HEIC must fit in memory as a whole. Animated HEIC has no loop count, and its last frame takes the delay of the one before. There is no animated AVIF. Multi-page outputs carry no metadata, a multi-page TIFF is at most 4 GB, and a PDF's pages are rendered rather than its embedded images extracted. Create Multi-Page File, Image Strip and Extract Pages work in the browser only, not in the viewer or from Shortcuts. The Create Multi-Page File and Image Strip sheets have no live preview; they show only the page count and size.
- **Slideshow:** resuming after a pause waits a full interval. A caption longer than the space beside the control bar is cut short in the middle. Changing the HDR or RAW settings during a show changes what is on screen only at the next slide.
- **Slideshow videos** are SDR only. They use the Slideshow settings, with no separate choices per video. Random transitions differ from one export to the next. An export can't be paused, and quitting abandons it. The dialog counts every picture given, so if some turn out unreadable the video is shorter than it said.
- **Web galleries** are made one picture at a time, so a large one takes a while. The words on the pages are English. There are three themes and no custom templates. HEIC galleries show only in Safari. Animated pictures become their first frame and multi-page files their first page.
- **Print:** paper smaller than its unprintable edges gets empty cells, and Page Setup scales below 10% count as 10%. The preview is recognised by the class name of its graphics context; if macOS renames it, the preview decodes at print quality on the main thread.
- **Capture** writes 8-bit SDR PNGs. HDR capture isn't implemented.
- **Set as Desktop Picture** keeps the ten newest copies it made, but a copy set on another Space can be removed while still in use there.
- **Compare** shows at most four images.
- **Share** offers many files at once without asking; the share sheet shows what is being sent.
- **Help:** without a Help Book, the search field in the **Help** menu finds menu items only, not the text of the help pages. The Help window's own search does that.

## Shortcuts

- **Running a shortcut while minivu is closed opens minivu,** with its browser window and Dock icon, and minivu stays open afterwards.
- **Rename Images works only in Pictures and the folders in minivu's sidebar.** A set that includes a file elsewhere is refused whole.
- **Set Rating rates the file the shortcut passes.** If an earlier step handed on a temporary copy, the copy is rated.
- **Convert Images and Resize Images use Batch Convert's defaults,** not the options you last chose in the Batch Convert sheet, so a shortcut does the same on every Mac.
- **The spoken phrases** of minivu's ready-made shortcuts are English, and whether Siri accepts them hasn't been checked.

## Languages

- **Every translation is a machine translation** that no native speaker has reviewed yet. Some wording will be odd, and in Polish and a few other languages a word may not agree with the number beside it. See [Languages](Languages).
- **Some text stays English:** the names of files minivu writes, the words on web gallery pages, the spoken phrases and summaries in the Shortcuts app, and a few technical details in error messages.

## Platform and distribution

- **Apple Silicon and macOS 15 only,** by design. No Intel Macs, no iPad or iPhone, no other operating systems.
- **Not notarised.** The app is signed ad hoc, without an Apple Developer ID, so every other Mac shows the Gatekeeper dialog once. See [Installation](Installation).
- **No network, so no update check.** A new version means building or copying a new app.
- **Left out on purpose:** scanners, touch screens, email tools, a portable mode and running several copies at once.
- **Building needs full Xcode.** The build uses SwiftPM's Swift Build engine and Xcode's App Intents tool for the Shortcuts actions. Without Xcode's Metal toolchain the shaders compile when the app launches instead of at build time.

## Verification

- **Measured on few Macs.** minivu is developed and tested on an M1 Pro MacBook Pro, where the numbers in [Architecture](Architecture) were measured; the performance study of November 2026 ran on an M4 MacBook Air. Nothing has been measured on a Mac with 8 GB of memory, where minivu's memory rules matter most.
- **Two displays are tested only with simulated displays.** Full screen on another display, **Move to Next Display**, unplugging a display and notched screens are covered by tests that stand in for real screens, not on a real second display.
- **Shortcuts can't be driven by the tests.** The tests call the actions' own code; that the actions appear and run in the Shortcuts app is checked by hand. The hand checks are listed in the feature notes (see [Architecture](Architecture), Tests).
- **Benchmarks aren't part of the test run.** They are skipped by a plain `swift test`, and most need a folder of your own photos in `MINIVU_BENCH_DIR`.
