# Browser

The browser window is where minivu starts. It has three parts: the folder sidebar on the left, the thumbnail grid in the middle, and the preview pane on the right, with the selected photo, its stars and tag, and its file details and EXIF. A toolbar runs across the top and a status bar under the grid.

At launch the browser opens the last folder you visited, if it can still be read, and otherwise your Pictures folder. The window's title is the folder's name, with a count such as "123 images, 4 folders" under it. The window remembers its size and the widths of its panes.

**View > Show Sidebar** (⌃⌘S) and **View > Show Preview Pane** (⌥⌘P) hide and show the two sides; the toolbar has a button for each. A hidden preview pane decodes nothing.

## The toolbar

From left to right:

| Item | What it does |
|---|---|
| Sidebar button | Shows or hides the sidebar |
| Back and Forward | The folders you viewed before and after this one |
| Enclosing Folder | Up one level |
| Thumbnail Size | A slider for the size of the grid's thumbnails |
| Sort | The **View > Sort By** choices |
| Filter | Stars, the tag and the folder's Finder tags; its symbol fills while a filter is on |
| Compare | Compares two to four selected images (⌥⌘K) |
| Slideshow | Starts a slideshow (⇧⌘F) |
| Search field | Filters the folder by name |
| Preview button | Shows or hides the preview pane |

The toolbar can't be customised.

## The sidebar

The sidebar lists **Favorites**. **Pictures** is always first and can't be removed; the folders you add follow, in the order you added them. There are three ways to add one:

- the **Add Folder** button at the foot of the sidebar;
- **File > Add Folder to Sidebar…** (⇧⌘O), which adds a folder without opening it;
- **File > Open Folder…** (⌘O), which adds the folder and shows it.

Each favourite expands into its folder tree. A folder's subfolders are listed when you expand it, and again each time you do, so folders made or deleted in Finder meanwhile appear and go. Click a folder to show it in the grid. When the folder shown lies under a favourite, its row is selected and the rows above it expand; otherwise no row is selected.

Right-click a row for **Reveal in Finder**, and on a favourite other than Pictures, **Remove from Sidebar**. Removing a favourite doesn't touch the folder.

### What minivu can open

minivu runs in the App Sandbox. It can use your Pictures folder, the folders in its sidebar and everything inside them, recent Copy To and Move To folders, and folders and files you choose in an open panel, drop on the app or open with it from Finder. The parent of a folder you opened is often outside all of those: **Go > Enclosing Folder** is then unavailable, and a folder minivu isn't allowed to read shows a message in the grid pointing to **File > Open Folder…**.

minivu works only with the Mac's internal storage. The **Open Folder…** and **Add Folder to Sidebar…** panels grey out folders on external drives, memory cards, disk images and network shares, minivu explains instead of opening one from Finder, and it refuses to copy or move files to them. Copy photos to a folder on the Mac first. See [Limitations](Limitations).

## Moving between folders

- **Double-click** a folder in the grid, or select it and press Return, to go into it.
- **Go > Enclosing Folder** (⌘↑) goes up one level, with the folder you came from selected, as in Finder.
- **Go > Back** (⌘[) and **Go > Forward** (⌘]) step through the folders you viewed in this window and select the item you had selected in each.
- The status bar shows the folder's path on its right; click a folder in it to go there.

minivu watches the folder shown. Files added, removed or renamed in Finder or another app show up by themselves, without a Refresh command. Finder tags are the exception: changing one changes only an extended attribute, which the folder watcher doesn't report, so minivu reads the tags of the visible thumbnails again when its window becomes active, which is when you come back from Finder.

Opening an image from Finder with minivu shows its folder in the browser with the image selected, then opens it in the viewer.

## The grid

The grid shows the folder's subfolders first, then its images. Only image files in formats minivu reads are listed; other files are left out. **View > Show Hidden Files** (⇧⌘.), or **Show hidden files** in **Settings > General**, also lists hidden files, such as those whose names start with a dot. Packages, such as an app or a Photos library, count as documents, not folders, as in Finder, so they aren't listed.

Each cell shows:

- the thumbnail, drawn as large as fits in its square;
- a checkmark badge on the picture's top-left corner when the image is tagged;
- the name, followed by up to three coloured dots for its Finder tags;
- a row of stars: filled for the rating, and hollow ones to click while the pointer is over the cell;
- the image's pixel dimensions, as in "6032 × 4032", once they have been read.

Folders have no stars or dimensions.

**Thumbnail size.** Drag the slider in the toolbar, or use **Image > Zoom In** (⌘=) and **Image > Zoom Out** (⌘-) while the browser is the active window, which move in steps of 20 points. The size is 80 to 320 points, 150 by default, and is also in **Settings > Thumbnails**. It is remembered.

