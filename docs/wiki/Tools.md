# Tools

The **Tools** menu holds the things you do with many images at once, or with an image rather than to it. Printing and Share live in the **File** menu but are described here too, as is Live Text.

**What a tool works on.** In the browser, a tool uses the selected images in grid order, or every image shown (filters applied) when nothing is selected. Folders never count. In the viewer, it uses the image on screen. Batch Convert, Batch Rename, Extract Pages, Find Duplicates, Create Multi-Page File, Image Strip, Contact Sheet, Create Web Gallery and Montage Wallpaper are browser-only; Capture works with no window open at all.

The commands that open a sheet are unavailable while another sheet is up on the same window. Batch Convert, Batch Rename, Extract Pages, Create Multi-Page File and Image Strip are also unavailable while a batch or a copy is still running.

**Videos.** The tools that make or show pictures skip videos: Start Slideshow, Export Slideshow Video, Batch Convert, Extract Pages, Create Multi-Page File, Image Strip, Print, Contact Sheet, Create Web Gallery and Montage Wallpaper. A video's first frame alone would misrepresent it, and minivu doesn't convert video. With only videos chosen, these commands are greyed out. Set as Desktop Picture is greyed out when the image it would use is a video. Batch Rename, Share and Open in External Editor treat a video like any other file. Find Duplicates finds identical copies of a video but leaves videos out of Similar Images.

| Command | Shortcut | Browser | Viewer |
|---|---|---|---|
| **Tools > Start Slideshow** | ⇧⌘F | yes | yes |
| **Tools > Export Slideshow Video…** | | yes | yes |
| **Tools > Batch Convert…** | ⌥⌘B | yes | |
| **Tools > Batch Rename…** | ⇧F2 | yes | |
| **Tools > Extract Pages…** | | yes | |
| **Tools > Find Duplicates…** | | yes | |
| **Tools > Create Multi-Page File…** | | yes | |
| **Tools > Image Strip…** | | yes | |
| **Tools > Contact Sheet…** | | yes | |
| **Tools > Create Web Gallery…** | | yes | |
| **Tools > Montage Wallpaper…** | | yes | |
| **Tools > Set as Desktop Picture** | | yes | yes |
| **Tools > Capture** | | anywhere | anywhere |
| **Tools > Open in External Editor** | ⌘E for the first editor | yes | yes |
| **File > Print…** | ⌘P | yes | yes |
| **File > Page Setup…** | ⇧⌘P | yes | yes |
| **File > Share…** | | yes | yes |
| **Edit > Copy Text** | ⇧⌘C | | yes |

## Slideshow

**Tools > Start Slideshow** (⇧⌘F), the **Slideshow** button in the browser's toolbar, or the play button in the viewer's control bar.

**Which images.** In the browser, two or more selected images play on their own. Otherwise every image shown plays, starting from the selected one (or the first). In the viewer, the viewer's whole list plays from the image shown, and when the show ends the viewer moves to the last slide. Videos are left out; started from a video, the show begins at the next picture. There is one slideshow at a time; starting another brings the running one forward.

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

### Export as video

**Tools > Export Slideshow Video…** (directly under Start Slideshow, no shortcut) makes a video file of the slideshow, to send or play elsewhere. It takes the pictures Start Slideshow would play, in the browser or the viewer, and leaves videos out.

The **Export Slideshow Video** sheet has two sections:

- **Video:** **Resolution** (720p, 1080p, 4K, or **Screen size**, the pixel size of the screen the window is on), **Frame rate** (24, 30 or 60 fps), **Codec** (H.264, or HEVC (H.265), which makes smaller files), **Quality** (Low, Medium or High) and **File** (MPEG-4 (.mp4) or QuickTime (.mov)). It starts at 1080p, 30 fps, H.264, Medium and .mp4, and remembers your choices.
- **Slideshow:** three lines saying what the video plays with, taken from **Settings > Slideshow**: the slide time and transition, the order and captions, and the music. **Slideshow Settings…** opens that pane; the lines follow any change. The video has no settings of its own for these, so a show and its video always agree.

The bottom line gives the number of pictures, the length and the size, for example `12 pictures · 1:05 · 1920 × 1080`. **Export…** asks where to save, starting with the name `<folder> Slideshow.mp4`; only folders on this Mac's internal storage can be chosen. Cancel in the save panel goes back to the sheet. A progress sheet with a percentage and **Cancel** follows; Cancel leaves no file. Nothing opens afterwards.

