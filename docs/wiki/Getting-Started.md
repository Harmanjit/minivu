# Getting Started

## First launch

If you built the app yourself, open `build/minivu.app`; a copy from another Mac shows the Gatekeeper dialog once (see [Installation](Installation)).

minivu opens one window, the browser, showing your Pictures folder. From then on it opens on the folder you were looking at when you quit, as long as it can still read it. There is no import step and no library to set up: minivu shows folders as they are on disk.

## Open a folder

- **File > Open Folder…** (⌘O) chooses a folder, shows it, and adds it to the sidebar, so it is one click away next time, even after you quit.
- **File > Add Folder to Sidebar…** (⇧⌘O) adds a folder without leaving the one you are in.
- In Finder, Control-click images and choose **Open With > minivu**, or drop a folder on minivu's icon in the Dock. An image opens in the viewer, with its folder behind it in the browser.

minivu works with folders on the Mac's internal storage. Folders on a memory card, a USB drive, a disk image or a network share are refused, so copy the photos to a folder on the Mac first. The app is sandboxed: it reaches your Pictures folder, the folders and files you choose, and its own container. See [Security and Privacy](Security-and-Privacy).

## Browse

The browser has three parts: the sidebar on the left, where **Favorites** lists Pictures and the folders you add, each opening into its subfolders; the thumbnail grid in the middle; and the preview pane on the right, with the selected image, its stars and tag, and its file and camera details. A status bar under the grid counts what is shown and selected.

- Click a folder in the sidebar, or double-click one in the grid, to open it. ⌘↑ goes to the enclosing folder, ⌘[ and ⌘] go back and forward.
- Arrow keys move the selection, and typing a name selects it, as in Finder.
- **View > Sort By** sorts by name, dates, rating, custom order, size or type. The toolbar sets the thumbnail size and filters by stars, tag, Finder tag or name.
- **View > Show Sidebar** (⌃⌘S) and **Show Preview Pane** (⌥⌘P) hide or show either side.

See [Browser](Browser).

## View

Double-click a thumbnail, or select it and press Return, to open it in the viewer. By default the viewer opens in full screen, instantly and without a new Space; **Settings > General > Open viewer in full screen** turns that off.

| Key or action | In the viewer |
|---|---|
| → ↓ Space | Next image |
| ← ↑ Delete | Previous image |
| Home, End | First and last image |
| Return | Switch between window and full screen |
| Esc, or double-click | Back to the browser |
| Click | Fit to the window, or actual size at the point clicked |
| Press and hold | The magnifier |
| + - / * | Zoom in, zoom out, actual size, fit |
| I | Keep the overlay with name, position, size and zoom |
| F | The filmstrip |

When the image is larger than the window, the arrow keys pan it instead. Move the pointer to an edge of the viewer for its panels: the filmstrip at the top, the edit tools on the left, file information and the histogram on the right, and zoom, navigation and slideshow controls at the bottom. See [Viewer](Viewer).

## Rate and tag

Each image can have 0 to 5 stars and a tag, the quick "keep" mark for culling a shoot.

- In the grid, press **1** to **5** to give the selected images stars, **0** to clear them, and the backquote key (**`**) to tag or untag them. You can also point at a thumbnail and click one of the hollow stars that appear under its name.
- In the viewer, the same digits rate the image shown, and **T** or **`** tags it.
- In both, **Image > Rating** (⌃0 to ⌃5) and **Image > Tag** (⌘T; **Remove Tag** when already tagged) do the same.

Then use the toolbar's Filter menu to show only, say, **★★★ or More** or **Tagged Only**; the status bar says how many are shown. Stars and tags are kept in minivu's own catalog on your Mac, not written into the files.

## A first edit

1. Open a photo in the viewer.
2. Choose **Image > Adjust > Lighting…** (⌥⌘L), or move the pointer to the left edge and pick Lighting from the panel.
3. Drag **Brightness** or **Contrast**. The image updates as you drag.
4. Click **Apply** to add the change, or **Cancel** to leave it out. **Reset** puts the controls back.
5. **Edit > Undo** (⌘Z) and **Redo** (⇧⌘Z) step through your edits, up to 50 steps.

Nothing on disk has changed yet. To keep the result:

- **File > Save** (⌘S) writes over the original in its own format, colour space and bit depth, with its metadata and the quality last used for that format, after asking whether to replace the original (the alert's **Don’t ask again** turns the question off; **Settings > General > Ask before saving over the original** turns it back on). Formats minivu can't write back, such as RAW, WebP and PDF, go to Save As instead.
- **File > Save As…** (⇧⌘S) writes a new file, with the format and its options, a live size estimate and a quality comparison.
- **File > Revert to Saved** throws the edits away.

If you move to another image, go back to the browser or quit with unsaved edits, minivu asks first. See [Editing](Editing).

## Where next

- [Tools](Tools): slideshows (⇧⌘F), Batch Convert, Batch Rename, printing, contact sheets and more.
- [Settings](Settings): **minivu > Settings…** (⌘,).
- [Keyboard Shortcuts](Keyboard-Shortcuts), or **Help > Keyboard Shortcuts** (⌘/) in the app.
- **Help > minivu Help** (⌘?) has its own, shorter set of pages, with search.

## Where things are

- Your photos: wherever they were. minivu changes a file only when you ask. Save writes over the original; Move to Trash, and replacing a file of the same name when copying or moving, put items in the Trash rather than deleting them.
- The catalog, the thumbnail cache and settings: in the app's container, `~/Library/Containers/com.minivu.app`.
- Screen captures, montages and desktop picture copies: **Pictures/minivu Captures** and **Pictures/minivu Wallpapers**.
