# Tools

The **Tools** menu holds the things you do with many images at once, or with an image rather than to it. Printing lives in the **File** menu but is described here too.

**What a tool works on.** In the browser, a tool uses the selected images in grid order, or every image shown (filters applied) when nothing is selected. Folders never count. In the viewer, it uses the image on screen. Batch Convert, Batch Rename, Contact Sheet and Montage Wallpaper are browser-only; Capture works with no window open at all.

The commands that open a sheet are unavailable while another sheet is up on the same window, and the two batch commands also while a batch or a copy is still running.

| Command | Shortcut | Browser | Viewer |
|---|---|---|---|
| **Tools > Start Slideshow** | ⇧⌘F | yes | yes |
| **Tools > Batch Convert…** | ⌥⌘B | yes | |
| **Tools > Batch Rename…** | ⇧F2 | yes | |
| **File > Print…** | ⌘P | yes | yes |
| **File > Page Setup…** | ⇧⌘P | yes | yes |
| **Tools > Contact Sheet…** | | yes | |
| **Tools > Montage Wallpaper…** | | yes | |
| **Tools > Set as Desktop Picture** | | yes | yes |
| **Tools > Capture** | | anywhere | anywhere |
| **Tools > Open in External Editor** | ⌘E for the first editor | yes | yes |

## Slideshow

**Tools > Start Slideshow** (⇧⌘F), the **Slideshow** button in the browser's toolbar, or the play button in the viewer's control bar.

**Which images.** In the browser, two or more selected images play on their own. Otherwise every image shown plays, starting from the selected one (or the first). In the viewer, the viewer's whole list plays from the image shown, and when the show ends the viewer moves to the last slide. There is one slideshow at a time; starting another brings the running one forward.

**Where it plays.** Full screen on the display chosen by **Settings > Viewer > Full-screen viewer opens on**, so with **Another display** a show started in the browser leaves the browser's display free. A show started from a full-screen viewer plays over it, unless **Another display** is chosen and that viewer is on the browser's display. **Window > Move to Next Display** (⌃⌥⌘→) moves a running show. The menu bar and Dock hide while the show is in front, the display doesn't go to sleep, and the picture stays below a notched display's camera housing.

**Pictures.** The next and previous slides are decoded ahead, fitted to the screen. HDR photos show in HDR when **Display HDR photos in HDR** is on and the screen can show it, and **Enlarge small images to fit** applies as in the viewer. An image that can't be loaded is skipped from then on, in both directions; if nothing loads, the show ends.

### Keys and controls

| Key | Does |
|---|---|
| Space | Pause or resume |
| → ↓ Page Down | Next slide |
| ← ↑ Page Up | Previous slide |
| Esc, or ⌘W | End the show |

A click anywhere outside the control bar also ends the show. The arrow keys never wait for a transition: one under way finishes at once and a quick one (0.35 s, or the set duration if shorter) starts.

