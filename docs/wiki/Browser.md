# Browser

The browser window is where minivu starts. It has three parts: the sidebar on the left, the thumbnail grid in the middle, and the preview pane on the right, with the selected photo, its stars and tag, and its file details and EXIF. A toolbar runs across the top and a status bar under the grid.

The grid usually shows one folder. It can also show a **list**: the images of a folder and all its subfolders (the flat view), the results of a search, a smart folder, a collection, or files sent from Find Duplicates. Each is described below. Videos sit in the grid among the photos. In this page, "image" means any file the grid lists, video or photo, as it does in minivu's menus.

At launch the browser opens the last folder you visited, if it can still be read, and otherwise your Pictures folder. The window's title is the folder's name, with a count such as "123 images, 4 folders" under it; when the folder holds videos they are counted apart, as in "4 images, 2 videos, 1 folder". The window remembers its size and the widths of its panes.

**View > Show Sidebar** (⌃⌘S) and **View > Show Preview Pane** (⌥⌘P) hide and show the two sides; the toolbar has a button for each. A hidden preview pane decodes nothing.

## The toolbar

From left to right:

| Item | What it does |
|---|---|
| Sidebar button | Shows or hides the sidebar |
| Back and Forward | The folders and lists you viewed before and after this one |
| Enclosing Folder | Up one level |
| Thumbnail Size | A slider for the size of the grid's thumbnails |
| Sort | The **View > Sort By** choices |
| Filter | Stars, the tag, photos or videos, More Filters…, and the folder's Finder tags; its symbol fills while a filter is on |
| Compare | Compares two to four selected images (⌥⌘K) |
| Slideshow | Starts a slideshow (⇧⌘F) |
| Share | Shares the selected images with AirDrop, Messages, Mail and other services |
| Search field | Filters what the grid shows by name |
| Preview button | Shows or hides the preview pane |

The toolbar can't be customised.

## The sidebar

The sidebar has up to three sections.

**Favorites.** **Pictures** is always first and can't be removed. It has the name Finder gives it in your Mac's language. The folders you add follow, in the order you added them. There are three ways to add one:

- the **Add Folder** button at the foot of the sidebar;
- **File > Add Folder to Sidebar…** (⇧⌘O), which adds a folder without opening it;
- **File > Open Folder…** (⌘O), which adds the folder and shows it.

Each favourite expands into its folder tree. A folder's subfolders are listed when you expand it, and again each time you do, so folders made or deleted in Finder meanwhile appear and go. Click a folder to show it in the grid. When the folder shown lies under a favourite, its row is selected and the rows above it expand; otherwise no row is selected.

Right-click a row for **Reveal in Finder**, and on a favourite other than Pictures, **Remove from Sidebar**. Removing a favourite doesn't touch the folder.