When a folder holds nothing minivu lists, the grid says "No Images", and when a search or filter hides everything, "No Matches".

## Selection

Click to select, ⌘-click and ⇧-click to select several, and use the arrow keys, with ⇧ to extend the selection. ⌘A selects everything the grid shows. Type the start of a name to select it; a pause of more than a second starts a new name, as in Finder. Right-clicking an item that isn't selected selects it first.

The **lead** is the item you clicked or arrowed to last. It is what the preview pane shows, what the viewer opens and what Rename renames.

The status bar counts what the folder holds, or the selection and its size, as in "12 of 340 selected — 84.1 MB". While a search or filter hides part of the folder and nothing is selected, it says how many are shown, as in "12 of 340 shown".

## Opening in the viewer

Double-click an image, press Return, or choose **File > Open in Viewer** (⌘↓). The viewer opens full screen, or in a window if you turn off **Open viewer in full screen** in **Settings > General**. It steps through the images the grid shows, in the grid's order, with the search and filters applied. When you go back to the browser, the image you were last looking at is selected and scrolled into view. See [Viewer](Viewer).

## The preview pane

With one image selected, the pane shows it large, drawn on the GPU as the viewer draws it. Below the picture:

- **Stars and a tag button** for that image. Click a star to rate it, the current rating again to clear it, and the checkmark to tag or untag it.
- **File information**, in sections: File (name, kind, size, modified and created dates), Image (dimensions, megapixels, bit depth, colour model, profile, orientation, DPI, alpha, and pages, frames or HDR where they apply), Camera, Exposure, Dates, GPS and Description. Sections the file has nothing for are left out. The values can be selected and copied.

Drag the divider between the picture and the information to share the height differently; minivu remembers where you put it.

In the picture, press and hold for the magnifier, and double-click to open the viewer. With **Mouse wheel** in **Settings > Viewer** set to **Previous / next image** (the default), scrolling over the picture moves the grid's selection to the next or previous image, and round from the end to the start when **Wrap around at end of folder** is on in **Settings > General**. Set to **Zoom in / out**, the wheel zooms the preview instead. Hold ⌘ while scrolling to do the other one.

A selected folder shows its icon and file information. Several selected items show how many there are and their total size.

## Sorting

**View > Sort By** and the toolbar's Sort menu offer:

| Sort | Order |
|---|---|
| **Name** | Finder's order (img2 before img10, letter case ignored), then extension, so a photo's variants stay together |
| **Date Modified** | The file's modification date, then name |
| **Date Created** | The file's creation date, then name |
| **Size** | File size, then name |
| **Type** | Extension, then name |
| **Rating** | Stars, with equal ratings by name |
| **Custom Order** | Your own arrangement |

**Ascending** and **Descending** at the foot of the menu set the direction. Each sort remembers its own direction, as Finder's columns do. The first time you choose one, Rating runs most stars first and the others run A to Z, oldest first or smallest first. The default sort is Name, ascending, and minivu keeps the sort you last chose, for every folder.

Folders always come before images. Sorted by Rating or Custom Order, folders go by name.

### Custom Order

Choose **Custom Order**, then drag thumbnails to arrange them. A gap shows where they will go, never before the folders. Each folder keeps its own arrangement in the catalog. Files that aren't in it yet, such as new ones, come after it, by name. Images hidden by a filter keep their places. **Descending** shows the arrangement back to front.

A file renamed in minivu, with Rename or Batch Rename, keeps its place.

Arranging needs dragging; there are no keys for it, and a rearrangement can't be undone.

## Filtering

The toolbar's **Filter** menu, and **View > Filter** in the menu bar, have:

- **Show All**, which turns the star, tag and Finder tag filters off;
- **★ or More** to **★★★★★**, the images with at least that many stars;
- **Tagged Only**, the tagged images;
- in the toolbar menu only, under **Finder Tags**, each Finder tag used in the folder. Choose a tag to show only images with it, and choose it again to turn it off.

A star filter, Tagged Only and a Finder tag can be on together, and an image must pass all of them. The filter's symbol in the toolbar fills while any of them is on.

The search field in the toolbar ("Filter by Name") keeps files and folders whose names contain what you type, ignoring letter case and accents, and it works together with the filters.

The star, tag and Finder tag filters apply to images only: folders always show, so a filter never strands you in a folder. The filters and the search stay as you move between folders, and start off at each launch. Selected images a filter hides are deselected. When a rating or tag you set makes the whole selection disappear under the filter, the selection moves on to the next item, as it does after Move to Trash, so culling with a filter on keeps going.

