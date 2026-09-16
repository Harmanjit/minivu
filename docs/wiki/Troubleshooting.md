# Troubleshooting

**macOS says minivu can't be opened, or can't be checked for malware.**
The app is signed ad hoc and isn't notarised, so Gatekeeper stops it the first time on any Mac but the one that built it. Try to open it once, then click **Open Anyway** in **System Settings > Privacy & Security**. Since macOS 15, Control-click > Open no longer skips this step. Alternatively, run `xattr -dr com.apple.quarantine /Applications/minivu.app`. See [Installation](Installation).

**"minivu only works with folders on this Mac's internal storage."**
Memory cards, USB and external drives, disk images and network shares are refused by design. Opening such a file from Finder says the same about files. Copy the photos to a folder on the Mac, then open that folder.

**"minivu doesn't have permission to open" a folder.**
The sandbox lets minivu into your Pictures folder, folders and files you chose in an Open or Save panel or dropped on it, folders in its sidebar and recent Copy To and Move To folders, and nothing else. The message usually appears after **Go > Enclosing Folder** (⌘↑) climbs above a folder you opened, or **Go > Back** returns to a folder whose access has gone. Choose **File > Open Folder…** (⌘O) and select the folder, or add a folder that contains it with **File > Add Folder to Sidebar…** (⇧⌘O).

**A folder passed on the command line doesn't open.**
The sandboxed bundle can't read arbitrary paths. For testing, build with `scripts/make_app.sh --dev`, which leaves the sandbox out, and run `open build/minivu.app --args <path>`; or use the debug build, `.build/debug/minivu <path>`.

**"The item may have been moved or deleted, or minivu may not have permission to read it."**
A file or folder opened from Finder, the Dock or the command line has gone, or is somewhere the sandbox doesn't reach. Check it still exists, then open it with **File > Open Folder…**.

**Tools > Capture > Entire Screen or Selection… says "minivu needs permission to capture the screen".**
Click **Open System Settings**, turn on minivu in **Privacy & Security > Screen & System Audio Recording**, then quit and reopen minivu. macOS shows its own prompt only the first time; after that, minivu's alert is what you see. **Tools > Capture > Window…** needs no permission, since picking a window in the system's picker is consent. If minivu is already turned on and capture is still refused, which can happen after the app is rebuilt and signed again, reset the permission and allow it once more:

```bash
tccutil reset ScreenCapture com.minivu.app
```

**An HDR photo doesn't look HDR.**
Check, in order:

- **Settings > Viewer > Display HDR photos in HDR** is on.
- The screen can show HDR: the Liquid Retina XDR display of a MacBook Pro, a Pro Display XDR, or an external display with HDR turned on in **System Settings > Displays**. Other screens show HDR photos tone mapped, which is expected.
- The screen's brightness. The room above white shrinks as brightness goes up, so highlights stand out less on a bright screen.
- The file really is HDR: a gain-map photo, or one encoded with PQ or HLG. An ordinary JPEG isn't, however bright.
- For RAW files, **Render RAW files with extended dynamic range** is on. It can only be turned on while **Display HDR photos in HDR** is.

Thumbnails, prints, contact sheets and **Save As** are always SDR; only the viewer, the preview pane, Compare and the slideshow show HDR. See [Viewer](Viewer).

**A RAW file looks soft when zoomed in, or its colours differ from another app's.**
With **Settings > Viewer > RAW files** set to **Embedded preview (faster)**, minivu shows the JPEG the camera saved inside the file wherever it is large enough, with the camera's own colours, and renders the RAW data only where the preview is too small. Choose **Render RAW data** to use Apple's RAW engine at every size; each photo then takes a moment.

**A RAW file doesn't open, shows small, or doesn't appear in the browser.**
minivu decodes RAW files with Apple's RAW engine, so it opens the cameras macOS supports. A camera macOS doesn't know shows only the preview it embedded, at the size the camera stored, and a file without a preview may not show at all. A newer macOS may add the camera. A RAW file with an extension minivu doesn't list doesn't appear in the browser at all. See [Limitations](Limitations).

**"minivu can't display" an image.**
The file is damaged, isn't what its extension says, or is a format macOS can't decode (PCX, WMF, EPS and X3F among them). Try opening it in Preview: if Preview can't either, neither can minivu.

**The first image after launch takes a moment.**
When the app was built without Xcode's Metal toolchain, it compiles its shaders from source when it starts. That runs on a background thread, so the browser window appears at once, but an image opened in the first fraction of a second waits for it. Installing the toolchain (`xcodebuild -downloadComponent MetalToolchain`) and running `scripts/make_app.sh` again precompiles them. To see how long it took, run the app from Terminal with `MINIVU_TRACE=1 build/minivu.app/Contents/MacOS/minivu`, which prints "Metal ready in …".