What the video shows: each picture once, in the slideshow's order (Shuffled shuffles once; **Start again after the last slide** doesn't apply). The first picture fades in from black and the last fades out to black. Transitions and captions are as set in Settings, and play as chosen even with Reduce Motion on, since the video is made for other screens. The music, when **Play music** is on, is laid end to end under the whole video, faded in and out, as AAC sound; the Volume slider isn't applied to the file. Nothing is played aloud while exporting. The video is SDR: HDR photos look as they would on a standard display. There is no zoom or pan effect.

## Batch Convert

**Tools > Batch Convert…** (⌥⌘B) saves converted copies of the images. The originals are never changed unless you choose to replace them and confirm. The sheet's title says how many images it will convert, and the line at the bottom shows the first file's new name (`IMG_0001.NEF → IMG_0001.jpg`), with anything in the way in red below it.

The sheet's sections come in this order: **Preset**, **Format**, **Pages**, **Edits**, **Size and Orientation**, **Destination** and **File Names**.

**Preset.** A preset is a named set of the sheet's choices, kept for next time. The popup lists **None** and the presets by name. The **…** menu beside it has **Save Preset…** (a preset keeps the edits and every option of the sheet; a name already used replaces that preset), **Rename Preset…** and **Delete Preset…** (asks first; images already converted aren't affected). Choosing a preset saved here brings back every option. Choosing one made in the viewer with **File > Save Edits as Preset…** (see [Editing](Editing)) replaces only the edits. **None** clears the edits and leaves the rest. Changing an option afterwards doesn't change the preset until you save it again.

**Format.** The formats Save As writes, with the same options. A format you haven't picked yet in the sheet starts from what Save As last used for it. AVIF is listed only where macOS can write it.

| Format | Extension | Quality | Colour profile | 16 bits | Metadata |
|---|---|---|---|---|---|
| JPEG | `.jpg` | 1–100 (90) | yes | | yes |
| PNG | `.png` | | yes | yes | yes |
| HEIC | `.heic` | 1–100 (80) | yes | | yes |
| AVIF | `.avif` | 1–100 (80) | yes | 10 bits | yes |
| TIFF | `.tif` | | yes | yes | yes |
| BMP | `.bmp` | | sRGB | | |
| GIF | `.gif` | | sRGB | | |
| TGA | `.tga` | | sRGB | | |
| JPEG 2000 | `.jp2` | 1–100 (90) | yes | | |
| ICO | `.ico` | | sRGB | | |

- **Color profile:** **Keep original** (the default), **sRGB**, **Display P3** or **Adobe RGB (1998)**. Formats that can't hold a profile are always converted to sRGB.
- **Compression** (TIFF): **None**, **LZW** (the default) or **PackBits**, all lossless.
- **Background for transparency** (JPEG and BMP, which have none): white by default.
- **Progressive** (JPEG), off by default. **16 bits per channel** (PNG and TIFF; **10 bits per channel** for AVIF), off by default.
- **Keep HDR** (JPEG, HEIC and AVIF), on by default. HDR photos keep their highlights, written with a gain map (extra data that tells an HDR screen how much brighter each part may be shown). A gain map needs **Keep original** or **Display P3** and 8 bits: with sRGB or Adobe RGB chosen, or 10 bits, HDR photos are written SDR, and a line under the switch says so. A PQ or HLG original becomes a gain-map file. Off, HDR photos are tone mapped to SDR. RAW files are always written SDR.
- **Keep metadata (EXIF, GPS, IPTC, XMP)**, on by default where the format can carry it. The orientation is reset, since the pixels are written upright.
- **Remove location**, under Keep metadata and on by default: leaves out the GPS position and the IPTC place names and keeps the rest. An original replaced by its own conversion keeps its location, whatever the switch says.

