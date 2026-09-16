# Viewer

Double-click a thumbnail, press Return, or choose **File > Open in Viewer** (⌘↓) to open an image in the viewer. It steps through the images the browser shows, in the browser's order and with its filter. Press Esc, press ⌘W or double-click the image to go back; the browser then selects the image you were looking at.

There is one viewer at a time. Opening another image from the browser while it is open reuses it.

## Window and full screen

**Open viewer in full screen** in **Settings > General** (on by default) decides how the viewer opens. Return switches between the two, as do the control bar's full-screen button and **View > Enter Full Screen** (⌃⌘F). Zoom and the point at the centre of the view carry over.

**Full screen** is minivu's own, not macOS full screen: a borderless window exactly the size of the display. It appears at once, with no animation and no new Space. While it is the key window the Dock is hidden and the menu bar hides until you move the pointer to the top of the screen; switch to another app, or to the browser on another display, and both come back. Other apps' windows come in front of it as usual. The pointer hides after two seconds without moving, unless a panel the pointer opened is out.

**Windowed**, the viewer first opens centred, three-quarters as wide and 80% as tall as the display's usable area, and remembers its size and place after that. The title is the file name and the subtitle the position ("3 of 120"). It can't be made smaller than 640 × 400 points, the width the control bar needs.

**Background** in **Settings > Viewer** sets the surround: **Black** (the default), **Dark gray**, **Gray** or **White**. A window's title bar takes the same colour. Transparent parts of an image are drawn over a grey checkerboard.

## Choosing the display

**Full-screen viewer opens on** in **Settings > Viewer** has two choices:

| Starting from | **The display with the browser** (default) | **Another display** |
|---|---|---|
| The browser | The browser's display | The next display after the browser's |
| A windowed viewer going full screen | The display the window is on | The window's display, if it isn't the browser's; otherwise the next one |
| One display connected | That display | That display |

"Next" means left to right, and top to bottom where displays are stacked, which is how they sit on the desk rather than the order macOS lists them. Slideshows follow the same rule, so a slideshow started from a full-screen viewer plays over it.

**Window > Move to Next Display** (⌃⌥⌘→) moves the viewer, or a slideshow, to the next display, wrapping round after the last. In full screen it covers the next display; a window keeps its relative place on the new display's usable area, and shrinks only if it wouldn't fit. The item is disabled with one display.

A full-screen viewer remembers which display it covers. When that display changes resolution it keeps covering it; when it is unplugged, the viewer moves to a remaining display, chosen as when the viewer opens.

Two-display behaviour is covered by automated tests with simulated displays only.

## Notched displays

On a display with a camera housing, the full-screen viewer fits the image below it. The strip beside the camera stays black whatever the background, the overlay and the filmstrip sit below it, and moving the pointer anywhere into the strip opens the filmstrip. Slideshows do the same.

## Zoom and pan

| Do this | To |
|---|---|
| Click | Switch between fitting the view and actual size, at the point you clicked |
| Double-click | Go back to the browser |
| Press and hold (a quarter of a second) | Show the magnifier |
| Drag | Pan, when the image is larger than the view (the pointer is an open hand) |
| + or =, − | Zoom in or out one step |
| / | Actual size |
| * | Fit |
| Arrow keys, when the image is larger than the view | Pan by a tenth of the view |

The **Image** menu has **Fit to Window** (⌘9), **Actual Size** (⌘0), **Zoom In** (⌘=) and **Zoom Out** (⌘-).

Zoom steps are 5, 10, 25, 33.3, 50, 66.7, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400 and 3200%. Pinching and the wheel zoom freely between them. The deepest zoom is 3200%; the smallest is 2%, or the fitted size if that is smaller.