**A thumbnail shows an old version of a photo.**
Thumbnails are made again when a file's modification date or size changes. A tool that rewrites a file and keeps both the same leaves the old thumbnail. Choose **Settings > Thumbnails > Clear Thumbnail Cache**, then quit and reopen minivu, since thumbnails already in memory stay until then. Clearing the cache never touches your photos.

**"… was changed by another application."**
Another application saved the photo while you had unsaved edits of it in the viewer. **Reload** shows the version saved there and discards your edits. **Keep My Edits** (the default) keeps them, and Save then asks for a new name, so neither version is lost. If the change landed during a Save, minivu doesn't replace the file and says to use **Save As** instead.

**Save opens Save As.**
Either minivu can't write that file back (RAW, WebP, AVIF, JPEG XL, PDF, SVG and Photoshop files, animations, and files holding more than one image, such as a multi-page TIFF), or the file was changed by another application since you started editing and you chose to keep your edits.

**Save no longer asks "Replace the original?".**
You ticked **Don't ask again** once. Turn **Settings > General > Ask before saving over the original** back on.

**Stars and tags are missing.**

- **Files moved or renamed in Finder** get their marks back when you open the folder they are now in, in minivu.
- **A development build** without the sandbox (`swift run`, `.build/debug/minivu`, `scripts/make_app.sh --dev`) keeps its catalog in `~/Library/Application Support/minivu/`, not in the app's container, so it has marks of its own. Snapshot runs, test runs and `MINIVU_CATALOG=memory` use a catalog in memory that is gone when they quit.
- **A damaged catalog** is set aside, not deleted: minivu renames it `catalog.sqlite.damaged-<timestamp>` (with its `-wal` and `-shm` files) in the same folder and starts a fresh one. The old file is there for recovery by hand; delete it if you don't need it.
- **A catalog that can't be opened at all** is replaced for that session by a temporary one in memory, and the log says "Catalog unavailable, using a temporary one". Marks made then are gone when minivu quits.

**An external editor "can't be found".**
The application was moved or deleted since you added it. Click **Edit Editor List…** in the alert, or open **Settings > Editors**, and add it again.

**Quitting takes a moment.**
minivu asks about unsaved edits, then waits for saves still being written, lets a copy or move stop after the file it is on, and lets a batch rename under way finish. Nothing is cut off half-written.

**Help shows "Page Unavailable", or minivu crashes as soon as it opens.**
The app bundle is missing one of its resource bundles: the help pages, or the Metal shaders, without which it can't start. This happens when the executable is copied on its own. Build the app with `scripts/make_app.sh`, which copies both into `Contents/Resources`.

**Where are the logs?**
minivu logs to the unified log under the subsystem `com.minivu.app`: catalog failures, a damaged catalog set aside, a renderer that couldn't start, slides a slideshow skipped. To watch live:

```bash
log stream --predicate 'subsystem == "com.minivu.app"' --level info
```

Errors from the last hour, after the fact: `log show --last 1h --predicate 'subsystem == "com.minivu.app"'`. Crash reports are in the Console app under **Crash Reports**. minivu has no network access, so nothing is ever sent anywhere; attach what you find to an issue yourself.

**Starting over: settings, thumbnails or the catalog.**
Quit minivu first. Everything is in its container, `~/Library/Containers/com.minivu.app/Data/Library/`; in Finder, use **Go > Go to Folder…**. If you use Terminal, macOS may ask whether it can access another app's data.

| To reset | Remove | You lose |
|---|---|---|
| Settings | run `defaults delete com.minivu.app` (the file is `Preferences/com.minivu.app.plist`) | Every setting, including the sidebar folders, recent Copy To and Move To folders, slideshow music and the external editors list |
| Thumbnails | `Caches/minivu/thumbnails.sqlite` and its `-wal` and `-shm` files, or use **Clear Thumbnail Cache** | Nothing; thumbnails are made again |
| Catalog | `Application Support/minivu/catalog.sqlite` and its `-wal` and `-shm` files | Every star rating, tag and Custom Order |

**Building or testing fails although Xcode is installed.**
minivu needs full Xcode, not only the Command Line Tools. If `xcode-select -p` prints a Command Line Tools path, point it at Xcode once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**`make_app.sh` says "Metal toolchain not installed: shaders compile at launch".**
Harmless: the app compiles the shaders when it starts instead. To precompile them, install the toolchain with `xcodebuild -downloadComponent MetalToolchain` and run the script again.

**I changed the code and the app looks the same.**
`build/minivu.app` is a snapshot of the last build. Run `scripts/make_app.sh` again after any change, and replace any copy in Applications.
