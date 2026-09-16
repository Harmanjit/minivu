# Security and Privacy

## No network

minivu makes no network requests. There is no account, telemetry, analytics, crash reporting or update check. The app bundle has no network entitlement, so macOS enforces this: the process can't open a connection, incoming or outgoing. The help is part of the app, and its pages may link only to each other; any other link is refused, so the Help window never opens a browser. **Red-Eye Removal**'s **Auto Detect** finds faces with Apple's Vision framework, on your Mac.

minivu has no third-party code. Below the app there are only Apple's frameworks (AppKit, SwiftUI, Metal, Core Image, ImageIO, PDFKit, AVFoundation, ScreenCaptureKit, Vision and the system SQLite), so there are no libraries to vendor or pin. Image files are decoded by those frameworks inside minivu's own process; there is no separate decoder process, so the sandbox below is what contains a file crafted to exploit a decoder.

## Sandbox and hardened runtime

`scripts/make_app.sh` signs the app ad hoc with the hardened runtime and the App Sandbox. No Apple developer account is involved, and the app isn't notarised (see [Installation](Installation)); the sandbox is enforced from the signature regardless. These are the entitlements, from [scripts/minivu.entitlements](https://github.com/Harmanjit/minivu/blob/main/scripts/minivu.entitlements), and nothing else:

| Entitlement | What it allows |
|---|---|
| `com.apple.security.app-sandbox` | Turns the sandbox on |
| `com.apple.security.files.user-selected.read-write` | Reading and writing the files and folders you choose in an Open or Save panel, drop on minivu, or open with minivu from Finder |
| `com.apple.security.files.bookmarks.app-scope` | Remembering those choices between launches |
| `com.apple.security.assets.pictures.read-write` | Your Pictures folder, from the first launch |
| `com.apple.security.print` | **File > Print…** reaching the printing system |

`com.apple.security.network.client` and `network.server` are deliberately absent. So minivu can reach only your Pictures folder, what you chose, and its own container, `~/Library/Containers/com.minivu.app`.

Choices are remembered with app-scoped security bookmarks, which only this app on this Mac can use: folders in the sidebar (removing one forgets its bookmark), the last five folders used with **Copy To** and **Move To**, the folder **Batch Convert** writes to, the songs and folders of slideshow music, and the applications in **Settings > Editors**.

`scripts/make_app.sh --dev` builds the same app without the sandbox, for testing with folders passed on the command line; the sandbox rules on this page don't apply to that build.

## Internal storage only

minivu refuses folders on removable, ejectable, external or network volumes: memory cards, USB drives, external disks, disk images and network shares. If minivu can't read a volume's properties, it refuses the folder too, and the Open panel greys out folders on volumes it would refuse. The rule applies to opening a folder, adding one to the sidebar, the folder minivu reopens at launch, files opened from Finder, drops, **Copy To** and **Move To** destinations, and the **Batch Convert** destination. See [Limitations](Limitations).

## Location in saved and converted files

- **Save** writes over the original and always keeps its metadata, including the GPS position, in the formats that carry it (below), so overwriting a photo never quietly strips its EXIF.
- **Save As…** and **Batch Convert…** have **Keep metadata (EXIF, GPS, IPTC, XMP)**, on by default for JPEG, PNG, HEIC and TIFF and remembered with the other options. With it on, the new file carries the source's EXIF, GPS, IPTC, TIFF and XMP, which includes where the photo was taken and any camera and lens serial numbers the file holds. There is no separate switch for location: to leave it out, turn the option off, and the file gets its colour profile and nothing else.
- JPEG 2000, GIF, BMP, TGA and ICO don't carry metadata, so the option isn't offered and those files have none.
- Kept metadata is cleaned up for the new image: the orientation is reset (the pixels are already upright), the pixel size updated, any embedded thumbnail dropped, and Camera Raw develop settings and gain-map descriptions removed.
- **Rotate Left**, **Rotate Right** and the flips in the browser change only the orientation tag of JPEG, HEIC, TIFF and PNG files, without re-encoding the pixels; RAW files are never modified. **Edit Comment…** changes only a JPEG's comment.
- Screen captures, montages, contact sheets and desktop picture copies are written with no metadata.

## Screen recording

