# Settings

Choose **minivu > Settings…** (⌘,). The window has six panes: **General**, **Viewer**, **Magnifier**, **Thumbnails**, **Slideshow** and **Editors**, and opens on the one you looked at last.

Every change is saved and takes effect the moment you make it; there is no OK or Apply button. Settings live in minivu's sandbox container, on your Mac only (see [Security and Privacy](Security-and-Privacy)).

## General

| Setting | Choices | Default |
|---|---|---|
| **Theme** | **System**, **Bright**, **Gray**, **Dark** | System |
| **Show hidden files** | on or off | off |
| **Wrap around at end of folder** | on or off | off |
| **Open viewer in full screen** | on or off | on |
| **Ask before saving over the original** | on or off | on |

- **Theme.** **System** follows macOS's light or dark appearance. **Bright** and **Dark** are the standard light and dark looks; **Gray** is the dark look with lighter surfaces. **View > Theme** sets the same thing.
- **Show hidden files** lists hidden files and folders in the browser. **View > Show Hidden Files** (⇧⌘.) toggles the same setting.
- **Wrap around at end of folder.** Going to the next image after the last goes back to the first, and the previous image before the first goes to the last. It applies in the viewer and Compare, and to scrolling over the browser's preview pane.
- **Open viewer in full screen.** Double-clicking an image, or pressing Return, opens the viewer full screen; off, it opens in a window. See [Viewer](Viewer).
- **Ask before saving over the original.** **File > Save** asks before it writes over the file. Ticking **Don't ask again** in that question turns this off; this switch is the way to turn it back on. See [Editing](Editing).

## Viewer

| Setting | Choices | Default |
|---|---|---|
| **Background** | **Black**, **Dark gray**, **Gray**, **White** | Black |
| **Enlarge small images to fit** | on or off | off |
| **Pixelated zoom above 200%** | on or off | on |
| **Mouse wheel** | **Previous / next image**, **Zoom in / out** | Previous / next image |
| **Full-screen viewer opens on** | **The display with the browser**, **Another display** | The display with the browser |
| **Display HDR photos in HDR** | on or off | on |
| **RAW files** | **Embedded preview (faster)**, **Render RAW data** | Embedded preview (faster) |
| **Render RAW files with extended dynamic range** | on or off | off |

- **Background** is the surround behind the image.
- **Enlarge small images to fit** scales an image smaller than the window or screen up to fit it. Off, small images show at their own size. Slideshows follow it too.
- **Pixelated zoom above 200%** draws each pixel as a sharp square once you zoom in past 200%, so you can judge pixels one by one. Off, they are smoothed.
- **Mouse wheel** decides what scrolling over an image does. Hold ⌘ while scrolling to get the other one.
- **Full-screen viewer opens on.** **Another display** keeps the browser's display free: browse on one display and view full screen on the other. With one display connected, the viewer opens on it. Slideshows open where the full-screen viewer does, and **Window > Move to Next Display** (⌃⌥⌘→) moves either. Two-display behaviour has been tested with simulated displays only.
- **Display HDR photos in HDR.** HDR photos (gain maps, PQ and HLG) show highlights brighter than white on screens that can show them: the Liquid Retina XDR display of a MacBook Pro, Pro Display XDR, and external displays with HDR turned on. Off, or on other screens, they are tone mapped.
- **RAW files.** **Embedded preview (faster)** shows the JPEG the camera saved inside the raw file, at once. Where that preview is too small for the screen or the zoom, the RAW data is rendered instead. **Render RAW data** always renders the sensor data with Apple's RAW engine: slower, but the same rendering at every zoom. Batch Convert renders RAW files the same way.
- **Render RAW files with extended dynamic range** shows RAW highlights in HDR. It always renders the RAW data, which takes a moment per photo, and its highlights need an HDR screen. It can only be turned on while **Display HDR photos in HDR** is on.

Changing the HDR or RAW settings reloads the image on screen. In a slideshow that is running, the change shows from the next slide.

There is one setting with no control: how much of the RAW engine's extended range **Render RAW files with extended dynamic range** uses, from 0 to 1 (1 by default). To tame RAW highlights, quit minivu and set a lower value in Terminal:

```bash
defaults write ~/Library/Containers/com.minivu.app/Data/Library/Preferences/com.minivu.app hdrRawAmount -float 0.5
```

To go back to the default, quit minivu and remove the value:

```bash
defaults delete ~/Library/Containers/com.minivu.app/Data/Library/Preferences/com.minivu.app hdrRawAmount
```

## Magnifier

The magnifier is the round loupe that appears while you press and hold on an image in the viewer.

