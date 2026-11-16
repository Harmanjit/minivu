# Security and Privacy

## No network

minivu makes no network requests. There is no account, telemetry, analytics, crash reporting or update check. The app bundle has no network entitlement, so macOS enforces this: the process can't open a connection, incoming or outgoing. The help is part of the app, and its pages may link only to each other; any other link is refused, so the Help window never opens a browser.

Some features look at the content of your pictures. All of them use Apple's frameworks on your Mac, and nothing is sent anywhere:

- **Red-Eye Removal**'s **Auto Detect** finds faces, and **Perspective…** finds the edges of a rectangle, with Apple's Vision framework.
- **Remove Background…** and **Edit > Copy Subject** find the subject of a picture with Vision.
- **Live Text** (**View > Live Text**, on by default) recognises text in the viewer's picture. minivu asks only for text. It never asks for *Visual Look Up* (identifying plants, landmarks or art), which would ask Apple's servers. It also turns off *data detectors*, which would underline addresses, phone numbers and links and open Maps, FaceTime or Safari when clicked. Turn Live Text off and minivu doesn't look for text at all.
- **Find Duplicates** compares pictures with *feature prints*: short summaries of what a picture looks like, made by Vision and kept in minivu's thumbnail cache.
- **Edit > Find…** reads the folders you search itself. It doesn't ask Spotlight.

Two features hand your files to other programs, which then work with their own permissions, outside minivu's sandbox. minivu itself still opens no connection:

- **File > Share…** gives the selected files, as they are on disk, to the system's share sheet: AirDrop, Messages, Mail and the like. Each service runs in its own process. If the image has unsaved edits in the viewer, minivu says first that the file is shared as last saved.
- **Tools > Open in External Editor** asks macOS to open the original files in the app you chose (see below).

minivu has no third-party code. Below the app there are only Apple's frameworks (AppKit, SwiftUI, Metal, Core Image, ImageIO, PDFKit, AVFoundation, AVKit, ScreenCaptureKit, Vision, VisionKit, App Intents and the system SQLite), so there are no libraries to vendor or pin. Image and video files are decoded by those frameworks inside minivu's own process; there is no separate decoder process, so the sandbox below is what contains a file crafted to exploit a decoder.

## Sandbox and hardened runtime

`scripts/make_app.sh` signs the app ad hoc with the hardened runtime and the App Sandbox. No Apple developer account is involved, and the app isn't notarised (see [Installation](Installation)); the sandbox is enforced from the signature regardless. These are the entitlements, from [scripts/minivu.entitlements](https://github.com/Harmanjit/minivu/blob/main/scripts/minivu.entitlements), and nothing else:

| Entitlement | What it allows |
|---|---|
| `com.apple.security.app-sandbox` | Turns the sandbox on |
| `com.apple.security.files.user-selected.read-write` | Reading and writing the files and folders you choose in an Open or Save panel, drop on minivu, or open with minivu from Finder |
| `com.apple.security.files.bookmarks.app-scope` | Remembering those choices between launches |
| `com.apple.security.assets.pictures.read-write` | Your Pictures folder, from the first launch |
| `com.apple.security.print` | **File > Print…** reaching the printing system |

`com.apple.security.network.client` and `network.server` are deliberately absent. So minivu can reach only your Pictures folder, what you chose, and its own container, `~/Library/Containers/com.minivu.app`. None of the features added since the first release needed a new entitlement.

Choices are remembered with app-scoped security bookmarks, which only this app on this Mac can use: folders in the sidebar (removing one forgets its bookmark), the last five folders used with **Copy To** and **Move To**, the folder **Batch Convert** writes to (also inside a saved preset), the songs and folders of slideshow music, the applications in **Settings > Editors**, and the picture chosen for a **Watermark…**, which is kept as a read-only bookmark so the watermark can be drawn again later.

`scripts/make_app.sh --dev` builds the same app without the sandbox, for testing with folders passed on the command line; the sandbox rules on this page don't apply to that build.