**Tools > Capture > Entire Screen** and **Selection…** need Screen Recording permission, which macOS asks for the first time. If it is refused, minivu says where to turn it on (then quit and reopen minivu); you can turn it off in **System Settings > Privacy & Security > Screen & System Audio Recording**. **Window…** uses the system's own window picker, where picking a window is the consent, and needs no permission. Captures leave out the pointer, and minivu's own windows are left out of screen and selection captures and of the window picker. They are saved as PNG files in **Pictures/minivu Captures**.

## External editors

**Tools > Open in External Editor** asks macOS to open the original files in the application you chose. That application then works on them with its own permissions, outside minivu's sandbox. minivu watches the files so the viewer can show what the editor saves. If the image has unsaved edits in minivu, it warns first that the editor gets the file as last saved, and opening more than 20 images at once is confirmed.

## Your files

minivu changes your files only when you ask:

- **Written whole, then put in place.** Every image write (Save, Save As, a lossless rotate, a comment, a batch conversion) goes to a hidden temporary file in the same folder, is flushed to disk, and only then takes the real name. An interrupted save leaves the old file as it was, never half a file. When a Save panel granted only the one file, the temporary file goes in the system's replacement folder on the same volume, so the swap is still atomic. A file saved over this way keeps its creation date, permissions and extended attributes, Finder tags included. A folder is never replaced by a file. Because the saved file is a new file, a hard link to the old one keeps the old picture; a symbolic link is followed and the file it points at is replaced.
- **One write at a time.** All image writes run in a single queue, in the order you asked for them, so ⌘S, another edit and ⌘S again land in that order. Moving, renaming or trashing a file waits for the writes queued for it, and quitting waits for writes in progress. Ratings, tags and order changes still queued at quit are written first.
- **Replaced items go to the Trash.** A name clash in a drop, **Copy To** or **Move To** asks Replace, Keep Both or Skip before anything moves, and a replaced item goes to the Trash; if the new item then can't arrive, the old one comes back. **Batch Convert** asks before replacing anything and trashes what it replaces, and so does a contact sheet saved over a file. Undoing a copy or a new folder moves it to the Trash.
- **Save** replaces the original after asking (tick **Don’t ask again** to stop the question, and turn it back on with **Ask before saving over the original** in **Settings > General**). It can't be undone and doesn't use the Trash; **Save As…** onto an existing file replaces it after the Save panel asks.
- **What minivu deletes** is only what it made: desktop picture copies beyond the ten newest (never one a display is showing, though a copy set as the desktop picture on another Space can be removed while still in use there), montages from a run that was cancelled or failed, and its own temporary files.

Stars, tags and custom order stay in minivu's catalog; they aren't written into files or Finder tags. Finder tags are read and filtered by, never changed.

## What is written, and where

- **The catalog**, `Application Support/minivu/catalog.sqlite` in the container: star ratings, tags and custom orders. A file has a row only while it has a rating or a tag, with its path, volume, file identifier, size and modification date, so a file moved in Finder keeps its marks; rows for files missing for a year are forgotten. A custom order keeps the names of the files in that folder. A damaged catalog is renamed aside as `catalog.sqlite.damaged-<timestamp>` rather than deleted, and a fresh one starts.
- **The thumbnail cache**, `Caches/minivu/thumbnails.sqlite` in the container: small JPEG or PNG copies of pictures you have browsed, keyed by path and trimmed back to 1 GB of image data at launch, least recently used first. **Settings > Thumbnails > Clear Thumbnail Cache** empties it. A damaged cache is deleted and started afresh, since it holds nothing that can't be rebuilt.
- **Settings**, in the container's preferences: everything in Settings, the last folder, the bookmarks above, the external editors, and the options last used for Save As, Batch Convert, Batch Rename, Contact Sheet, Montage Wallpaper and printing.
- **Pictures/minivu Captures**: screen captures.
- **Pictures/minivu Wallpapers**: montages, which stay, and copies made by **Set as Desktop Picture** when a photo can't be used as it is, of which the ten newest are kept.
- **Your folders**: only files you save, convert, rename, move, copy or make there.
- **The unified log**, subsystem `com.minivu.app`: failures such as a catalog that couldn't be read. A slideshow that skips an image logs its file name.

The snapshot harness that drives windows from environment variables is compiled into debug builds only; a release build neither reads those variables nor contains the code that sends actions.
