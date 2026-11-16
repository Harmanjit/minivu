# Tools

The **Tools** menu works on what you are looking at. In the browser, a tool
uses the selected images, or every image shown when nothing is selected. In
the viewer, it uses the image on screen. Tools that make pictures, and the
slideshow, skip videos.

## Slideshow

**Tools > Start Slideshow** plays the images full screen on the display the
window is on, with HDR as in the viewer. Starting from a single selected
image plays the whole folder from there.

- **Space** pauses and resumes, the arrow keys step, and **Esc** ends the
  show. Move the pointer to bring up the control bar.
- Choose the time per slide, the order (in order or shuffled), whether to
  start again at the end, captions, and one of eight transitions or a random
  one in **Settings > Slideshow**.
- Add music there too: MP3, AAC, WAV or AIFF songs, or folders of them. The
  music fades out when the show ends.

### Export as video

**Tools > Export Slideshow Video…** saves the slideshow as a video file, to
play or send anywhere.

- Choose the resolution (720p, 1080p, 4K or your screen’s size), the frame
  rate, the codec (H.264, or HEVC for smaller files), the quality, and MP4
  or MOV.
- The video uses the slide time, transition, order, captions and music set
  in **Settings > Slideshow**. Each picture appears once.
- The video is in standard dynamic range: HDR photos are tone mapped.
- Export… asks where to save it. A progress bar with Cancel follows.

## Batch Convert

**Tools > Batch Convert…** saves copies of many images in another format.

- Choose the format and its options, as in Save As, and a destination: a
  folder, or beside the originals. **Remove location** leaves the GPS
  position out of the copies; it starts turned on.
- Optionally rename the copies with a pattern, resize them (by long side,
  width, height or percent), rotate or flip them, and keep or strip their
  metadata.
- **Edits** lists the edits of the chosen preset, made in the viewer with
  **File > Save Edits as Preset…**, and applies them to every image.
  **Watermark** adds a watermark. See [Editing](help:Editing) and
  [Effects & Retouching](help:Effects).
- **Keep HDR** keeps HDR photos HDR in JPEG, HEIC and AVIF. It needs the
  color profile Keep original or Display P3, and 8 bits; otherwise HDR
  photos are written in standard dynamic range, and the sheet says so.
- **Preset** at the top keeps every choice under a name, to use again.
- The conversion runs in the background with a progress bar and Cancel, and
  lists any files that couldn’t be converted.
- minivu asks before anything would be replaced, and a replaced file goes to
  the Trash.

**Multi-page files** chooses what happens to PDFs, multi-page TIFFs and
animations: **First page only**, or **Every page**. Every page makes one
file with all the pages in TIFF and GIF, and one file per page in other
formats.

## Batch Rename

**Tools > Batch Rename…** renames many files at once from a pattern of text
and tokens: the original name, a counter, the date taken, the date modified,
the pixel size and the extension. Add find and replace and a letter case,
and check the live before-and-after list, which flags clashes before
anything changes. The whole rename is one step of **Edit > Undo**. A
**Preset** keeps a pattern under a name.

## Pages and strips

- **Tools > Extract Pages…** saves each page of a PDF or multi-page TIFF,
  or each frame of an animation, as a file of its own. Choose all pages or
  a range, and the format, as in Batch Convert. The names use the
  `{page}` token, the page number: “scan-03.png”.
- **Tools > Create Multi-Page File…** joins the images into one file: a
  multi-page TIFF, a PDF, an animated GIF or, where your Mac can write it,
  an animated HEIC. Drag the list to change the order.
- **Tools > Image Strip…** joins the images into one picture, side by side,
  one above another or in a grid, with the spacing and background you
  choose. The strip opens in the viewer.

## Find Duplicates

**Tools > Find Duplicates…** finds copies among the selected images, the
folder, or the folder and its subfolders.

- **Identical Files** finds files with exactly the same contents.
  **Similar Images** finds pictures that look alike, such as resized copies,
  edits and bursts. Move the **Similarity** slider to make it stricter or
  looser.
- In each group, minivu suggests one file to keep: the highest resolution,
  the largest file or the oldest, as you choose. **Mark Suggested** marks
  all the others; nothing is marked until you ask.
- **Move to Trash…** moves the marked files to the Trash, after asking.
  **Show in Browser** and **Compare** show the files found.

## Print and Page Setup

**File > Print…** uses the standard print panel with minivu’s layout
options: images per page, fit or fill, rotating pictures to fill the cells,
margins, spacing and captions, with a live preview. **File > Page Setup…**
chooses the paper.

## Contact Sheet

**Tools > Contact Sheet…** lays thumbnails out on pages: columns, rows,
spacing, captions, a header, the page size and background. Save it as JPEG,
PNG, TIFF or a multi-page PDF.

## Web Gallery

**Tools > Create Web Gallery…** makes a folder of web pages showing the
images: a page of thumbnails, and a page for each picture with Previous and
Next. Open its index.html in any web browser, from your Mac or after you
copy the folder to a website.

- Choose the title, the sizes of thumbnails and pictures, the columns, a
  light, dark or automatic theme, the order and the captions.
- Pictures are JPEG, HEIC (Safari only) or AVIF. Metadata can be kept, and
  **Remove location** starts turned on. **Include the original files** adds
  a download link for each original.
- The pages use no scripts and load nothing from the internet.

## Montage Wallpaper and Desktop Picture

- **Tools > Montage Wallpaper…** makes a collage of the images the size of
  your display, as a grid, a mosaic or scattered prints, and sets it as the
  desktop picture. Montages are saved in **Pictures/minivu Wallpapers**.
- **Tools > Set as Desktop Picture** uses one image as it is.

## Capture

**Tools > Capture** takes a picture of the entire screen, a window or a
selection you drag (**Return** captures, **Esc** cancels). Captures are
saved as PNG files in **Pictures/minivu Captures** and open in the viewer.

Capturing the entire screen or a selection needs Screen Recording
permission. macOS asks the first time; you can change it later in **System
Settings > Privacy & Security > Screen & System Audio Recording**. Picking a
window in the system’s window picker needs no permission.

## External Editors

**Tools > Open in External Editor** sends the selected images, or the image
shown, to another app. The first editor in the list is **⌘E**. Choose
**Edit Editor List…** to add apps in **Settings > Editors**.

When an editor saves a file, minivu shows the new version. If you had
unsaved edits of that file in minivu, it asks whether to keep them or reload.

## Shortcuts

minivu adds actions to the Shortcuts app: **Convert Images**, **Resize
Images**, **Rename Images**, **Set Rating**, **Set Colour Label** and **Open
in minivu**. Search for “minivu” in the Shortcuts app’s actions to use them
in your own shortcuts. Running such a shortcut opens minivu if it isn’t
open. The actions work only on files on your Mac’s internal storage.