## Internal storage only

minivu refuses folders on removable, ejectable, external or network volumes: memory cards, USB drives, external disks, disk images and network shares. If minivu can't read a volume's properties, it refuses the folder too, and the Open panel greys out folders on volumes it would refuse. The rule applies to opening a folder, adding one to the sidebar, the folder minivu reopens at launch, files opened from Finder, drops, **Copy To** and **Move To** destinations, the **Batch Convert** destination, the files saved by **Create Multi-Page File…** and **Image Strip…**, the folder **Create Web Gallery…** writes into, the file **Export Slideshow Video…** writes, a **Watermark…** picture, and every file a Shortcuts action is given. **Flat View** and **Find…** leave out an external disk that is mounted inside a folder they walk. See [Limitations](Limitations).

## Damaged and crafted files

A picture file says how big it is in its header, and a damaged or deliberately crafted file can claim anything. minivu checks those claims before it acts on them:

- **Absurd sizes are refused.** An SVG or PDF that claims a size far beyond any real drawing (more than about 176 metres a side) is refused as too large, instead of being sized from the file. Such a file used to be able to stop the app.
- **Animations are held to a memory limit.** An animated image that claims a huge canvas is played within a budget set by your Mac's memory, however far you zoom in, rather than asking for gigabytes.
- **Exports check the size first.** Batch Convert, Save of an unedited original, and the other tools that decode at full size compare the size a file claims with a budget of a quarter of your Mac's memory before decoding it. A file past it is refused and named, and the rest of a batch goes on. A *decompression bomb*, a small file that claims to be enormous, can't make minivu run out of memory this way.
- **Thumbnails** are not made for a file that claims more than 32768 × 32768 pixels.

## Location in saved and converted files

A photo's *location* is the GPS position the camera or phone recorded, and any place names (city, country) added later. minivu keeps it in your originals and, by default, leaves it out of copies you make:

- **Save** writes over the original and always keeps its metadata, including the location, in the formats that carry it, so overwriting a photo never quietly strips its EXIF.
- **Save As…** and **Batch Convert…** have **Keep metadata (EXIF, GPS, IPTC, XMP)**, on by default, and under it **Remove location**, also on by default. Both are remembered with the other options. With both on, the new file keeps the camera, lens, exposure and date details and the other metadata, but not the GPS position or the place names. Turn **Remove location** off to keep the location as well. Turn **Keep metadata** off and the file gets its colour profile and nothing else.
- **Writing over the original keeps the location**, whatever **Remove location** says, because that is the only copy: **Save As…** onto the original's own name, and a Batch Convert output that replaces its own source.
- Camera and lens serial numbers, and dates, are not location. They stay while **Keep metadata** is on.
- JPEG 2000, GIF, BMP, TGA and ICO don't carry metadata, so the options aren't offered and those files have none.
- Kept metadata is cleaned up for the new image: the orientation is reset (the pixels are already upright), the pixel size updated, any embedded thumbnail dropped, and Camera Raw develop settings and gain-map descriptions removed.
- **Image > Edit Metadata…** (⌘I) has **Remove location**, which removes it from the files themselves. A camera RAW file is never modified, so its own location stays; minivu says so for each such file.
- **Create Web Gallery…** has **Keep metadata** and **Remove location**, both on by default. Thumbnails never carry metadata. With **Include the original files** on, each original is copied byte for byte except its location, which is removed without re-encoding. An original whose location can't be removed (a camera RAW file, or a format minivu can't rewrite) is left out of the gallery, and minivu names it afterwards.
- The Shortcuts actions **Convert Images** and **Resize Images** have **Remove Location**, on by default.
- **Rotate Left**, **Rotate Right** and the flips in the browser change only the orientation tag of JPEG, HEIC, TIFF and PNG files, without re-encoding the pixels; RAW files are never modified. **Edit Comment…** changes only a JPEG's comment.
- Screen captures, montages, contact sheets, desktop picture copies, multi-page files, image strips, and frames saved or copied from a video are written with no metadata.
- A video's location is shown in the info panel but can't be removed or edited.