Move the pointer to bring up the control bar: **Previous**, **Play**/**Pause**, **Next**, **Mute Music** (only in a show that started with music), **Slideshow Settings** and **End Slideshow**. It and the pointer hide again after two seconds without movement, but not while the pointer is over the bar. The gear pauses the show and opens **Settings > Slideshow** in front of it; the show resumes when it is in front again, for example when you close Settings.

### Timing, order and captions

All in **Settings > Slideshow** (see [Settings](Settings)):

- **Show each slide for** 1 to 60 seconds, counted from the end of each transition. Resuming after a pause waits a full interval.
- **Order:** **In order** or **Shuffled**. Shuffled puts the starting image first and the rest in a random order fixed for the run, so each image shows once per pass and a loop repeats the same order.
- **Start again after the last slide.** Off, the show ends after the last slide.
- **Captions** in the bottom-left corner: **None**, **File name**, **File name and date** (the date taken, else when the file last changed), or **Camera and exposure** (camera, lens and exposure; a file with none of them shows its name). A caption too long for the space beside the control bar is shortened in the middle.

The interval, transition and captions can be changed during a show and apply from the next slide. Order, looping, the playlist and music shuffle are fixed when the show starts.

### Transitions

Eight, drawn on the GPU, or **Random**, which picks a different one from the last for every slide. **Duration** is 0.3 to 3 seconds. The Settings pane has a preview you click to play.

| Transition | What it does |
|---|---|
| Cross-Fade | The new slide fades in over the old (the default) |
| Fade Through Black | The old slide fades to black, then the new one fades in |
| Slide | The new slide moves in over the old one (from the right going forward, from the left going back) |
| Push | The new slide pushes the old one out |
| Wipe | A soft edge sweeps across |
| Zoom | The old slide grows and fades while the new one settles from slightly smaller |
| Iris | A circle opens from the centre |
| Dissolve | Blotches of the new slide appear and merge |

The first slide fades in from black. With **Reduce Motion** on in macOS's Accessibility settings, the transitions that move the picture (Slide, Push, Wipe, Zoom, Iris) play as a cross-fade; see [Accessibility](Accessibility).

### Music

Turn on **Play music** and choose songs with **Add…**: MP3, AAC, WAV or AIFF files, or folders of them. A folder contributes the songs directly inside it, in name order; subfolders are not searched. Songs play in the order listed, or shuffled once per show with **Shuffle**, and go round again after the last. A song that won't open is skipped.

The music fades in when the show starts, pauses with it, and fades out over a second and a half when it ends. In a show that started with music, **Volume**, and turning **Play music** off or on, take effect at once; the control bar's mute button silences it for that show only.

## Batch Convert

**Tools > Batch Convert…** (⌥⌘B) saves converted copies of the images. The originals are never changed unless you choose to replace them and confirm. The sheet's title says how many images it will convert, and the line at the bottom shows the first file's new name (`IMG_0001.NEF → IMG_0001.jpg`), with anything in the way in red below it.

**Format.** The formats Save As writes, with the same options. A format you haven't picked yet in the sheet starts from what Save As last used for it.

| Format | Extension | Quality | Colour profile | 16 bits | Metadata |
|---|---|---|---|---|---|
| JPEG | `.jpg` | 1–100 (90) | yes | | yes |
| PNG | `.png` | | yes | yes | yes |
| HEIC | `.heic` | 1–100 (80) | yes | | yes |
| TIFF | `.tif` | | yes | yes | yes |
| BMP | `.bmp` | | sRGB | | |
| GIF | `.gif` | | sRGB | | |
| TGA | `.tga` | | sRGB | | |
| JPEG 2000 | `.jp2` | 1–100 (90) | yes | | |
| ICO | `.ico` | | sRGB | | |

- **Color profile:** **Keep original** (the default), **sRGB**, **Display P3** or **Adobe RGB (1998)**. Formats that can't hold a profile are always converted to sRGB.
- **Compression** (TIFF): **None**, **LZW** (the default) or **PackBits**, all lossless.
- **Background for transparency** (JPEG and BMP, which have none): white by default.
- **Progressive** (JPEG), off by default. **16 bits per channel** (PNG and TIFF), off by default.
- **Keep metadata (EXIF, GPS, IPTC, XMP)**, on by default where the format can carry it. The orientation is reset, since the pixels are written upright. Keeping metadata keeps the GPS position too; turn it off to strip it.

**Size and Orientation.**

- **Resize:** **Don't Resize** (the default), **Long Side**, **Width**, **Height** (1 to 32,768 pixels; 2048 to start) or **Percentage** (above 0 up to 1000%; 50 to start). Proportions are always kept.
- **Resampling:** any of the eleven filters of **Image > Resize/Resample…**; **Lanczos 3** by default. See [Editing](Editing).
- **Don't enlarge smaller images**, on by default: a picture already smaller than asked keeps its size.
- **Rotate:** **None**, **90° Right**, **180°** or **90° Left**. **Flip:** **Horizontal**, **Vertical**.

Turning and flipping happen before the resize, so a width means the width of the picture as it comes out. RAW files are rendered as **Settings > Viewer > RAW files** says, one at a time. Converted files are always SDR.

**Destination.** **Save to** **Beside the originals** (the default) or a folder you choose with **Choose…**. The folder must be on the Mac's internal storage. It is remembered, and if it has gone by next time the sheet goes back to beside the originals.

**File Names.** **Keep the original names** (with the new extension), or **Use a pattern**, with the same pattern controls as Batch Rename below. Batch Convert remembers its own pattern, separately from Batch Rename's. `{ext}` is the original extension; the new format's extension is added after it.

**If a file exists.** Every name is settled before anything is written:

- Two converted files never share a name, and a converted file never lands on another image of the batch. Either way the converted file is numbered (`photo 2.jpg`), whatever the setting.
- A file already in the destination follows **If a file exists**: **Skip**, **Keep Both** (the default: the new file is numbered) or **Replace (Move Old to Trash)**. A folder of that name is never replaced.
- With **Replace**, minivu first asks once, naming what would go to the Trash: originals that their own conversions would replace (a JPEG converted to JPEG beside the originals with the names kept), and up to three existing files that aren't part of the batch. The answers are **Replace**, **Keep Both** (numbered names, for this run only) and **Cancel**, which is the default, so Return never replaces anything.
- An original replaced by its own conversion keeps its stars, tag and Custom Order place. Any other replaced file takes its marks to the Trash with it.

Each file is written in full under a hidden name before it takes its real one, so nothing is ever half written, and a replaced file goes to the Trash only once the new one is complete.

**Running.** **Convert** remembers the sheet's settings and starts. A progress sheet shows the count, the file in hand and **Cancel**. Two files convert at a time (one on a Mac with 8 GB of memory or less), and never more than one camera RAW at once. **Cancel** starts no new files and drops any conversion that finishes afterwards; a write already queued completes, so only whole files are left. When it is done, converted files in the folder you are looking at are selected. If anything was skipped or failed, an alert lists up to eight of each, with the reason.

Only the first page or frame of a multi-page or animated file is converted.

## Batch Rename

**Tools > Batch Rename…** (⇧F2, beside Rename's F2) renames the images from a pattern. The sheet shows a live Before and After list and renames nothing until you press **Rename**.

**Pattern.** Text with tokens. Type them, in any letter case, or pick them from **Insert Token**, which adds one at the end.

| Token | Becomes |
|---|---|
| `{name}` | The original name without its extension |
| `{#}`, `{###}` | The counter; each `#` is a digit, zero-padded |
| `{date}` | The date taken (EXIF DateTimeOriginal, else DateTimeDigitized), else the file's modification date; `yyyy-MM-dd` |
| `{date:yyyy-MM-dd HH.mm.ss}` | The same, in a format of your own |
| `{modified}`, `{modified:HH.mm}` | The modification date, with an optional format |
| `{width}`, `{height}` | The picture's pixel size as displayed (orientation applied) |
| `{ext}` | The original extension, without the dot |

Date formats are Unicode date patterns. Names come out the same on every Mac, whatever its region or calendar, and a date taken is written on the camera's clock when the file records its time zone. The date taken and pixel size are read from the files only when the pattern uses them. A token minivu doesn't know, such as `{nmae}`, stays in the name as typed and blocks **Rename** until it is fixed.

**Counter.** **start** and **step** (1 and 1 to begin with), and a minimum number of **digits** from 1 to 9. The larger of that and the token's own `#`s wins, so `{#}` with 4 digits gives `0001`.

**Replace.** Plain text (not a regular expression) replaced everywhere in the name the tokens made, with or without **Match case**.

**Letter case.** For the name: **Unchanged**, **lowercase**, **UPPERCASE** or **Title Case**. For the extension: **Unchanged**, **lowercase** or **UPPERCASE**.

Names are made in that order: tokens, then find and replace, then the name's letter case; the extension goes on last, in its own case. The counter follows the order of the list, which is the grid's order.

**Checking.** The line under the list says how many files will be renamed, or the first problem: two files would get one name, a name belongs to an item that isn't being renamed, a file can't be found any more, or a name isn't allowed (empty, a `/` or `:`, a leading dot, too long). Names are compared as the disk compares them, so `IMG.JPG` and `img.jpg` clash on an ordinary case-insensitive volume. Problem rows are marked in the list. **Rename** is available only when every name works. A name held by another file of the same batch is fine: swaps (`a.jpg` ↔ `b.jpg`) and chains work, and so does a rename that only changes letter case.

**Undo.** The whole rename is one step, **Edit > Undo Rename 12 Items** (⌘Z), and redo puts it back. Stars, tags and Custom Order places follow the files. The pattern is remembered for next time.

## Print and Page Setup

**File > Print…** (⌘P) prints the images with a layout; **File > Page Setup…** (⇧⌘P) chooses the printer, paper, orientation and scale. In the browser, Print uses the selected images, or every image shown; in the viewer, the image and page shown. With unsaved edits in the viewer, it prints the edited picture on screen, not the file.

The print panel is the standard macOS one, with its preview, copies, page range, paper size, orientation and scale, plus minivu's **Picture Layout** section:

| Setting | Choices | Default |
|---|---|---|
| **Images per page** | 1, 2, 4, 6, 9, 12, 20, 30 | 1 |
| **Scaling** | **Fit** or **Fill** | Fit |
| **Rotate pictures to fill the cells** | on or off | on |
| **Margins** | 0 to 72 pt | 18 pt |
| **Spacing** | 0 to 36 pt | 12 pt |
| **Captions** | **None**, **Name**, **Name and Date** | None |

72 pt is an inch. The margin and spacing sliders move in steps of 3 pt and show their values in millimetres, or inches where the region uses them. A margin is never smaller than the printer's own unprintable edge. The grid is the one whose cells are closest to square, turned for a landscape page: 6 images on portrait paper are 2 across and 3 down. **Name and Date** uses the date taken, else the file's date.

The panel's preview is drawn from small copies of the pictures. The print itself decodes them for the printer's resolution (150 to 600 dpi, at most 6000 pixels on the long edge) in the background, so minivu stays usable meanwhile.

The layout is remembered between prints. After a print, the printer, paper, orientation and scale chosen in the panel become Page Setup's, as in other Mac apps; copies and page range don't carry over.

## Contact Sheet

**Tools > Contact Sheet…** lays the images out on pages, with a preview of page 1 and a summary such as `24 images · 2 pages · 2480 × 3508 px`. Everything but the header text is remembered; the header starts as the folder's name each time.

**Page.**

- **Size:** **A4 at 300 dpi** (2480 × 3508 px, the default), **US Letter at 300 dpi** (2550 × 3300), **4K Display** (3840 × 2160), or **Custom**, 256 to 16,384 px a side (3000 × 2000 to start).
- **Orientation:** **Portrait** (default) or **Landscape**; a custom size is taken as typed.
- **Background:** white by default.

**Grid.** **Columns** 1 to 20 (4); **Rows** 0 to 30 (5), where 0 is **Auto (one page)**; **Spacing** 0 to 400 px (40); **Margin** 0 to 800 px (120); **Pictures** **Fit in Cell** (default) or **Fill Cell**.

**Text.** **Captions:** **None**, **Name** (default), **Name and Dimensions** or **Name and Date**. **Text size** 8 to 200 px (36); the header is set larger. **Header**, on by default, with its text. **Page numbers** ("Page 2 of 5"), on by default.

**File.** **Format:** **JPEG** (default, quality 90), **PNG**, **TIFF** or **PDF**. **Color profile:** **sRGB** (default) or **Display P3**, for the picture formats. A PDF holds every page, with A4 and Letter pages at their paper size, and pictures embedded at the size of their cells.

**Save…** asks where. A PDF, or a sheet of one page, gets a save panel with a name made from the header text (`Trip Contact Sheet.pdf`; plain `Contact Sheet` without any), and the panel asks before replacing a file. Several picture pages go into a folder you choose, as `Trip Contact Sheet 1.jpg`, `Trip Contact Sheet 2.jpg` and so on; if any of those names is taken, the whole set is numbered again (`Trip Contact Sheet 2 1.jpg`), so nothing is replaced. Cancelling the panel goes back to the dialog as you left it.

Pages are made on the same disk and moved into place only when all of them are finished. A progress sheet with **Cancel** appears for a large sheet, or when a small one takes more than a moment. A cancelled or failed sheet leaves nothing in the destination. The finished sheet opens in the viewer.

## Montage Wallpaper

**Tools > Montage Wallpaper…** makes a collage of the images at a display's size and sets it as that display's desktop picture. A montage uses at most 200 photos; with more, it takes the first 200 and the sheet says so.

- **Display:** each display, with its pixel size, and **All Displays** when there are several. It starts on the display the browser is on.
- **Layout:** **Grid** (uniform cells; each photo fills its cell and is cropped to it, with spare cells repeating photos), **Mosaic** (justified rows: each photo keeps its shape, cropped only by the few percent that make the rows fill the screen), or **Scattered** (tilted prints with white borders and soft shadows, overlapping a little). **Shuffle** scatters them another way.
- **Spacing:** 0 to 40 pt between photos and around the edge, 8 pt by default. It is measured in points, so it looks the same on Retina and standard displays.
- **Background:** a near-black grey by default.

The layout, spacing and background are remembered. The preview follows every change.

**Set as Wallpaper** draws the montage at the display's full pixel size, saves it as a JPEG in **Pictures/minivu Wallpapers** (`Montage 2026-09-14 at 10.30.05.jpg`, with ` (1)`, ` (2)` for each display of **All Displays**) and sets it as the desktop picture, scaled to fill. **Cancel** stops it; a cancelled or failed run deletes any montages it had already written. minivu never deletes montages that were set.

## Set as Desktop Picture

**Tools > Set as Desktop Picture** uses one image: the lead image of the browser's selection on the browser's display, or the viewer's image on the viewer's display. The picture is scaled to fill the screen, keeping its shape and cropping what overflows.

macOS reopens a desktop picture's file later, and after every restart, so minivu uses the file itself only when it is a JPEG, PNG, HEIC or TIFF inside your Pictures folder and has no unsaved edits. Anything else (a RAW, a WebP, a photo outside Pictures, or the viewer's unsaved edits) is exported first as a copy in **Pictures/minivu Wallpapers**, named `Desktop 2026-09-14 at 10.30.05 IMG_0001.jpg` (HEIC when the picture has transparency), in SDR and no larger than twice the screen's long edge. minivu keeps the newest ten copies and removes older ones, but never one a display is showing; a copy set on another Space can still be removed while it is in use there.

## Capture

**Tools > Capture** has three commands, and no shortcuts, because macOS keeps ⇧⌘3 to ⇧⌘5 for its own screenshots:

- **Entire Screen** captures the whole display the pointer is on, at its full pixel size.
- **Window…** opens the system's window picker; the window you click is captured.
- **Selection…** dims every screen and shows a crosshair. Drag a rectangle, which shows its size in pixels; letting go, or Return, captures it. A click without a drag clears the rectangle. Esc, or switching to another app, cancels.

minivu's own windows are left out of Entire Screen and Selection captures, and the pointer is never included. Each capture is saved as a PNG in **Pictures/minivu Captures**, named `Capture 2026-09-14 at 10.30.05.png`, and opens in the viewer.

**Permission.** Entire Screen and Selection need Screen Recording permission. The first time, macOS asks. If it has been refused, minivu explains instead and offers **Open System Settings**: turn minivu on in **System Settings > Privacy & Security > Screen & System Audio Recording**, then quit and reopen minivu. **Window…** needs no permission, because choosing a window in the system's picker is itself the consent.

Captures are 8-bit SDR, even on an HDR screen.

## External editors

**Tools > Open in External Editor** lists the applications you have added, each with its icon, then **Edit Editor List…**, which opens **Settings > Editors**. The first editor in the list opens with ⌘E. The list starts empty; see [Settings](Settings) for adding, ordering and the suggestions of editors already installed.

**What opens.** In the browser, the selected images, or the lead image. Unlike the other tools, it never falls back to every image in the folder. Opening more than 20 images asks first, since each becomes a window or tab in the editor. In the viewer, the image shown. If it has unsaved edits, minivu says so first: the editor gets the file as last saved, and **Open Saved File** goes ahead. If an application has moved or been deleted, minivu says it can't be found and offers **Edit Editor List…**.

**When the editor saves.** minivu watches the files it sent, in the eight folders most recently sent to an editor. When one changes, the browser's thumbnail updates and the viewer shows the new version, keeping the zoom and position when the size hasn't changed. If you have unsaved edits of that image in the viewer, it asks: **Keep My Edits** (the default) or **Reload**, which shows the editor's version and discards yours. After keeping your edits, **Save** asks for a new name for the rest of that session, so neither version is lost.

## See also

- [Editing](Editing) for Save As, whose options Batch Convert shares, and the resampling filters.
- [Settings](Settings) for the Slideshow and Editors panes.
- [Keyboard Shortcuts](Keyboard-Shortcuts) for every key.
- [Limitations](Limitations) for what these tools don't do.