- **Fit** shows the whole image and follows the window as it resizes. An image smaller than the view is shown at actual size, unless **Enlarge small images to fit** (**Settings > Viewer**, off by default) is on. Any other zoom keeps the point at the centre where it is when the window changes size.
- Every new image starts fitted.
- **Pixelated zoom above 200%** (on by default) draws each pixel as a sharp square once it covers more than two screen pixels. Off, the image is smoothed at every zoom.
- Images are decoded at the size they are shown. Zoom in past that and the full-resolution image decodes in the background and takes over with your zoom and pan kept.
- An image larger than 16384 pixels on a side, Metal's texture limit, is shown scaled down to fit it.

## Mouse wheel and trackpad

**Mouse wheel** in **Settings > Viewer** is **Previous / next image** (the default) or **Zoom in / out**. Hold ⌘ while scrolling for the other.

- **A mouse wheel** moves one image per notch, however fast you spin it. Rolling it towards you is always the next image (or zoom out), with or without natural scrolling. Zoom goes 1.25× per notch, about the pointer.
- **A trackpad's two-finger scroll** moves one image per swipe when the whole image fits the view, and the rest of that swipe, momentum included, does nothing more. When the image is larger than the view it pans instead, momentum included. Set to zoom, scrolling zooms, doubling for every 100 points of travel.
- **Pinch** zooms about the pointer. **Smart zoom** (a two-finger double tap) switches between fit and actual size.
- While an edit tool is open, scrolling never changes the image: a mouse wheel zooms and a trackpad pans.

## Magnifier

Press and hold on the image to show a round loupe that follows the pointer until you let go. It asks for the full-resolution image when the decode on screen isn't sharp enough for it.

**Settings > Magnifier** sets its **Zoom** (1.5× to 8×, default 2×, relative to actual size) and **Size** (the radius, 60 to 300 points, default 140), with a preview at one-third size. The loupe always magnifies at least twice the current zoom, so it still helps when you are already zoomed in, and never goes past 3200%.

Scrolling while you hold changes the loupe's zoom in steps of 1.25×, from 1.5× to 16×, and keeps it as the new setting.

## Moving through the folder

| Keys | Go to |
|---|---|
| → ↓ Space | Next image |
| ← ↑ ⌫ | Previous image |
| Home, End | First or last image |
| Page Down, Page Up | Next or previous page of a document, then the next or previous image |

While the image is larger than the view, the arrow keys pan it instead (see above); Space, ⌫, Home, End and the paging keys still move through the folder.

The **Go** menu has **Next Image**, **Previous Image**, **First Image** and **Last Image**. A click on the filmstrip jumps to that image.

At either end of the folder the overlay flashes its position instead of doing nothing. Turn on **Wrap around at end of folder** in **Settings > General** to go round from the last image to the first. If the image has unsaved edits, minivu asks about them before moving on; see [Editing](Editing).

**Speed.** The image on screen stays up until the next one is ready, so there is no black flash. If the next one isn't decoded within 150 ms, any smaller copy already in memory (the browser's preview, say) stands in until it is. Once an image shows, the next two in the direction you are travelling and one behind start decoding at screen size, and for a document its next page first. Measured on an M1 Pro MacBook Pro: moving to the next or previous image takes 9–17 ms; a 24 MP JPEG decodes for the screen in about 43 ms and 32 MB, since it is decoded at the size shown; opening the viewer holds up the app for about 25–45 ms.

### Stars, tags and files