**Smart Folders** (a gear symbol) and **Collections** (a stack symbol) appear once you have made one, each sorted by name. See [Smart folders](#smart-folders) and [Collections](#collections) below.

### What minivu can open

minivu runs in the App Sandbox. It can use your Pictures folder, the folders in its sidebar and everything inside them, recent Copy To and Move To folders, and folders and files you choose in an open panel, drop on the app or open with it from Finder. The parent of a folder you opened is often outside all of those: **Go > Enclosing Folder** is then unavailable, and a folder minivu isn't allowed to read shows a message in the grid pointing to **File > Open Folder…**.

minivu works only with the Mac's internal storage. The **Open Folder…** and **Add Folder to Sidebar…** panels grey out folders on external drives, memory cards, disk images and network shares, minivu explains instead of opening one from Finder, and it refuses to copy or move files to them. Copy photos to a folder on the Mac first. See [Limitations](Limitations).

## Moving between folders

- **Double-click** a folder in the grid, or select it and press Return, to go into it.
- **Go > Enclosing Folder** (⌘↑) goes up one level, with the folder you came from selected, as in Finder.
- **Go > Back** (⌘[) and **Go > Forward** (⌘]) step through the folders and lists you viewed in this window and select the item you had selected in each.
- The status bar shows the folder's path on its right; click a folder in it to go there. While a list is shown, the path is that of the lead image's folder (the **lead** is explained under [Selection](#selection)).

minivu watches the folder shown. Files added, removed or renamed in Finder or another app show up by themselves, without a Refresh command. Finder tags are the exception: changing one changes only an extended attribute, which the folder watcher doesn't report, so minivu reads the tags of the visible thumbnails again when its window becomes active, which is when you come back from Finder.

Opening an image from Finder with minivu shows its folder in the browser with the image selected, then opens it in the viewer.

## The grid

The grid shows the folder's subfolders first, then its images and videos. Only files in formats minivu reads are listed; other files are left out. **View > Show Hidden Files** (⇧⌘.), or **Show hidden files** in **Settings > General**, also lists hidden files, such as those whose names start with a dot. Packages, such as an app or a Photos library, count as documents, not folders, as in Finder, so they aren't listed.

Each cell shows:

- the thumbnail, drawn as large as fits in its square;
- a checkmark badge on the picture's top-left corner when the image is tagged;
- for a video, a dark badge on the picture's bottom-right corner with a play symbol and the length, such as "0:12";
- the name, followed by up to three coloured dots for its Finder tags, the colour label among them;
- a row of stars: filled for the rating, and hollow ones to click while the pointer is over the cell;
- the image's pixel dimensions, as in "6032 × 4032", once they have been read, and a video's length.

Folders have no stars or dimensions.

A video's thumbnail is a frame from a little way in (a second in, or a tenth of the way through a clip shorter than ten seconds), so a clip that starts on black still shows what it is of. Nothing plays in the grid.

**Thumbnail size.** Drag the slider in the toolbar, or use **Image > Zoom In** (⌘=) and **Image > Zoom Out** (⌘-) while the browser is the active window, which move in steps of 20 points. The size is 80 to 320 points, 150 by default, and is also in **Settings > Thumbnails**. It is remembered.

When a folder holds nothing minivu lists, the grid says "No Images", and when a search or filter hides everything, "No Matches".

## Selection

Click to select, ⌘-click and ⇧-click to select several, and use the arrow keys, with ⇧ to extend the selection. ⌘A selects everything the grid shows. Type the start of a name to select it; a pause of more than a second starts a new name, as in Finder. Right-clicking an item that isn't selected selects it first.

The **lead** is the item you clicked or arrowed to last. It is what the preview pane shows, what the viewer opens and what Rename renames.

The status bar counts what the folder holds, or the selection and its size, as in "12 of 340 selected — 84.1 MB". While a search or filter hides part of the folder and nothing is selected, it says how many are shown, as in "12 of 340 shown".

## Opening in the viewer

Double-click an image, press Return, or choose **File > Open in Viewer** (⌘↓). The viewer opens full screen, or in a window if you turn off **Open viewer in full screen** in **Settings > General**. It steps through the images the grid shows, in the grid's order, with the search and filters applied; in the flat view or a list, that is the whole list. When you go back to the browser, the image you were last looking at is selected and scrolled into view. A video opens the same way and plays in the viewer. See [Viewer](Viewer).

## The preview pane

With one image selected, the pane shows it large, drawn on the GPU as the viewer draws it. Below the picture:

- **Stars and a tag button** for that image. Click a star to rate it, the current rating again to clear it, and the checkmark to tag or untag it. For a video, the grid's play symbol and the length, such as "▶ 0:12", sit beside the stars.
- **File information**, in sections: File (name, kind, size, modified and created dates), Image (dimensions, megapixels, bit depth, colour model, profile, orientation, DPI, alpha, and pages, frames or HDR where they apply), Camera, Exposure, Dates, GPS and Description. Sections the file has nothing for are left out. The values can be selected and copied. When the description comes from an XMP sidecar (a separate ".xmp" file beside the photo, used for RAW files and formats minivu can't rewrite), a **Sidecar** row names it.
- **Keywords**, at the end, for a file whose metadata minivu can write. Each keyword has an x button that removes it from the file. Type new keywords in the **Add keywords** field, separated by commas, and press Return to add them. A keyword the file already has in another letter case isn't added twice. PDF, SVG, video files and folders show no keyword editor.

For a video, a **Video** section takes the place of Image: dimensions, duration, frame rate, codec, data rate (as in "12.4 Mbit/s"), audio, HDR, and "Playable: No" when macOS can't play it. Camera, Dates and GPS come from the movie's own metadata, as an iPhone or a camera writes it. They are shown only; minivu doesn't change a video's metadata. The pane never plays a video: double-click the still to open the viewer, where it plays.

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

Folders always come before images. Sorted by Rating or Custom Order, folders go by name. Videos sort among the photos.

### Custom Order

Choose **Custom Order**, then drag thumbnails to arrange them. A gap shows where they will go, never before the folders. Each folder keeps its own arrangement in the catalog. Files that aren't in it yet, such as new ones, come after it, by name. Images hidden by a filter keep their places. **Descending** shows the arrangement back to front.

A file renamed in minivu, with Rename or Batch Rename, keeps its place.

Arranging needs dragging; there are no keys for it, and a rearrangement can't be undone.

An arrangement belongs to one folder, so in the flat view, search results and smart folders, Custom Order shows the images by name. A collection under Custom Order shows its images in the order they were added (reversed with **Descending**), and can't be rearranged by dragging.

## Filtering

The toolbar's **Filter** menu, and **View > Filter** in the menu bar, have:

- **Show All**, which turns every filter below off;
- **★ or More** to **★★★★★**, the images with at least that many stars;
- **Tagged Only**, the tagged images;
- **Photos Only** and **Videos Only**. "Photos" means everything that isn't a video, RAW files, PDFs and SVGs included. Choose the one that is on again to show both;
- **More Filters…**, described below;
- in the toolbar menu only, under **Finder Tags**, each Finder tag used in the folder. Choose a tag to show only images with it, and choose it again to turn it off.

These filters can be on together, and an image must pass all of them. The filter's symbol in the toolbar fills while any of them is on, and **Show All** has a checkmark only while none is.

The search field in the toolbar ("Filter by Name") keeps files and folders whose names contain what you type, ignoring letter case and accents, and it works together with the filters.

The filters apply to images only: folders always show, so a filter never strands you in a folder. The filters and the search stay as you move between folders and lists, and start off at each launch. Selected images a filter hides are deselected. When a rating or tag you set makes the whole selection disappear under the filter, the selection moves on to the next item, as it does after Move to Trash, so culling with a filter on keeps going.

### More Filters

**View > Filter > More Filters…** opens a sheet of conditions on the files' metadata. Every condition you set must hold; one left empty doesn't filter.

| Condition | What it keeps |
|---|---|
| **Type** | The ticked kinds: JPEG, HEIF and AVIF, PNG, RAW, TIFF, GIF, WebP, Photoshop, PDF, SVG, Video, Other. None ticked shows every type. |
| **Date Taken** | From and to, both days included. The date is the one the camera recorded, on its own clock; for a video, when recording began. |
| **Camera model** and **Lens** | Names containing what you type, ignoring letter case and accents: "5d" finds "Canon EOS 5D Mark IV". |
| **ISO**, **Aperture (f/)** and **Focal length (mm)** | A range; either end can be left empty. "f/2,8" and "2.8" both work. |
| **Keywords** | Images with all of the keywords you type, separated by commas, in any letter case. |
| **Label** | Any, No Label, or one colour label. |
| **Location** | Any, Has a location, or Has no location. |
| **Orientation** | Any, Landscape, Portrait or Square. |
| **At least … × … pixels** | A minimum width and height. |

**Clear** empties the form, **Cancel** (Esc) leaves the filter as it was, and **Filter** (Return) applies it. While a condition is on, the toolbar's filter symbol fills and the status bar says how many are shown. **Show All** clears these conditions with the others.

Type and Label take effect at once. The other conditions need each file's header (the part of the file that holds its metadata, read without decoding the picture), so minivu reads the headers in the background and images appear as they are known to match; an image is never shown and then taken away. A file that doesn't record a value, such as a photo with no ISO, fails a condition on it. What was read is kept in the catalog, so filtering the same files again reads nothing, until a file changes.

## Flat view

**View > Flat View** (⌥⌘F) shows the images of the folder and of every folder below it as one list, without the subfolders themselves. A checkmark shows it is on. The window's subtitle then ends "with subfolders", as in "123 images, with subfolders". Flat View stays on as you move between folders, like the filters, but it is per window and starts off at each launch.

- The grid fills in as folders are read, and the status bar ends "— searching…" until all are read. Stars, tags and Finder tags arrive at the end.
- Images in different folders can share a name, so a cell's tooltip shows its full path, and the status bar's path shows the lead image's folder; click it to go there.
- Everything else works as in a folder: open in the viewer, rate, tag, label, rename, move, copy, trash, the batch tools and Edit Metadata. Paste puts files in the folder at the top. **New Folder** is off, since the flat view lists no folders. Dragging a thumbnail from a subfolder onto the grid doesn't move it up into the top folder.
- minivu watches only the folder at the top. Changes deeper down show the next time the view is loaded; minivu's own moves, renames and batch work reload it at once.

A walk stops at 12 levels of folders, 20,000 images or 5,000 folders, leaving out the deepest folders first. When it stops, the status bar ends "— limit reached, not every image is shown". Folders on other volumes, and symbolic links to folders, are never followed.

## Lists in place of a folder

Search results, smart folders, collections and files sent from Find Duplicates show in the grid as a list of files that can come from many folders. The window's title is the list's name, and each list is a step in Back and Forward.

Everything the flat view supports works on a list. The commands that need one folder step aside: **New Folder**, **Paste**, dropping files on the grid, arranging in Custom Order, and **Go > Enclosing Folder**. A file you trash or move away with minivu, from the browser, the viewer or the compare window, leaves the list, and after Move To the next image is selected. A list from Find Duplicates keeps a file you rename, or move with Move To, under its new name. Lists aren't watched for changes made in Finder.

## Finding images

**Edit > Find…** (⌘F) searches a folder and its subfolders. The **Find Images** sheet has:

- **Search in**: Pictures, each sidebar folder, and the folder shown. minivu can only search folders you have given it.
- **Include subfolders** (on by default).
- **Name contains**: part of the file name.
- **Rating** (Any, or ★ or More to ★★★★★) and **Tagged only**.
- Every condition of [More Filters](#more-filters).

**Find** (Return) shows the results as a list titled, for example, "“IMG” in Pictures", or "Search in Pictures" without a name. **Clear** empties the form. The sheet opens with your last search, pointed at the folder shown. **Go > Back** returns to the folder.

A search reads the folders when you ask, and stops when you move on; there is no index running in the background. It uses the same limits as the flat view and says when it reaches one. minivu doesn't ask Spotlight, which may not have indexed the camera details and never knows minivu's ratings and tags. Names, types, ratings, tags and labels cost nothing to check; metadata conditions read each file's header once, and the catalog keeps what was read.

### Smart folders

A **smart folder** is a saved search. While search results are shown, choose **File > Save as Smart Folder…** and give it a name. It appears under **Smart Folders** in the sidebar. Clicking it runs the search again, so files added since are found.

Right-click a smart folder for:

- **Edit Search…**, the Find sheet with **Save**; a smart folder being shown runs again with the new search;
- **Rename…**;
- **Delete Smart Folder…**, which asks first and deletes only the saved search, never a file. Deleting the one shown goes back to where you were.

A smart folder whose folder minivu can no longer open shows the usual message pointing to **File > Open Folder…**.

## Collections

A **collection** is a set of images you choose, from any folders, without moving or copying them, like an album in Photos.

- **File > New Collection…** asks for a name and makes a collection holding the selected images, if any.
- **File > Add to Collection**, also in the right-click menu, lists each collection, then **New Collection…**.
- Drag images onto a collection in the sidebar to add them. Nothing moves.
- Click a collection in the sidebar to show its images as a list. Choose **View > Sort By > Custom Order** to see them in the order they were added.
- **File > Remove from Collection**, also in the right-click menu, takes the selected images out of the collection shown. They stay in their folders.
- Right-click a collection in the sidebar for **Rename…** and **Delete Collection…**, which asks first. The images in it stay where they are.

Collections are kept in minivu's catalog, and an image stays in its collections when it moves:

- A file renamed or moved with minivu, including with Batch Rename, stays in its collections. So does a file saved over.
- A file renamed or moved in Finder on the same disk is found again the next time the collection is opened, or when minivu opens the folder it went to.
- A file moved to the Trash leaves the list at once. If you put it back with Finder's Put Back, it returns.
- A file deleted, emptied from the Trash, moved to another disk, or moved somewhere minivu may not read is left out. It comes back if it reappears, and is forgotten after a year.
- Copies are new files and aren't in the collection.

## Ratings and the tag

Each image can have 0 to 5 stars and a tag, FastStone's quick "keep" mark for sorting through a shoot.

| To | In the grid | From any window |
|---|---|---|
| Rate the selection | 0–5 (0 clears) | **Image > Rating** (⌃0–⌃5) |
| Tag or untag the selection | ` (backquote) | **Image > Tag** (⌘T) |
| Label the selection | | **Image > Label** (⌥⌘0–⌥⌘7) |
| Rate one image | Click its stars | |

Clicking a cell's stars rates only that image and doesn't change the selection; clicking the rating it already has clears it. The right-click menu has **Rating** (**Clear Rating**, **Rate 1 Star** to **Rate 5 Stars**), **Tag** and **Label** too, and the preview pane has stars and a tag button for the image it shows.

A digit or backquote typed within a second of a letter continues the name you are typing instead, so a name like "IMG_2" can still be typed to select it. T types a name in the grid, as letters do in Finder; use ⌘T to tag.

Tag on a mixed selection tags all of it, and untags only when every selected image was already tagged; when they all are, the menu item reads **Remove Tag**. **Image > Rating** shows a checkmark beside the rating every selected image shares.

Videos can be rated, tagged and labelled like photos.

### Ratings from other apps

minivu also reads the rating and tag a file carries itself, as XMP (a standard way of storing metadata inside a photo, or in a sidecar file beside it). Ratings set in Lightroom, Bridge, digiKam, XnView MP or a camera therefore show in the grid, the preview pane, the viewer and the compare window, and sort and filter like minivu's own. minivu takes digiKam's "Accepted" pick as its tag.

minivu's catalog wins: once you rate or tag a file in minivu, minivu shows its own marks for that file, even if another app changes the file's rating later. To take the newer rating, rate the file again in minivu.

### Where marks are kept

Stars and tags are kept in minivu's catalog, one SQLite database on your Mac, in the app's container at `~/Library/Containers/com.minivu.app/Data/Library/Application Support/minivu/catalog.sqlite`. The catalog also holds each folder's Custom Order, your collections and smart folders, and the metadata read for filters and searches.

By default minivu doesn't write marks into your files, so other applications don't see them. Turn on **Write ratings into files (XMP)** in **Settings > General** to write every rating, tag and colour label you set from then on into the file as well: inside JPEG, HEIC, PNG and TIFF files, without re-encoding the picture, and in an XMP sidecar for camera RAW files and other formats. The file's modification date changes, and its thumbnail is made again. Marks already in the catalog aren't written when you turn it on. PDFs, SVGs and videos are never written to; their marks stay only in the catalog.

Marks follow files:

- A file renamed or moved with minivu keeps its marks, including with Batch Rename, and a copy made with minivu gets its original's marks.
- The catalog records each file's identity as well as its path, so a file renamed or moved in Finder gets its marks back the next time minivu opens the folder it is in.
- Copies made in Finder are new files and start unmarked, and a file moved to another volume in Finder loses its marks.
- A file moved to the Trash with minivu keeps its marks while it is there.
- A file missing from its folder for a year is forgotten.

If the catalog file is ever damaged, minivu renames it aside (`catalog.sqlite.damaged-…`) rather than deleting it, and starts a new one.

## Colour labels and Finder tags

minivu shows the tags you set in Finder as coloured dots after an image's name, up to three, in the colours Finder gives them, and lists the folder's tags in the toolbar's Filter menu.

**Image > Label** sets an image's **colour label**: **None** (⌥⌘0), **Red** (⌥⌘1), **Orange** (⌥⌘2), **Yellow** (⌥⌘3), **Green** (⌥⌘4), **Blue** (⌥⌘5), **Purple** (⌥⌘6) or **Gray** (⌥⌘7). The right-click menu has the same **Label** submenu, without the shortcuts. It works on the selected images, never folders.

The label is the file's standard Finder colour tag, so Finder, Spotlight and other apps see it. Choosing a colour replaces whichever standard colour tag the file had and keeps every other tag, such as "Holiday". **None** removes the colour tag. A checkmark shows the label every selected image shares. The label is the only change minivu makes to Finder tags.

## Managing files

### Drag and drop

Drag files from Finder, or thumbnails from the grid, onto:

- the grid, to put them in the folder it shows (an outline round the grid shows the drop will land there);
- a folder in the grid, to put them in that folder;
- a folder in the sidebar, to put them in that folder;
- a collection in the sidebar, to add them to it without moving them.

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

**File > New Folder** (⇧⌘N), or **New Folder** when you right-click the grid's background, makes "untitled folder" in the folder shown and starts renaming it. It is off in the flat view and in lists.

### Move to Trash

**File > Move to Trash** (⌘⌫, or **Move to Trash** in the right-click menu) moves the selection to the Trash without asking, as Finder does, and selects the next item, so pressing ⌘⌫ repeatedly works through a folder. Move to Trash isn't on the Edit menu's Undo; the items stay in the Trash until you empty it. If the viewer has unsaved edits of an image being trashed, it asks about them first.

**File > Reveal in Finder** (⌥⌘R) shows the selection in Finder, or the folder when nothing is selected. It works in lists too.

### Share

**File > Share…**, **Share…** in the right-click menu, or the toolbar's **Share** button offers the selected images to the system's share sheet: AirDrop, Messages, Mail, Notes and whatever else is installed. With nothing selected, it offers the lead image. Folders are left out, and Share never falls back to every image in the folder. The services get the files as they are on disk, as Finder would share them. Share has no shortcut. minivu itself makes no network connection; each share service runs in its own process.

### Selecting, copying and pasting

**Edit > Select Tagged** selects every tagged image the grid is showing, and **Edit > Invert Selection** (⇧⌘I) selects everything shown that wasn't selected. Both stop at what a filter shows, so an image hidden by one is left alone. Select Tagged never takes folders; Invert Selection takes them, as Select All does.

**Edit > Copy** (⌘C) puts the selected files on the clipboard, so they paste into Finder or anywhere else that takes files, and **Edit > Paste** (⌘V) brings files on the clipboard into the folder you're looking at. Pasting copies, never moves, and a name already in the folder is offered Keep Both, Replace or Skip, exactly as dragging is. In the viewer, ⌘C copies the picture on screen, edits and all, so it pastes into Mail or Pages as you see it.

### Undo

**Edit > Undo** (⌘Z) and **Edit > Redo** (⇧⌘Z) cover copies, moves, renames, new folders and Batch Rename. The menu names the step, as in "Undo Move 3 Items".

- Undoing a move puts each file back exactly where it was, under the name it had.
- Undoing a copy, or a new folder, moves it to the Trash, where it can still be recovered.
- Undoing a transfer that replaced something brings the replaced item back from the Trash.
- A file whose old place has been taken since isn't overwritten; minivu says some items couldn't be put back.

Ratings, tags, colour labels, keyword and metadata edits, collection changes, Custom Order rearrangements, Move to Trash and the lossless rotations below aren't on the Undo menu.

## The right-click menu

Right-click an item for **Open in Viewer**, **Rename**, **Copy To**, **Move To**, **Tag** (or **Remove Tag**), **Rating**, **Label**, **Add to Collection**, **Remove from Collection**, **Rotate Left**, **Rotate Right**, **Edit Comment…**, **Edit Metadata…**, **Reveal in Finder**, **Share…** and **Move to Trash**. Items that don't apply to the selection are greyed out, such as rating a folder, rotating a RAW file or a video, or Remove from Collection while no collection is shown. Right-click the grid's background for **New Folder**.

## Quick changes without the viewer

Some edits work straight on the selected files, without opening the viewer:

- **Image > Rotate Left** (⌘L), **Rotate Right** (⌘R), **Flip Horizontal** and **Flip Vertical** change the orientation tag of JPEG, HEIC, TIFF and PNG files, so the pixels are never re-encoded. RAW files, videos and other formats are skipped, and an alert afterwards says how many and of which kinds. The files change straight away.
- **Image > Edit Comment…** changes the comment of one selected JPEG.
- **Image > Edit Metadata…** (⌘I) changes the title, caption, creator, copyright, keywords and date taken of the selected images, and can remove their location. With several images selected, a field whose value differs shows "Mixed", and only the fields you change are written. JPEG, HEIC, PNG and TIFF files are changed without re-encoding the picture; RAW files and formats minivu can't rewrite get an XMP sidecar instead. PDF, SVG and video files are skipped. More than one file shows a progress sheet with **Cancel**.
- The **Keywords** editor in the preview pane adds and removes keywords of one image.
- **File > Save As…** (⇧⌘S) converts one selected image to another format.

See [Editing](Editing).

## Compare, slideshow and tools

**Image > Compare Selected** (⌥⌘K), or the toolbar's Compare button, opens the compare window with the two to four selected images side by side; ← and → there step through the rest of the folder in the browser's order. A video is compared by its first frame. See [Viewer](Viewer).

**Tools > Start Slideshow** (⇧⌘F), or the toolbar's Slideshow button, plays the selected images when two or more are selected. **Tools > Export Slideshow Video…** uses the same images, in the same order. Otherwise it plays every image the grid shows, starting from the selected one. Slideshows skip videos; started from a video, the show begins at the next picture. With only videos, Start Slideshow is greyed out.

**Tools > Batch Convert…**, **Extract Pages…**, **Create Multi-Page File…**, **Image Strip…**, **Contact Sheet…**, **Create Web Gallery…**, **Montage Wallpaper…** and **File > Print…** work on the selected images, or on every image the grid shows when none is selected. Folders never count, and these tools skip videos. **Tools > Batch Rename…** works the same way and renames videos too. **Tools > Find Duplicates…** looks in the selected images, the folder or list shown, or the folder and its subfolders; its **Show in Browser** button shows what it found as a list titled "Duplicates" or "Similar Images". **Tools > Set as Desktop Picture** uses the lead image, if it isn't a video. While a list is shown, the tools that make files start their panels in the lead image's folder and take the list's name as their title. See [Tools](Tools).

## The thumbnail cache

Thumbnails are made off the main thread. A cell that scrolls away before its thumbnail is ready cancels its request, and the row you stop on is made first, so a fast scroll decodes only where you stop. Thumbnails are made at two sizes, 256 and 512 pixels, and the cell scales one to fit, so moving the size slider doesn't decode the folder again. At most three video frames are decoded at once, however many thumbnails are waiting.

They are kept in two places:

- **In memory**, up to 200 MB, drawn in the colour space of the display the browser is on.
- **On disk**, as JPEG (PNG for images with transparency), in one SQLite file at `~/Library/Containers/com.minivu.app/Data/Library/Caches/minivu/thumbnails.sqlite`. It is trimmed to 1 GB at launch, least recently used first.

A cached thumbnail is used only while its file's modification date and size are unchanged, so an edited photo gets a new one. **Settings > Thumbnails > Clear Thumbnail Cache** empties the disk cache, and with it the fingerprints Find Duplicates keeps; thumbnails are made again from the original files the next time a folder is shown. Thumbnails already held in memory can still be used until minivu quits.

On the M1 Pro MacBook Pro minivu was developed on, scrolling a folder of 5,000 thumbnails stays smooth, with peak memory around 186 MB. See [Architecture](Architecture).