**Pages.** **Multi-page files:** **First page only** (the default) converts the first page of a PDF or multi-page TIFF and the first frame of an animation. **Every page** writes all the pages into one file for TIFF (pages) and GIF (frames, keeping the original's timing and loop count), and one numbered file per page for every other format; the line under it says which. Multi-page outputs carry no metadata, because their pages can come from different files.

**Edits.** The steps the batch applies to every image, from a preset, each with its note (Auto Enhance is measured again on each photo; Crop and Perspective take the same part of each photo; RAW Adjustments applies to RAW files only). The minus button leaves a step out of this batch. "None" when there are none. Then **Watermark**: a summary of the watermark, with **Add…** or **Edit…** and **Remove**. Add and Edit open the viewer's watermark controls in a sheet of their own (see [Editing](Editing)), without a preview, since no photo is open. Edits are applied first, then the turn, the flip and the resize below; the watermark is stamped last, at the converted size, so it covers the same share of every photo.

**Size and Orientation.**

- **Resize:** **Don't Resize** (the default), **Long Side**, **Width**, **Height** (1 to 32,768 pixels; 2048 to start) or **Percentage** (above 0 up to 1000%; 50 to start). Proportions are always kept.
- **Resampling:** any of the eleven filters of **Image > Resize/Resample…**; **Lanczos 3** by default. See [Editing](Editing).
- **Don't enlarge smaller images**, on by default: a picture already smaller than asked keeps its size.
- **Rotate:** **None**, **90° Right**, **180°** or **90° Left**. **Flip:** **Horizontal**, **Vertical**.

Turning and flipping happen before the resize, so a width means the width of the picture as it comes out. RAW files are rendered as **Settings > Viewer > RAW files** says, one at a time. Converted files are SDR unless **Keep HDR** applies.

**Destination.** **Save to** **Beside the originals** (the default) or a folder you choose with **Choose…**. The folder must be on the Mac's internal storage. It is remembered, and if it has gone by next time the sheet goes back to beside the originals.

**File Names.** **Keep the original names** (with the new extension), or **Use a pattern**, with the same pattern controls as Batch Rename below. Batch Convert remembers its own pattern, separately from Batch Rename's. `{ext}` is the original extension; the new format's extension is added after it. Here **Insert Token** also offers `{page}` (or `{frame}`): the page or frame number, from 1, zero-padded to the file's page count. A page written without `{page}` in the pattern gets its number after its name (`scan-03.jpg`), so two pages never ask for one name. A page never replaces its own original: it is numbered instead, even under Replace.

**If a file exists.** Every name is settled before anything is written:

- Two converted files never share a name, and a converted file never lands on another image of the batch. Either way the converted file is numbered (`photo 2.jpg`), whatever the setting.
- A file already in the destination follows **If a file exists**: **Skip**, **Keep Both** (the default: the new file is numbered) or **Replace (Move Old to Trash)**. A folder of that name is never replaced.
- With **Replace**, minivu first asks once, naming what would go to the Trash: originals that their own conversions would replace (a JPEG converted to JPEG beside the originals with the names kept), and up to three existing files that aren't part of the batch. The answers are **Replace**, **Keep Both** (numbered names, for this run only) and **Cancel**, which is the default, so Return never replaces anything.
- An original replaced by its own conversion keeps its stars, tag and Custom Order place. Any other replaced file takes its marks to the Trash with it.

Each file is written in full under a hidden name before it takes its real one, so nothing is ever half written, and a replaced file goes to the Trash only once the new one is complete.

**Running.** **Convert** remembers the sheet's settings and starts. A progress sheet shows the count, the file in hand and **Cancel**. Two files convert at a time (one on a Mac with 8 GB of memory or less), and never more than one camera RAW at once. **Cancel** starts no new files and drops any conversion that finishes afterwards; a write already queued completes, so only whole files are left. When it is done, converted files in the folder you are looking at are selected. If anything was skipped or failed, an alert lists up to eight of each, with the reason. Before decoding, each file is checked against the memory minivu allows for one export, including how large the edits, a frame or a shadow would make it; a file over the limit is skipped and named.

## Batch Rename

**Tools > Batch Rename…** (⇧F2, beside Rename's F2) renames the images from a pattern. The sheet shows a live Before and After list and renames nothing until you press **Rename**.

**Preset.** The same Preset row as Batch Convert, above the pattern. A rename preset keeps the pattern, the counter, find and replace, and the letter cases. **None** leaves the pattern as it is.

**Pattern.** Text with tokens. Type them, in any letter case, or pick them from **Insert Token**, which adds one at the end. Videos are renamed like any other file.

| Token | Becomes |
|---|---|
| `{name}` | The original name without its extension |
| `{#}`, `{###}` | The counter; each `#` is a digit, zero-padded |
| `{date}` | The date taken (EXIF DateTimeOriginal, else DateTimeDigitized; for a video, when recording began), else the file's modification date; `yyyy-MM-dd` |
| `{date:yyyy-MM-dd HH.mm.ss}` | The same, in a format of your own |
| `{modified}`, `{modified:HH.mm}` | The modification date, with an optional format |
| `{width}`, `{height}` | The picture's or video's pixel size as displayed (orientation applied) |
| `{ext}` | The original extension, without the dot |

Date formats are Unicode date patterns. Names come out the same on every Mac, whatever its region or calendar, and a date taken is written on the camera's clock when the file records its time zone. The date taken and pixel size are read from the files only when the pattern uses them. A token minivu doesn't know, such as `{nmae}`, stays in the name as typed and blocks **Rename** until it is fixed. `{page}` counts as unknown here, because Batch Rename renames whole files.

**Counter.** **start** and **step** (1 and 1 to begin with), and a minimum number of **digits** from 1 to 9. The larger of that and the token's own `#`s wins, so `{#}` with 4 digits gives `0001`.

**Replace.** Plain text (not a regular expression) replaced everywhere in the name the tokens made, with or without **Match case**.

**Letter case.** For the name: **Unchanged**, **lowercase**, **UPPERCASE** or **Title Case**. For the extension: **Unchanged**, **lowercase** or **UPPERCASE**.

Names are made in that order: tokens, then find and replace, then the name's letter case; the extension goes on last, in its own case. The counter follows the order of the list, which is the grid's order.

**Checking.** The line under the list says how many files will be renamed, or the first problem: two files would get one name, a name belongs to an item that isn't being renamed, a file can't be found any more, or a name isn't allowed (empty, a `/` or `:`, a leading dot, too long). Names are compared as the disk compares them, so `IMG.JPG` and `img.jpg` clash on an ordinary case-insensitive volume. Problem rows are marked in the list. **Rename** is available only when every name works. A name held by another file of the same batch is fine: swaps (`a.jpg` ↔ `b.jpg`) and chains work, and so does a rename that only changes letter case.

**Undo.** The whole rename is one step, **Edit > Undo Rename 12 Items** (⌘Z), and redo puts it back. Stars, tags and Custom Order places follow the files. The pattern is remembered for next time. Renames run one at a time across every window (and the Rename Images action in Shortcuts), so two never meet in one folder.

## Extract Pages

**Tools > Extract Pages…** writes each page of a PDF or multi-page TIFF, or each frame of an animation (GIF, animated PNG, WebP, animated HEIC), as a file of its own. It opens the Batch Convert sheet in its Extract Pages mode, titled for example "Extract Pages from 3 Files", with an **Extract** button. There is no Preset row and no Edits section. The **Pages** section has **All pages** (the default) or **A range**, **From** and **to**, counted from 1.

Everything else works as in Batch Convert: any of its formats and options (PNG to start), resize, turn and flip, destination, **If a file exists** and names. Names start as the pattern `{name}-{page}`, so a 12-page `scan.pdf` gives `scan-01.png`, `scan-02.png` and so on. Files with only one page are skipped, as are files shorter than the range's start, and the summary names them. Extract Pages remembers its own settings and pattern, apart from Batch Convert's. A PDF page is rendered as the viewer renders it at full resolution (at least 4096 px on the long edge); the pictures inside a PDF are not taken out as they are.

## Find Duplicates

**Tools > Find Duplicates…** finds copies of the same photo, so you can keep one and move the others to the Trash. It opens one **Find Duplicates** window; asking again brings it forward, pointed at what the browser shows now.

- **Look in:** **Selected Images (N)** (the default when images are selected), the folder shown (without its subfolders; **Images Shown** for a list such as search results or a collection), or the folder **and Subfolders**.
- **Find:** **Identical Files** (exactly the same bytes, found by comparing a fingerprint of each file's content) or **Similar Images** (pictures that look alike: resized or re-encoded copies, light edits, bursts). Similar Images uses Apple's Vision framework on this Mac to describe each picture, and nothing is sent anywhere. It leaves videos out; Identical Files includes them.

Return or **Find** starts. A progress bar says what it is doing, and **Stop** (Esc) shows the groups among what was compared so far, with a note that it stopped early.

The results are groups, headed for example "3 identical files, 4.2 MB each" or "4 similar images". Each file has a checkbox, its thumbnail, name, folder (the full path when you hover), pixel size, file size and date modified. The **Similarity** slider (Similar Images only) runs from **Stricter** to **Looser**; the groups change as it moves, without looking at the pictures again.

- **Keep:** **Highest Resolution** (the default), **Largest File** or **Oldest**. The file this rule suggests keeping has a **Keep** badge.
- **Mark Suggested** ticks every file except each group's suggested keeper. **Clear Marks** unticks everything, and the checkboxes tick single files. Nothing is ticked unless you do one of these. The footer says how many files are marked and their total size.
- **Move to Trash…** asks first, and warns when every file of a group is marked, so no copy would be left. The files go to the Trash, from where Finder can put them back.
- **Show in Browser** shows the selected files, or every file found, as a list in the browser titled "Duplicates" or "Similar Images", where every browser command works. **Compare** opens 2 to 4 selected files in the Compare window.

The fingerprints are kept in minivu's thumbnail cache, so a second search of the same files is fast; **Clear Thumbnail Cache** in Settings empties them too. One similar search compares at most 20,000 images (10,000 on a Mac with 8 GB of memory or less) and says so when it stops there. Differences smaller than a 256-pixel copy shows, such as a dust spot, aren't seen by Similar Images.

## Create Multi-Page File

**Tools > Create Multi-Page File…** joins the images into one file with several pages, or into an animation.

**Pages.** The images as a numbered list, in the browser's order to start. A file that has several pages says so ("12 pages", or "12 frames" for an animation). Drag rows to reorder them, or use **Move Up**, **Move Down** and **Reverse**. **Include every page of multi-page files** (on to start) puts in every page of a PDF or multi-page TIFF and every frame of an animation; off, only the first.

**Format:**

| Format | Options |
|---|---|
| **Multi-Page TIFF** (the default) | **Compression**: None, LZW (the default) or PackBits. Each page keeps its size and colour profile. |
| **PDF** | **Page size**: **Same as Each Image** (the default), A4 or US Letter; **Margin** in points for paper (36 to start; 72 points is an inch); **Lossless (larger file)**, off to start; **Quality** (85% to start) when not lossless. |
| **Animated GIF** | **Frame delay** in seconds (0.5 to start); **Play**: **Forever** (the default) or a number of times; **Frame size**: the long side in pixels (800 to start) or **Same as the first image**; **Background**: **Transparent** or a colour. |
| **Animated HEIC** | As GIF but without **Play**, plus **Quality** (80% to start). Listed only where macOS can write it. Animated HEIC files play once, and the last frame shows as long as the one before it. |

In an animation every frame is fitted into one size and centred; frames that come from an animation keep their own timing. The line by the buttons gives the page count, or in red why the file can't be made, such as a setting out of range or an animation too large for memory. **Save…** asks for the file (the first image's name, in the folder shown), then makes it with a progress sheet and **Cancel**. The new file is selected when it is in the folder shown. Pages that couldn't be read are left out and listed afterwards.

The file carries no metadata, because its pages come from different files, and it is SDR. There is no animated AVIF, because macOS can't write one.

## Image Strip

**Tools > Image Strip…** joins the images into one picture, side by side or in a grid, and opens it in the viewer.

- The same order list as Create Multi-Page File.
- **Arrange:** **Side by Side** (the default; every picture scaled to the same height), **One Above Another** (the same width) or **Grid** (each picture fitted and centred in its cell; cells take the pictures' middle shape), with **Columns** (3 to start).
- **Height**, **Width** or **Cell height** in pixels, 1080 to start.
- **Spacing** and **Margin** in pixels, 0 to start.
- **Background:** white to start, another colour, or **Transparent** where the format keeps it.
- **File:** any format Save As writes except ICO (JPEG to start), with Quality, Color profile, TIFF compression and 16 or 10 bits as in Save As.

The line by the buttons shows the strip's size, for example "5,120 × 1,080 pixels", or why it can't be made: a strip can be at most 32,768 px on a side. **Save…** asks for the file (the first name plus " Strip"), makes it with a progress sheet and **Cancel**, selects it and opens it in the viewer, where it can be edited like any photo. HDR photos come out SDR.

## Print and Page Setup

**File > Print…** (⌘P) prints the images with a layout; **File > Page Setup…** (⇧⌘P) chooses the printer, paper, orientation and scale. In the browser, Print uses the selected images, or every image shown, leaving videos out; in the viewer, the image and page shown (greyed out for a video). With unsaved edits in the viewer, it prints the edited picture on screen, not the file.

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

**Tools > Contact Sheet…** lays the images out on pages (videos left out), with a preview of page 1 and a summary such as `24 images · 2 pages · 2480 × 3508 px`. Everything but the header text is remembered; the header starts as the folder's name each time.

**Page.**

- **Size:** **A4 at 300 dpi** (2480 × 3508 px, the default), **US Letter at 300 dpi** (2550 × 3300), **4K Display** (3840 × 2160), or **Custom**, 256 to 16,384 px a side (3000 × 2000 to start).
- **Orientation:** **Portrait** (default) or **Landscape**. Every preset is turned to the orientation chosen, so 4K Display in Portrait makes a 2160 × 3840 page; choose **Landscape** for a screen-shaped 4K page. A custom size is taken as typed.
- **Background:** white by default.

**Grid.** **Columns** 1 to 20 (4); **Rows** 0 to 30 (5), where 0 is **Auto (one page)**; **Spacing** 0 to 400 px (40); **Margin** 0 to 800 px (120); **Pictures** **Fit in Cell** (default) or **Fill Cell**.

**Text.** **Captions:** **None**, **Name** (default), **Name and Dimensions** or **Name and Date**. **Text size** 8 to 200 px (36); the header is set larger. **Header**, on by default, with its text. **Page numbers** ("Page 2 of 5"), on by default.

**File.** **Format:** **JPEG** (default, quality 90), **PNG**, **TIFF** or **PDF**. **Color profile:** **sRGB** (default) or **Display P3**, for the picture formats. A PDF holds every page, with A4 and Letter pages at their paper size, and pictures embedded at the size of their cells.

**Save…** asks where. A PDF, or a sheet of one page, gets a save panel with a name made from the header text (`Trip Contact Sheet.pdf`; plain `Contact Sheet` without any), and the panel asks before replacing a file. Several picture pages go into a folder you choose, as `Trip Contact Sheet 1.jpg`, `Trip Contact Sheet 2.jpg` and so on; if any of those names is taken, the whole set is numbered again (`Trip Contact Sheet 2 1.jpg`), so nothing is replaced. Cancelling the panel goes back to the dialog as you left it.

Pages are made on the same disk and moved into place only when all of them are finished. A progress sheet with **Cancel** appears for a large sheet, or when a small one takes more than a moment. A cancelled or failed sheet leaves nothing in the destination. The finished sheet opens in the viewer.

## Web Gallery

**Tools > Create Web Gallery…** makes a small website of the images: a folder you can open from disk in any web browser, copy to a USB stick or put on a web server. It needs nothing from the internet. Videos are left out.

The **Create Web Gallery** sheet:

- **Title:** the folder's name to start. It heads the gallery and names its folder.
- **Pictures:** **Thumbnails** (64 to 512, 200 to start; the size the reader sees, written at twice that for Retina screens), **Large pictures** (the long side, 320 to 8192 px, 1600 to start; smaller pictures keep their size) and **Include the original files** (off).
- **Layout:** **Columns** (0, which fits the window, to start; or 1 to 12), **Theme** (Light, Dark or Automatic, which follows the reader's light or dark setting) and **Order** (As Shown, Name, Date Taken or Date Modified).
- **Captions:** **File name** (on), **Title and caption from the metadata** (on) and **Date taken** (off).
- **File:** **Format** (JPEG, HEIC or AVIF, where macOS can write them; HEIC shows only in Safari, AVIF in current Safari, Chrome, Firefox and Edge), **Quality** (85% to start), **Keep metadata** (on) and **Remove location** (on).

Every choice but the title is remembered. **Create…** asks for the folder the gallery goes in; only folders on this Mac's internal storage can be chosen. The gallery is a new folder there, named after the title, or numbered ("Trip 2") if that name is taken, so nothing is ever replaced. A progress sheet with **Cancel** follows; Cancel leaves nothing behind. Pictures that can't be read are left out and listed afterwards. Nothing opens afterwards.

The folder holds `index.html` (the thumbnail grid), `style.css`, a page for each picture in `pages`, the large pictures in `images`, the thumbnails in `thumbnails`, and the originals in `originals` when included. Each picture's page has **Previous** and **Next** links and "3 of 24"; the pages use no JavaScript and link to nothing outside the gallery. Pictures are written in sRGB, so HDR photos look as on a standard display. Thumbnails carry no metadata. An included original has its location removed unless the large pictures keep it; an original it can't be removed from, such as a camera RAW, is left out, and an alert names it. Animated pictures become stills, and multi-page files give their first page. The page text ("Previous", "Next") is in English.

## Montage Wallpaper

**Tools > Montage Wallpaper…** makes a collage of the images (videos left out) at a display's size and sets it as that display's desktop picture. A montage uses at most 200 photos; with more, it takes the first 200 and the sheet says so.

- **Display:** each display, with its pixel size, and **All Displays** when there are several. It starts on the display the browser is on.
- **Layout:** **Grid** (uniform cells; each photo fills its cell and is cropped to it, with spare cells repeating photos), **Mosaic** (justified rows: each photo keeps its shape, cropped only by the few percent that make the rows fill the screen), or **Scattered** (tilted prints with white borders and soft shadows, overlapping a little). **Shuffle** scatters them another way.
- **Spacing:** 0 to 40 pt between photos and around the edge, 8 pt by default. It is measured in points, so it looks the same on Retina and standard displays.
- **Background:** a near-black grey by default.

The layout, spacing and background are remembered. The preview follows every change.

**Set as Wallpaper** draws the montage at the display's full pixel size, saves it as a JPEG in **Pictures/minivu Wallpapers** (`Montage 2026-09-14 at 10.30.05.jpg`, with ` (1)`, ` (2)` for each display of **All Displays**) and sets it as the desktop picture, scaled to fill. **Cancel** stops it; a cancelled or failed run deletes any montages it had already written. minivu never deletes montages that were set.

## Set as Desktop Picture

**Tools > Set as Desktop Picture** uses one image: the lead image of the browser's selection on the browser's display, or the viewer's image on the viewer's display. It is greyed out when that image is a video. The picture is scaled to fill the screen, keeping its shape and cropping what overflows.

macOS reopens a desktop picture's file later, and after every restart, so minivu uses the file itself only when it is a JPEG, PNG, HEIC or TIFF inside your Pictures folder and has no unsaved edits. Anything else (a RAW, a WebP, a photo outside Pictures, or the viewer's unsaved edits) is exported first as a copy in **Pictures/minivu Wallpapers**, named `Desktop 2026-09-14 at 10.30.05 IMG_0001.jpg` (HEIC when the picture has transparency), in SDR and no larger than twice the screen's long edge. minivu keeps the newest ten copies and removes older ones, but never one a display is showing; a copy set on another Space can still be removed while it is in use there.

## Capture

**Tools > Capture** has three commands, and no shortcuts, because macOS keeps ⇧⌘3 to ⇧⌘5 for its own screenshots:

- **Entire Screen** captures the whole display the pointer is on, at its full pixel size.
- **Window…** opens the system's window picker; the window you click is captured.
- **Selection…** dims every screen and shows a crosshair. Drag a rectangle, which shows its size in pixels; letting go captures it. A click without a drag, or a rectangle too small to use, clears the rectangle. Esc, or switching to another app, cancels.

minivu's own windows are left out of Entire Screen and Selection captures, and the pointer is never included. Each capture is saved as a PNG in **Pictures/minivu Captures**, named `Capture 2026-09-14 at 10.30.05.png`, and opens in the viewer.

**Permission.** Entire Screen and Selection need Screen Recording permission. The first time, macOS asks. If it has been refused, minivu explains instead and offers **Open System Settings**: turn minivu on in **System Settings > Privacy & Security > Screen & System Audio Recording**, then quit and reopen minivu. **Window…** needs no permission, because choosing a window in the system's picker is itself the consent.

Captures are 8-bit SDR, even on an HDR screen.

## Share

**File > Share…** offers the images to the system's share sheet: AirDrop, Messages, Mail, Notes and whatever else is installed. In the browser it is also in the grid's right-click menu, and the toolbar has a **Share** button. It shares the selected images, or the lead image with nothing selected; unlike the other tools it never falls back to every image in the folder, and folders in the selection are left out. In the viewer it shares the image shown. There is no shortcut.

The share sheet always gets the file as it is on disk, with its metadata, as Finder would share it. If the viewer's image has unsaved edits, minivu says so first ("The file is shared as it was last saved, without the edits made here"); **Share Saved File** goes ahead. To share the edits, save them first. minivu itself opens no network connection: each share service runs in its own process and reads the files the share sheet hands it.

## Live Text

In the viewer, text in a picture, such as a sign, a document or a screenshot, can be selected and copied, as in Preview. Move the pointer over the picture, then drag over the text. **Edit > Copy Text** (⇧⌘C) copies all the text found in the picture; with no text it beeps. **View > Live Text** turns the feature off or on (on to start). The text is read on this Mac and nothing is sent anywhere. Live Text isn't offered while an edit tool is open, while an animation plays, or for a video. See [Viewer](Viewer) for more.

## External editors

**Tools > Open in External Editor** lists the applications you have added, each with its icon, then **Edit Editor List…**, which opens **Settings > Editors**. The first editor in the list opens with ⌘E. The list starts empty; see [Settings](Settings) for adding, ordering and the suggestions of editors already installed.

**What opens.** In the browser, the selected images (videos included), or the lead image. Unlike the other tools, it never falls back to every image in the folder. Opening more than 20 images asks first, since each becomes a window or tab in the editor. In the viewer, the image shown. If it has unsaved edits, minivu says so first: the editor gets the file as last saved, and **Open Saved File** goes ahead. If an application has moved or been deleted, minivu says it can't be found and offers **Edit Editor List…**.

**When the editor saves.** minivu watches the files it sent, in the eight folders most recently sent to an editor. When one changes, the browser's thumbnail updates and the viewer shows the new version, keeping the zoom and position when the size hasn't changed. If you have unsaved edits of that image in the viewer, it asks: **Keep My Edits** (the default) or **Reload**, which shows the editor's version and discards yours. After keeping your edits, **Save** asks for a new name for the rest of that session, so neither version is lost.

## Shortcuts

minivu adds actions to Apple's Shortcuts app (search for "minivu" in its action library), so you can build your own automations:

| Action | Settings (starting value) |
|---|---|
| **Convert Images** | Format (JPEG; also HEIC, AVIF, PNG, TIFF, JPEG 2000, GIF, BMP, TGA, ICO); Quality 1–100 (90); Long Side in pixels (empty keeps the size; smaller images are never enlarged); Remove Location (on) |
| **Resize Images** | Resize By (Long Side, Width, Height or Percentage); Size (2048); Enlarge Smaller Images (off); Remove Location (on) |
| **Rename Images** | Pattern (`{date}-{###}`, with Batch Rename's tokens); Counter Starts At (1) |
| **Set Rating** | Rating 0–5 (5; 0 clears it) |
| **Set Colour Label** | Label (None, Red, Orange, Yellow, Green, Blue, Purple or Gray; Red to start) |
| **Open in minivu** | Images or Folder |

Convert and Resize never write beside the originals: they hand the new files back to the shortcut, whose next action (Save File, for example) puts them where you want. Rename works only in your Pictures folder and folders added to minivu's sidebar, and renames nothing if any file is elsewhere. Files on external drives, memory cards and network shares are refused, as everywhere in minivu. These actions take images only, not videos. Convert Images, Resize Images and Open in minivu are also offered as ready-made shortcuts under minivu in the Shortcuts app.

To use one from Finder, make a shortcut that receives images, turn on **Use as Quick Action** in the shortcut's details, and it appears under **Quick Actions** in Finder's right-click menu.

To run a shortcut from a script, type `shortcuts run "Shortcut Name" --input-path photo.jpg` in Terminal, or use Automator's **Run Shortcut** action. minivu has no AppleScript dictionary of its own.

## See also

- [Editing](Editing) for Save As, whose options Batch Convert shares, the resampling filters, the watermark and Save Edits as Preset.
- [Settings](Settings) for the Slideshow and Editors panes.
- [Viewer](Viewer) for Live Text and saving a video's frame.
- [Keyboard Shortcuts](Keyboard-Shortcuts) for every key.
- [Limitations](Limitations) for what these tools don't do.