- **0** to **5** rate the image shown (0 clears), and **T** or **`** tags or untags it. **Image > Rating** (⌃0 to ⌃5) and **Image > Tag** (⌘T, shown as **Remove Tag** when the image is tagged) do the same. Stars and tags are kept in minivu's catalog; see [Browser](Browser).
- **File > Move to Trash** (⌘⌫) moves the image to the Trash and shows the next one, or the previous one if it was the last; the viewer closes when none are left. The ⌫ key on its own goes to the previous image and never deletes anything.
- **File > Reveal in Finder** (⌥⌘R) shows the file in Finder.
- **Tools > Start Slideshow** (⇧⌘F) plays the viewer's images from the one shown; see [Tools](Tools).

## The overlay

A small overlay in the top-left corner shows:

- the file name, and the stars and tag when the image has either;
- the position, page, pixel size and zoom, for example "3 / 120 · Page 2 of 10 · 6000 × 4000 · 25%";
- for photos, the exposure: "1/250 s  f/2.8  ISO 400  35 mm", leaving out what the file doesn't record;
- "Edited · Undo Crop" in orange while the image has unsaved edits.

It appears whenever the image, page, zoom, rating or tag changes, and fades after 1.5 seconds. Press **I** to keep it up, and **I** again to let it fade. It sits below the title bar or camera housing, and moves aside for a filmstrip or tools panel kept open.

## Panels at the edges

Move the pointer to an edge of the viewer, within 4 points of it, and a panel slides in. In a window the edges are those of the image area below the title bar. In a corner the nearer edge wins, and top and bottom win a tie.

| Edge | Panel | Keep it open with |
|---|---|---|
| Top | Filmstrip | **F** |
| Left | Edit tools | The control bar's **Show Edit Tools** button, or opening a tool |
| Right | Histogram and file information | The control bar's **Show Info** button, **Image > Histogram** (⇧⌘H) or **Image > Count Colors** |
| Bottom | Control bar | Pointer only |

A panel the pointer opened stays while the pointer is over it, and closes when the pointer leaves it or the window, or when you press on the image, so panels never sit over the magnifier. A panel kept open stays until you close it the same way. Side panels fit below a filmstrip that is kept open, and a tools panel kept open takes its width from the image, so fitting still shows the whole image beside it. With **Reduce Motion** on, panels fade in and out where they stand instead of sliding; see [Accessibility](Accessibility).

Panels build their controls the first time they open, and the filmstrip, histogram and file information do no work while hidden.

### Filmstrip

Thumbnails of the viewer's images, with the one on screen highlighted. Click one to jump to it; a mouse wheel scrolls the strip sideways. The thumbnails come from the same cache as the browser's, so a folder you have already browsed shows its strip at once.

### Edit tools

The tools in four groups: **Adjust** (Resize, Crop, Rotate & Flip, Straighten, Lighting, Colors, Curves, Levels, Sharpen, Blur), **Effects** (Color Effects, Drop Shadow, Frame, Bump Map, Sketch, Oil Painting, Lens), **Draw** (Text and Shapes) and **Retouch** (Clone Stamp, Healing Brush, Red-Eye Removal). Opening a tool replaces the list with its settings and keeps the panel open; Return applies it and Esc closes it. The tools are disabled until the image has loaded, and for animations. [Editing](Editing) describes each one.

### Histogram and information

The **Histogram** at the top of the right panel plots RGB together or **R**, **G**, **B** or **Luminance** alone; the choice is remembered. Two warnings light when more than 0.1% of the pixels sit in the darkest or the brightest of its 256 levels, in the colour of the channels that clip. Hover over the plot for the level and pixel counts under the pointer. For an HDR photo it also says what share of the pixels is brighter than SDR white.

It measures what is on screen, including an edit in progress, from a reduced copy about 1024 pixels on its long edge. While you drag an edit slider it updates at most ten times a second, and once a second while an animation plays.

**Unique colors** has a **Count** button. The count is of the file as saved, not of unsaved edits, and is remembered for the file, until it changes, while minivu is running.

Below it, the file information: **File**, **Image**, **Camera**, **Exposure**, **Dates**, **GPS** and **Description**, whichever the file has. Values can be selected and copied. They are read in the background, so moving through a folder with the panel open doesn't wait for the disk.

### Control bar

From left to right: **Previous Image** and **Next Image**; for documents, previous and next page with "2 / 10" between them; for animations, **Play** or **Pause**; **Fit to Window** and **Actual Size**; **Zoom Out**, the zoom, **Zoom In**; **Rotate Left** and **Rotate Right**; **Start Slideshow** and **Show Edit Tools**; **Show Info** and the full-screen button. In a narrow window the rotate, slideshow and tools buttons give way first; the menus still have them.

## Documents

PDFs and multi-page TIFFs open on their first page.

- **Go > Next Page** and **Previous Page** (⌥→ and ⌥←, or ⌥Page Down and ⌥Page Up) move between the pages of the file only.
- **Page Down** and **Page Up** go through the pages first, then on to the next or previous image, which opens on its first page.
- The overlay shows "Page 2 of 10", and flashes at the first or last page.

PDF pages are drawn on white. A page's actual size is two pixels per point, the size it would have on a Retina screen, and it is rendered at the size shown; zooming in renders it again, sharper, at least 4096 pixels on its long edge (but no more than 32 times its actual size, and never past 16384). SVG files are rendered the same way, with their own size in points as the starting point, but on a transparent background, so the checkerboard shows through.

An edit belongs to one page, so turning the page asks about unsaved edits first.

## Animations

Animated GIF, PNG (APNG), WebP and HEIC image sequences play on their own, with the file's own frame timing and number of loops. A frame delay of 10 ms or less, which old tools wrote for "as fast as possible", is shown for 100 ms, as web browsers do.

- **P**, **Image > Play Animation** or **Pause Animation**, or the control bar's button plays and pauses. While paused, the overlay shows the frame: "Frame 3 / 24".
- The animation stops its clock while its window can't be seen: minimised, hidden, covered, or on another Space.
- Frames are decoded at the size the animation is shown when fitted; zoom in and the next frames decode larger, zoom back to fit and they go back.
- Animations are always shown in SDR, and can't be edited.

## Colour

Every image is colour managed. Its embedded ICC profile is honoured, and ColorSync converts it once, when it is decoded:

- 8-bit images go into Display P3.
- 16-bit images, images in colour spaces wider than Display P3, and HDR images go into extended linear Display P3 at half-float precision, so colours outside P3 and highlights above white survive.

The canvas itself is extended linear Display P3, and macOS converts it for whichever display the window is on, so moving between displays with different gamuts needs no new decode. Zoomed-out views are filtered in linear light, which keeps downscaled views correct.

## HDR

minivu recognises HDR photos by their content: a gain map (Apple's, ISO 21496-1 or Ultra HDR), or PQ or HLG encoding, as in HDR HEIC and AVIF files from phones and cameras. RAW files can be shown in HDR too; see below.

With **Display HDR photos in HDR** on (**Settings > Viewer**, the default), their highlights show brighter than white on HDR screens: the Liquid Retina XDR display of a MacBook Pro, Pro Display XDR, and external displays with HDR turned on.

- minivu asks macOS for extended dynamic range only while an HDR photo is on a screen that can show some of it, because it raises the backlight and costs power. The image brightens over a second or two as the system raises it.
- The screen's headroom (how far above white it can go) changes with brightness, so it is read for every frame drawn.
- Highlights brighter than the screen can show roll off smoothly towards its limit. Below three-quarters of the headroom nothing changes, so on any screen with 1.33× headroom or more, white and everything under it keep their exact values. The curve never brightens and never adds contrast.
- On an SDR screen the same curve tone maps the photo: only the top quarter of the range is given up to fit the highlights in.

With the setting off, HDR photos are decoded tone mapped to SDR. Changing it decodes the image on screen again and keeps your zoom.

Saving keeps HDR only in some cases; see [Editing](Editing) and [Limitations](Limitations).

## RAW files

The browser lists these camera RAW extensions: .3fr, .arw, .cr2, .cr3, .crw, .dng, .erf, .fff, .iiq, .mrw, .nef, .nrw, .orf, .pef, .raf, .raw, .rw2, .rwl, .rwz, .sr2, .srf and .srw. Apple's RAW engine decodes them, so its camera list, which comes with macOS, decides which bodies actually work.

**RAW files** in **Settings > Viewer**:

- **Embedded preview (faster)**, the default, shows the JPEG the camera saved inside the file, with the camera's own colours. Where it is too small for the screen or the zoom (many cameras store 1616 pixels or less), minivu renders the sensor data instead, on the GPU, with Apple's RAW engine.
- **Render RAW data** always renders the sensor data, at the size shown: slower, but the same rendering at every zoom.

**Render RAW files with extended dynamic range** (off by default, and available only while **Display HDR photos in HDR** is on) renders the sensor data with highlights reaching about twice SDR white. It always renders, since embedded previews are SDR, which takes a moment per photo, and its highlights need an HDR screen.

A RAW render is heavy: for a 24 MP photo, about 0.8 GB of memory for a screen-sized render and 1.6 GB for full size, held for about five seconds afterwards. So renders run one at a time, only the nearest RAW neighbour is rendered ahead, and on Macs with 8 GB of memory or less none is (embedded previews still are).

## Formats

Everything is decoded by Apple's frameworks: ImageIO for images and RAW previews, Apple's RAW engine (through Core Image) for RAW renders, Core Graphics for PDF and AppKit for SVG. The browser lists files with these extensions, in any letter case:

| Format | Extensions |
|---|---|
| JPEG | .jpg .jpeg .jpe .jfif |
| PNG, animated PNG | .png .apng |
| GIF | .gif |
| HEIC and HEIF | .heic .heif .hif |
| AVIF | .avif |
| WebP | .webp |
| JPEG XL | .jxl |
| JPEG 2000 | .jp2 .j2k .jpf .jpx |
| TIFF | .tif .tiff |
| BMP | .bmp .dib |
| TGA | .tga |
| Icons and cursors | .ico .cur .icns |
| Photoshop (flattened) | .psd |
| OpenEXR | .exr |
| Camera RAW | as listed above |
| PDF | .pdf |
| SVG | .svg |

An icon file shows its largest size, and a HEIC collection its primary picture. A file macOS can't decode shows "minivu can’t display “name”." in place of the image, and the keys still move on to the next.

## Compare

Select two to four images in the browser and choose **Image > Compare Selected** (⌥⌘K), or click **Compare** in the browser's toolbar. The Compare window shows them side by side: two or three in a row, and four in a row or a 2 × 2 grid, set with **Layout** in its toolbar (**Grid** by default, and remembered). There is one Compare window; comparing again replaces its images.

Each pane has its number, the file name (its path in the tooltip), pixel size, file size and exposure (or, without one, the camera or the format) at the top, and stars, a tag button, a Trash button and the zoom at the bottom. Click a star to rate, and the current star again to clear. The focused pane is outlined.

Each pane is the same canvas as the viewer: click for fit or actual size, press and hold for the magnifier, drag to pan, and HDR shows as it does there. The wheel over a pane does what **Mouse wheel** is set to, for that pane.

**Sync** in the toolbar (on by default, and remembered) zooms and pans all panes together. Zoom is matched relative to each image's fitted size, and position as a fraction of the image, so photos of different sizes show the same part of the scene. An image replaced in a pane joins the others' zoom.

| Keys | Do |
|---|---|
| ⌘1 to ⌘4, or click | Focus a pane |
| Tab, ⇧Tab | Next or previous pane |
| ← → | Previous or next image in the focused pane |
| 0 to 5 | Rate the focused image (0 clears) |
| T | Tag or untag it |
| ⌫, ⌦ or ⌘⌫ | Move it to the Trash |
| Return or F | Full screen |
| Esc | Close the window |

- ← and → step through the browser's images in its order, skipping images already in another pane, and wrap round if **Wrap around at end of folder** is on.
- The **Image** menu's zoom, rating and tag commands, **Go > Next Image** and **Previous Image**, and **File > Reveal in Finder** and **Move to Trash** act on the focused pane; with Sync on, zoom carries to the others.
- Move to Trash asks nothing, as in Finder. The pane then shows the next image in the folder that isn't already shown, or the previous one at the end; with none left the pane goes, and the window closes with its last pane.
- Stars and tags set here show in the browser and the viewer straight away.
- Full screen in the Compare window is macOS full screen, in a Space of its own, unlike the viewer's.
