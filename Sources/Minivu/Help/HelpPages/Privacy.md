# Privacy

## No network

minivu never connects to the internet. It runs in the App Sandbox without
the network entitlement, so macOS doesn’t let it open a connection at all.
There is no account, no analytics, no crash reporting and no update check,
and this help is part of the app.

## What minivu can see

The sandbox limits minivu to:

- your **Pictures** folder;
- folders and files you choose in an Open or Save panel, drop onto minivu,
  or open with minivu from Finder;
- folders in its sidebar and recent Copy To and Move To folders, which it
  remembers with bookmarks that only this Mac and this app can use;
- its own container, `~/Library/Containers/com.minivu.app`.

It works only with your Mac’s internal storage, not memory cards, external
drives or network shares.

## What minivu keeps

In its container, on your Mac only:

- **The catalog** of star ratings, tags and custom orders.
- **The thumbnail cache**, which **Settings > Thumbnails > Clear Thumbnail
  Cache** empties.
- **Settings**, including the sidebar folders, recent folders, slideshow
  music and external editors.

## What minivu changes in your files

Only what you ask for:

- **Save** writes over the original, after asking. **Save As**, Batch
  Convert, Contact Sheet and Montage make new files.
- Rotate and flip in the browser change a JPEG’s orientation tag, and Edit
  Comment changes its comment.
- Rename, Move, Copy, New Folder and Batch Rename change names and folders,
  and can be undone.
- **Move to Trash**, and replacing a file of the same name, put items in the
  Trash. minivu doesn’t delete your files.
- Files are written in full first and then put in place, so an interrupted
  save never leaves half a file.

minivu also writes to **Pictures/minivu Captures** (screen captures) and
**Pictures/minivu Wallpapers** (montages, and copies made for Set as Desktop
Picture, of which it keeps the ten newest).

## Permissions

- **Screen Recording**, only if you use Capture > Entire Screen or
  Selection. You can turn it off in System Settings > Privacy & Security.
- **Printing**, through the standard print panel.

Red-eye detection finds faces with Apple’s Vision framework, on your Mac.
