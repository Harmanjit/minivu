# Privacy

## No network

minivu never connects to the internet. It runs in the App Sandbox without
the network entitlement, so macOS doesn’t let it open a connection at all.
There is no account, no analytics, no crash reporting and no update check,
and this help is part of the app.

Live Text, Remove Background, Copy Subject, red-eye detection, Perspective’s
Auto and Find Duplicates’ Similar Images use Apple’s Vision framework, on
your Mac. Nothing is sent anywhere.

**File > Share…** hands the files to the share service you pick, such as
AirDrop or Mail, which then sends them. minivu itself opens no connection.

## What minivu can see

The sandbox limits minivu to:

- your **Pictures** folder;
- folders and files you choose in an Open or Save panel, drop onto minivu,
  or open with minivu from Finder;
- folders in its sidebar and recent Copy To and Move To folders, which it
  remembers with bookmarks that only this Mac and this app can use;
- a picture chosen for a watermark, which it remembers with a read-only
  bookmark;
- its own container, `~/Library/Containers/com.minivu.app`.

It works only with your Mac’s internal storage, not memory cards, external
drives or network shares.

## What minivu keeps

In its container, on your Mac only:

- **The catalog** of star ratings, tags, custom orders, collections, smart
  folders, and the photo details read for filters and searches.
- **The thumbnail cache**, with the fingerprints Find Duplicates makes,
  which **Settings > Thumbnails > Clear Thumbnail Cache** empties.
- **Settings**, including the sidebar folders, recent folders, slideshow
  music, external editors and presets.

Searches read only folders minivu may see, on your Mac. minivu doesn’t ask
Spotlight.

## What minivu changes in your files

Only what you ask for:

- **Save** writes over the original, after asking. **Save As**, Batch
  Convert, Extract Pages, Create Multi-Page File, Image Strip, Contact
  Sheet, Montage, Export Slideshow Video and Create Web Gallery make new
  files.
- Rotate and flip in the browser change the orientation tag of a JPEG,
  HEIC, TIFF or PNG file, and Edit Comment changes a JPEG’s comment.
- **Edit Metadata** writes the details you change into the file, or into an
  XMP sidecar file beside it.
- **Image > Label** sets the file’s Finder color tag. Stars and tags are
  written into files only if you turn on **Write ratings into files (XMP)**
  in Settings.
- A minivu action in the Shortcuts app can convert, resize, rename, rate or
  label files that minivu may change.
- Rename, Move, Copy, New Folder and Batch Rename change names and folders,
  and can be undone.
- **Move to Trash** puts items in the Trash. When a copy, move, drop or
  paste replaces a file of the same name, the old file goes to the Trash.
  So does a file that Batch Convert, Extract Pages, Contact Sheet or Export
  Slideshow Video replaces.
- **Save**, and **Save As**, Create Multi-Page File, Image Strip or Save
  Frame As over an existing file, replace that file for good. It doesn’t go
  to the Trash, and this can’t be undone.
- Files are written in full first and then put in place, so an interrupted
  save never leaves half a file.

**Location.** Save As, Batch Convert, Create Web Gallery and the Shortcuts
actions leave out the GPS position and place names unless you turn off
**Remove location**. Save keeps everything, location included. A video’s
location is shown but never removed.

minivu also writes to **Pictures/minivu Captures** (screen captures) and
**Pictures/minivu Wallpapers** (montages, and copies made for Set as Desktop
Picture, of which it keeps the ten newest).

## Permissions

- **Screen Recording**, only if you use Capture > Entire Screen or
  Selection. You can turn it off in System Settings > Privacy & Security.
- **Printing**, through the standard print panel.