| Setting | Range | Default |
|---|---|---|
| **Zoom** | 1.5× to 8×, relative to actual size | 2.0× |
| **Size** | 60 to 300 pt | 140 pt |

**Size** is the loupe's radius, so 140 pt is a circle 280 pt across. The **Preview** below the sliders shows the loupe at one-third size. The loupe always magnifies at least twice the viewer's current zoom, so it still enlarges when you are already zoomed in.

Scrolling while the magnifier is up also changes **Zoom**, by 1.25× per wheel notch, and the new value stays. Scrolling reaches from 1.5× up to 16×, beyond the slider's 8×.

## Thumbnails

- **Size:** 80 to 320 pt, 150 pt by default. It is the side of each square cell in the browser's grid. The **Thumbnail Size** slider in the browser's toolbar sets the same value.
- **Clear Thumbnail Cache** empties the thumbnail cache on disk; thumbnails are made again from the original files when they are next needed. Nothing else is touched: stars, tags and custom orders are in the catalog, not the cache.
- Without clearing, the disk cache is kept to about 1 GB: at each launch the least recently used thumbnails are removed beyond that.

## Slideshow

How **Tools > Start Slideshow** plays. [Tools](Tools) describes the show itself. The pane is also one click away during a show: the gear in the control bar pauses the show and opens it.

| Setting | Choices | Default |
|---|---|---|
| **Show each slide for** | 1 to 60 s, in whole seconds | 4 s |
| **Order** | **In order**, **Shuffled** | In order |
| **Start again after the last slide** | on or off | on |
| **Captions** | **None**, **File name**, **File name and date**, **Camera and exposure** | None |
| **Transition** | **Random**, or one of **Cross-Fade**, **Fade Through Black**, **Slide**, **Push**, **Wipe**, **Zoom**, **Iris**, **Dissolve** | Cross-Fade |
| **Duration** | 0.3 to 3.0 s, in tenths | 1.0 s |
| **Play music** | on or off | off |
| **Shuffle** | on or off | off |
| **Volume** | silent to full | 80% |

- Slideshows play full screen on the display chosen for the full-screen viewer in **Viewer** settings; there is no separate display setting here.
- **Show each slide for** counts from the end of each slide's transition.
- The **Transition** section has a small preview of the chosen transition; click it to play. With Reduce Motion on in macOS's Accessibility settings, transitions that move the picture play as a cross-fade.
- **Music.** **Add…** chooses MP3, AAC, WAV and AIFF files, or folders of them, and turns **Play music** on. Each song or folder is listed with **Remove**; the list reads "No music chosen" when empty. **Shuffle** and **Volume** are available while **Play music** is on. The music fades in when a slideshow starts, pauses with it, and fades out when it ends.

**During a show.** In a show that started with music, **Volume** and **Play music** apply at once. **Show each slide for**, **Transition**, **Duration** and **Captions** apply from the next slide. **Order**, **Start again after the last slide**, the songs and **Shuffle** apply to the next show.

## Editors

The applications listed in **Tools > Open in External Editor**. The list starts empty, so until you add one that menu holds only **Edit Editor List…**, which opens this pane.

- **Add…** opens a panel in Applications; choose one or more apps. An app already in the list isn't added twice. An empty list reads "No editors yet".
- Each row shows the app's icon and name, with **Move Up**, **Move Down** and **Remove** buttons. Rows can also be dragged into a new order.
- The first editor carries a ⌘E badge: it is the one ⌘E opens.
- A warning triangle marks an app that is no longer where it was added. minivu still looks for it by its bookmark and bundle identifier when you use it, and says so if it can't be found.
- **Suggestions** lists up to six image editors installed on your Mac that aren't in the list yet; click one to add it. Known editors come first (Preview, Pixelmator, Affinity Photo, Photoshop, Lightroom Classic, Lightroom, Acorn, Skylum's apps, Capture One, DxO's apps, GIMP, darktable and Krita), then other apps that declare themselves editors of JPEG or images.

The images open as saved. When the editor saves one, minivu shows the change; see [Tools](Tools).

## Remembered without a setting

Some choices are kept between launches without appearing in Settings. They are saved in the same place:

- The browser's sort order.
- Save As's format and its options for each format.
- The Batch Convert sheet (when you press **Convert**), its name pattern, and Batch Rename's pattern (when you press **Rename**), each kept separately.
- The print layout from the print panel's **Picture Layout** section.
- The Contact Sheet dialog, except the header text.
- Montage Wallpaper's layout, spacing and background.
- The Settings pane you last looked at.