## Screen recording

**Tools > Capture > Entire Screen** and **Selection…** need Screen Recording permission, which macOS asks for the first time. If it is refused, minivu says where to turn it on (then quit and reopen minivu); you can turn it off in **System Settings > Privacy & Security > Screen & System Audio Recording**. **Window…** uses the system's own window picker, where picking a window is the consent, and needs no permission. Captures leave out the pointer, and minivu's own windows are left out of screen and selection captures and of the window picker. They are saved as PNG files in **Pictures/minivu Captures**.

## External editors

**Tools > Open in External Editor** asks macOS to open the original files in the application you chose. That application then works on them with its own permissions, outside minivu's sandbox. minivu watches the files so the viewer can show what the editor saves. If the image has unsaved edits in minivu, it warns first that the editor gets the file as last saved, and opening more than 20 images at once is confirmed.

## Shortcuts

minivu offers six actions to the Shortcuts app: **Convert Images**, **Resize Images**, **Rename Images**, **Set Rating**, **Set Colour Label** and **Open in minivu**. [Tools](Tools) describes them. What they can and can't do:

- **Who can run them.** Only macOS, on behalf of Shortcuts, Spotlight or Siri: a shortcut you built or added, or one of minivu's ready-made ones that you run. Other apps can't call them directly. A script can run one of your shortcuts with the `shortcuts` command, but only a shortcut that already exists.
- **Same sandbox.** The actions run inside minivu, with the same sandbox and entitlements as everything else. They read only the files the shortcut passes, and refuse the whole action if any of them is on an external, removable or network volume.
- **They never overwrite.** **Convert Images** and **Resize Images** write new files into a folder inside minivu's container and hand them back to the shortcut; the shortcut's next step (Save File, for example) decides where they go. Shortcuts removes each file once it has taken it, and minivu removes run folders older than a day.
- **Changes only where minivu may already write.** **Rename Images** works only in Pictures and the folders in minivu's sidebar, and checks every folder before it renames anything: if one isn't allowed, nothing is renamed. **Set Colour Label** checks that minivu may change every file first. **Set Rating** changes minivu's catalog (and the file too, only while **Write ratings into files (XMP)** is on).
- **Nothing is deleted.** The most a shortcut can do through minivu is rename images, set ratings and set colour labels.
- **No AppleScript.** minivu has no scripting dictionary and accepts no Apple Events beyond the standard "open these files" that Finder sends.

## Web galleries

**Tools > Create Web Gallery…** writes plain HTML pages with no scripts and no links to other sites. Every file name, title and caption is escaped before it goes into a page, so a name can't add code or a link. The gallery is written in a hidden folder first and appears under its name only when it is complete, so Cancel or a failure leaves nothing behind.

## Your files

minivu changes your files only when you ask:

- **Written whole, then put in place.** Every image write (Save, Save As, a lossless rotate, a comment, a metadata edit, a batch conversion) goes to a hidden temporary file in the same folder, is flushed to disk, and only then takes the real name. An interrupted save leaves the old file as it was, never half a file. When a Save panel granted only the one file, the temporary file goes in the system's replacement folder on the same volume, so the swap is still atomic. A file saved over this way keeps its creation date, permissions and extended attributes, Finder tags included. A folder is never replaced by a file. Because the saved file is a new file, a hard link to the old one keeps the old picture; a symbolic link is followed and the file it points at is replaced.
- **One write at a time.** All image writes run in a single queue, in the order you asked for them, so ⌘S, another edit and ⌘S again land in that order. Moving, renaming or trashing a file waits for the writes queued for it, and quitting waits for writes in progress. Ratings, tags and order changes still queued at quit are written first. Batch renames, from any window or any shortcut, also run one at a time.
- **Replaced items go to the Trash.** A name clash in a drop, **Copy To** or **Move To** asks Replace, Keep Both or Skip before anything moves, and a replaced item goes to the Trash; if the new item then can't arrive, the old one comes back. **Batch Convert** asks before replacing anything and trashes what it replaces, and so do a contact sheet and a slideshow video saved over a file. Undoing a copy or a new folder moves it to the Trash. **Find Duplicates** moves files to the Trash only after you mark them and confirm; it never marks anything by itself.
- **Save** replaces the original after asking (tick **Don’t ask again** to stop the question, and turn it back on with **Ask before saving over the original** in **Settings > General**). It can't be undone and doesn't use the Trash; **Save As…** onto an existing file replaces it after the Save panel asks.
- **Metadata edits.** **Edit Metadata…**, the keyword editor in the info panel and **Edit Comment…** write into the file without re-encoding its pixels. Camera RAW files and formats minivu can't rewrite that way get an *XMP sidecar* instead: a small `.xmp` file with the same name beside the photo.
- **Colour labels** (**Image > Label**) are the file's Finder colour tag, written in its extended attributes as Finder does. Choosing one replaces the file's other standard colour tag and keeps every other tag.
- **Ratings and the tag** stay in minivu's catalog. They go into the files too, as XMP (or a sidecar), only while **Settings > General > Write ratings into files (XMP)** is on. It is off by default.
- **What minivu deletes** is only what it made: desktop picture copies beyond the ten newest (never one a display is showing, though a copy set as the desktop picture on another Space can be removed while still in use there), montages from a run that was cancelled or failed, the files made for a shortcut once it has taken them, and its own temporary files.

Custom orders, collections and smart folders stay in minivu's catalog and are never written into files. Finder tags other than the colour label are read and filtered by, never changed.

## What is written, and where

- **The catalog**, `Application Support/minivu/catalog.sqlite` in the container: star ratings, tags, custom orders, collections, smart folders, and a cache of the details the filters need (such as date taken, camera, lens and exposure) for files you have filtered or searched. A file's row keeps its path, volume, file identifier, size and modification date, so a file moved in Finder keeps its marks and collections; rows for files missing for a year are forgotten. A custom order keeps the names of the files in that folder. A damaged catalog is renamed aside as `catalog.sqlite.damaged-<timestamp>` rather than deleted, and a fresh one starts.
- **The thumbnail cache**, `Caches/minivu/thumbnails.sqlite` in the container: small JPEG or PNG copies of pictures you have browsed, keyed by path and trimmed back to 1 GB of image data at launch, least recently used first, and the file hashes and feature prints **Find Duplicates** made. **Settings > Thumbnails > Clear Thumbnail Cache** empties both. A damaged cache is deleted and started afresh, since it holds nothing that can't be rebuilt.
- **Settings**, in the container's preferences: everything in Settings, the last folder, the bookmarks above, the external editors, Batch Convert and Batch Rename presets, and the options last used for Save As, Batch Convert, Batch Rename, Extract Pages, Create Multi-Page File, Image Strip, Contact Sheet, Create Web Gallery, Export Slideshow Video, Montage Wallpaper, Find Duplicates and printing.
- **The container's temporary folder**: files made for a shortcut, until the shortcut has taken them.
- **Pictures/minivu Captures**: screen captures.
- **Pictures/minivu Wallpapers**: montages, which stay, and copies made by **Set as Desktop Picture** when a photo can't be used as it is, of which the ten newest are kept.
- **Your folders**: only files you save, convert, rename, move, copy or make there, metadata you edit, Finder colour tags you set, XMP sidecars beside files that need one, and web galleries, slideshow videos, multi-page files and strips where you save them.
- **The unified log**, subsystem `com.minivu.app`: failures such as a catalog that couldn't be read. A slideshow that skips an image logs its file name.

The snapshot harness that drives windows from environment variables is compiled into debug builds only; a release build neither reads those variables nor contains the code that sends actions.