## Ratings and the tag

Each image can have 0 to 5 stars and a tag, FastStone's quick "keep" mark for sorting through a shoot.

| To | In the grid | From any window |
|---|---|---|
| Rate the selection | 0–5 (0 clears) | **Image > Rating** (⌃0–⌃5) |
| Tag or untag the selection | ` (backquote) | **Image > Tag** (⌘T) |
| Rate one image | Click its stars | |

Clicking a cell's stars rates only that image and doesn't change the selection; clicking the rating it already has clears it. The right-click menu has **Rating** (**Clear Rating**, **Rate 1 Star** to **Rate 5 Stars**) and **Tag** too, and the preview pane has stars and a tag button for the image it shows.

A digit or backquote typed within a second of a letter continues the name you are typing instead, so a name like "IMG_2" can still be typed to select it. T types a name in the grid, as letters do in Finder; use ⌘T to tag.

Tag on a mixed selection tags all of it, and untags only when every selected image was already tagged; when they all are, the menu item reads **Remove Tag**. **Image > Rating** shows a checkmark beside the rating every selected image shares.

### Where marks are kept

Stars and tags are kept in minivu's catalog, one SQLite database on your Mac, in the app's container at `~/Library/Containers/com.minivu.app/Data/Library/Application Support/minivu/catalog.sqlite`. The catalog also holds each folder's Custom Order. minivu doesn't write marks into your files, into XMP sidecars or into Finder tags, so other applications don't see them.

Marks follow files:

- A file renamed or moved with minivu keeps its marks, including with Batch Rename, and a copy made with minivu gets its original's marks.
- The catalog records each file's identity as well as its path, so a file renamed or moved in Finder gets its marks back the next time minivu opens the folder it is in.
- Copies made in Finder are new files and start unmarked, and a file moved to another volume in Finder loses its marks.
- A file missing from its folder for a year is forgotten.

If the catalog file is ever damaged, minivu renames it aside (`catalog.sqlite.damaged-…`) rather than deleting it, and starts a new one.

## Finder tags

minivu shows the tags you set in Finder as coloured dots after an image's name, up to three, in the colours Finder gives them, and lists the folder's tags in the toolbar's Filter menu. It reads Finder tags but never changes them.

## Managing files

### Drag and drop

Drag files from Finder, or thumbnails from the grid, onto:

- the grid, to put them in the folder it shows (an outline round the grid shows the drop will land there);
- a folder in the grid, to put them in that folder;
- a folder in the sidebar, to put them in that folder.

As in Finder, a drag on the same disk moves and a drag to another disk copies. Hold ⌥ while dropping to copy, or ⌘ to move. Dragging files from Finder into minivu on the same disk therefore moves them, exactly as a drag between two Finder windows would.

Files already in the destination stay where they are, except in Custom Order, where dropping them rearranges the grid. A folder can't be put inside itself. Both are decided by each item's identity on disk, not its path, so another spelling of the same folder, such as a symbolic link, can never make a file replace itself.

Dragging thumbnails out of minivu, to Finder or another app, copies the files.

### Copy To and Move To

**File > Copy To** and **File > Move To**, also in the right-click menu, act on the selection. Each lists the last five folders you chose, then **Choose Folder…**, which opens a panel where you can also make a new folder. The recent folders are remembered as bookmarks, so the sandbox lets minivu use them again after a restart.

### Name clashes

Before anything moves, minivu asks about every file whose name is already taken in the destination: **Keep Both**, **Replace** or **Skip**. **Keep Both** is the default and gives the new file a number, as in "photo 2.jpg". When more than one name clashes, **Apply to All** answers the rest the same way.

**Replace** puts the old item in the Trash rather than deleting it. If the new item then can't arrive (the file is unreadable or the disk is full), the old one comes back from the Trash. A folder is never replaced by a file, or a file by a folder.

### Progress and safety

Files are copied or moved one at a time, off the main thread. A job of more than 20 files, or one still running after half a second, shows a progress sheet with **Cancel**, which stops after the file under way. One copy or move runs at a time. When it finishes, the files that arrived in the folder shown are selected; files that left it make way for the next one. Anything that couldn't be copied or moved is listed in an alert.

A move to another volume copies to a hidden name first, renames the copy into place and only then deletes the original, so a partial copy is never left under the real name. Quitting during a copy or move stops it after the file under way and waits for that file.

minivu waits for any save still being written to a file before it moves, renames, replaces or trashes that file, so a save can't bring back a file you just moved, or land in the Trash half written. See [Editing](Editing).

### Rename and New Folder

**File > Rename** (F2, or **Rename** in the right-click menu) edits the name of the one selected item in place, with a file's name selected up to its extension. Return, Tab or a click elsewhere keeps the new name; Esc cancels. A name that can't be used, such as one already taken, empty, containing "/" or ":", or starting with a dot, is explained, and the editor comes back with what you typed so you can correct it. A change of letter case alone works. To rename many files, use **Tools > Batch Rename…** (⇧F2); see [Tools](Tools).

**File > New Folder** (⇧⌘N), or **New Folder** when you right-click the grid's background, makes "untitled folder" in the folder shown and starts renaming it.

### Move to Trash

**File > Move to Trash** (⌘⌫, or **Move to Trash** in the right-click menu) moves the selection to the Trash without asking, as Finder does, and selects the next item, so pressing ⌘⌫ repeatedly works through a folder. Move to Trash isn't on the Edit menu's Undo; the items stay in the Trash until you empty it. If the viewer has unsaved edits of an image being trashed, it asks about them first.

**File > Reveal in Finder** (⌥⌘R) shows the selection in Finder, or the folder when nothing is selected.

### Undo

**Edit > Undo** (⌘Z) and **Edit > Redo** (⇧⌘Z) cover copies, moves, renames, new folders and Batch Rename. The menu names the step, as in "Undo Move 3 Items".

- Undoing a move puts each file back exactly where it was, under the name it had.
- Undoing a copy, or a new folder, moves it to the Trash, where it can still be recovered.
- Undoing a transfer that replaced something brings the replaced item back from the Trash.
- A file whose old place has been taken since isn't overwritten; minivu says some items couldn't be put back.

Ratings, tags, Custom Order rearrangements, Move to Trash and the lossless rotations below aren't on the Undo menu.

## The right-click menu

Right-click an item for **Open in Viewer**, **Rename**, **Copy To**, **Move To**, **Tag** (or **Remove Tag**), **Rating**, **Rotate Left**, **Rotate Right**, **Edit Comment…**, **Reveal in Finder** and **Move to Trash**. Items that don't apply to the selection are greyed out, such as rating a folder or rotating a RAW file. Right-click the grid's background for **New Folder**.

## Quick changes without the viewer

Some edits work straight on the selected files, without opening the viewer:

- **Image > Rotate Left** (⌘L), **Rotate Right** (⌘R), **Flip Horizontal** and **Flip Vertical** change the orientation tag of JPEG, HEIC, TIFF and PNG files, so the pixels are never re-encoded. RAW files and other formats are skipped, and an alert afterwards says how many and of which kinds. The files change straight away.
- **Image > Edit Comment…** changes the comment of one selected JPEG.
- **File > Save As…** (⇧⌘S) converts one selected image to another format.

See [Editing](Editing).

## Compare, slideshow and tools

**Image > Compare Selected** (⌥⌘K), or the toolbar's Compare button, opens the compare window with the two to four selected images side by side; ← and → there step through the rest of the folder in the browser's order. See [Viewer](Viewer).

**Tools > Start Slideshow** (⇧⌘F), or the toolbar's Slideshow button, plays the selected images when two or more are selected. Otherwise it plays every image the grid shows, starting from the selected one.

**Tools > Batch Convert…**, **Tools > Batch Rename…**, **Tools > Contact Sheet…**, **Tools > Montage Wallpaper…** and **File > Print…** work on the selected images, or on every image the grid shows when none is selected. Folders never count. **Tools > Set as Desktop Picture** uses the lead image. See [Tools](Tools).

## The thumbnail cache

Thumbnails are made off the main thread. A cell that scrolls away before its thumbnail is ready cancels its request, and the row you stop on is made first, so a fast scroll decodes only where you stop. Thumbnails are made at two sizes, 256 and 512 pixels, and the cell scales one to fit, so moving the size slider doesn't decode the folder again.

They are kept in two places:

- **In memory**, up to 200 MB, drawn in the colour space of the display the browser is on.
- **On disk**, as JPEG (PNG for images with transparency), in one SQLite file at `~/Library/Containers/com.minivu.app/Data/Library/Caches/minivu/thumbnails.sqlite`. It is trimmed to 1 GB at launch, least recently used first.

A cached thumbnail is used only while its file's modification date and size are unchanged, so an edited photo gets a new one. **Settings > Thumbnails > Clear Thumbnail Cache** empties the disk cache; thumbnails are made again from the original files the next time a folder is shown. Thumbnails already held in memory can still be used until minivu quits.

On the M1 Pro MacBook Pro minivu was developed on, scrolling a folder of 5,000 thumbnails stays smooth, with peak memory around 186 MB. See [Architecture](Architecture).
