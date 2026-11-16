# Browser

The browser window has three parts: the sidebar of folders on the left, the
thumbnail grid in the middle, and the preview pane on the right, with the
selected photo, its stars and its file and camera details. Videos sit among
the photos.

## Folders

- The sidebar lists your favorite folders first, then the folder tree,
  then your smart folders and collections, once you have some. Choose
  **View > Show Sidebar** or **Show Preview Pane** to hide or show either
  side.
- Double-click a folder in the grid to open it. The toolbar’s back, forward
  and parent folder buttons, and the **Go** menu, move between folders.
- **View > Show Hidden Files** shows files whose names start with a dot.
- **View > Flat View** (**⌥⌘F**) shows the images of the folder and of
  every folder inside it as one list, without the subfolders themselves.
  It stays on as you move between folders. Hover over a thumbnail to see
  which folder it is in. **New Folder** is off in the flat view.
- The status bar at the bottom counts the images, and while a filter is on
  it says how many are shown, as in “12 of 340 shown”.

## Sort and filter

- **View > Sort By** sorts by name, date modified, date created, rating,
  custom order, size or type. Each one remembers whether it was ascending or
  descending, as Finder’s columns do.
- **Custom Order** is your own arrangement: drag thumbnails where you want
  them. Each folder keeps its own order, and new files go after it, by name.
- The toolbar’s **Filter** menu, and **View > Filter**, show everything,
  images with at least one to five stars, tagged images only, photos only
  or videos only. The toolbar’s menu also lists the folder’s Finder tags.
  **Show All** turns every filter off. A filter stays on as you move
  between folders, and it never hides folders.
- **More Filters…** in the same menu filters by file type, date taken,
  camera model, lens, ISO, aperture, focal length, keywords, color label,
  location, orientation and minimum size. Type and label filter at once;
  for the rest minivu reads each file in the background, and images appear
  as they are found to match.
- The search field in the toolbar filters the folder by name.
- The toolbar sets the thumbnail size too.

## Stars and tags

Each image can have 0 to 5 stars and a tag, the quick “keep” mark for
sorting through a shoot. It can also have a color label.

- Hover over the space under a thumbnail’s name and click a star to rate.
  Click the current rating again to clear it.
- With images selected, press **0** to **5** to rate them, or the backquote
  key (**`**) to tag them. **Image > Rating** and **Image > Tag** do
  the same from any window.
- Toggling the tag on a mixed selection tags all of it; it untags only when
  every image was already tagged.
- A tagged image shows a checkmark on its corner. The colored dots after a
  name are its Finder tags.
- **Image > Label** (**⌥⌘0** to **⌥⌘7**) gives the selected images a color
  label: None, Red, Orange, Yellow, Green, Blue, Purple or Gray. The label
  is the file’s Finder color tag, so Finder shows it too. Choosing a label
  replaces the file’s other color tag and keeps its named tags.
- **Edit > Select Tagged** selects the tagged images shown, and **Edit >
  Invert Selection** (**⇧⌘I**) selects everything shown that wasn’t
  selected.

Stars and tags are kept in minivu’s own catalog on your Mac. They are
written into the files too only if you turn on **Write ratings into files
(XMP)** in **Settings > General**. XMP is a standard way to store details
inside a photo, which Lightroom, Bridge and other apps read. Ratings that
those apps wrote into a file show in minivu for photos you haven’t rated
here.

## Organize files

- Drag files onto the grid, a folder or a sidebar folder to put them there.
  As in Finder, a drag on the same disk moves and a drag to another disk
  copies; hold **Option** to copy or **Command** to move.
- **File > Copy To** and **Move To** remember the last five folders you
  chose.
- **File > Rename** (F2) edits the name in place: Return keeps it, Esc
  cancels. **File > New Folder** makes a folder and starts renaming it.
- **Edit > Copy** (**⌘C**) puts the selected files on the clipboard, and
  **Edit > Paste** (**⌘V**) copies files from the clipboard into the folder
  shown.
- **File > Move to Trash** moves the selection to the Trash, and **Reveal in
  Finder** shows it there.
- **File > Share…**, or the toolbar’s **Share** button, sends the selected
  images with AirDrop, Messages, Mail and the other ways your Mac offers.
- If a file of the same name is already there, minivu asks whether to
  replace it, keep both or skip, before anything moves. A replaced file goes
  to the Trash, never straight to deletion.
- Moves, copies, renames and new folders can be undone with **Edit > Undo**.

## Quick changes without opening the viewer

- **Image > Rotate Left**, **Rotate Right** and the flips turn JPEG, HEIC,
  TIFF and PNG files by changing their orientation tag, so the pixels are
  never re-encoded.
  Files that can’t turn that way, such as RAW files, are skipped and listed.
  These change the files straight away.
- **Image > Edit Comment…** changes a JPEG’s comment.
- **Image > Edit Metadata…** (**⌘I**) changes the title, caption, creator,
  copyright, keywords and date taken of the selected images, and can remove
  their location. See [Editing](help:Editing).
- The preview pane lists a photo’s keywords at the end. Click the x on a
  keyword to remove it, or type new ones, separated by commas, and press
  Return.
- **File > Save As…** converts the selected image to another format.
- **Image > Compare Selected** shows two to four images side by side. See
  [Viewer](help:Viewer).

## Find across folders

**Edit > Find…** (**⌘F**) searches Pictures, a sidebar folder or the folder
shown, with or without subfolders. Search by name, rating, the tag, and
everything More Filters offers. The results replace the grid as a list;
**Go > Back** returns to the folder. Most commands work on the list, but
New Folder, Paste and Custom Order don’t, because the images come from many
folders.

**File > Save as Smart Folder…** keeps the search in the sidebar under
**Smart Folders**. Clicking it runs the search again, so new files are
found. Control-click it to edit the search, rename it or delete it.

## Collections

A collection is a list of images you choose, from any folders. The files
stay where they are.

- **File > New Collection…** makes a collection of the selected images.
- **File > Add to Collection** adds images to one, or drag them onto its
  row under **Collections** in the sidebar.
- Click the row to see the collection. **View > Sort By > Custom Order**
  shows the images in the order you added them.
- **File > Remove from Collection** takes images out of the collection,
  never out of their folders. Control-click the row to rename or delete
  the collection.

## Videos

Videos show in the grid with a play mark and their length, and in the
preview pane with their length beside the stars. Rate, tag, label, rename,
move and share them as you would photos. Double-click one to play it in the
[viewer](help:Viewer). minivu doesn’t edit or convert videos.
