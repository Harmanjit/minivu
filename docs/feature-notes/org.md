# Feature notes: find across folders, flat view, filters, smart folders and collections (G3)

Branch `feature/org`. Notes for the documentation pass: what was built,
why, the limits, and which DESIGN.md, wiki and help sections should change.
Nothing in DESIGN.md, docs/wiki or the help pages was edited.

The no-import model stands: nothing is indexed ahead of time and nothing
runs while the app is idle. A tree is read only when the user asks for it
(the flat view, Find, opening a smart folder), off the main thread, and the
read is cancelled when the user moves on. The only thing kept is what was
read for a filter, in the catalog, so the next search of the same files
reads nothing.

## Flat view

### What the user can do

- **View > Flat View** (⌥⌘F, a checkmark). The browser shows the folder's
  images and those of every folder below it as one list, without the
  subfolders themselves. It stays on as the user moves between folders, as
  the filters do; it is per window and not remembered across launches (a
  flat view of Pictures at launch would walk the whole library uninvited).
- The window's subtitle says "123 images, with subfolders".
- Images can share a name in different folders, so each cell's tooltip
  shows its full path and VoiceOver reads "IMG_1.jpg, in 2024-06-01, 3
  stars…". The status bar's path control shows the **lead image's folder**
  instead of the window's, and a click on it goes there.
- The grid fills in as folders are read: every quarter of a second what
  has been found so far is sorted (off the main thread) and shown, and the
  status bar says "… — searching…" until the walk ends. Stars, tags and
  Finder tags arrive with the end of the walk.
- Everything else works as in a folder: open in the viewer (the viewer
  steps through the whole flat list), rate, tag, label, rename, move, copy,
  trash, the batch tools, Edit Metadata, sort (Custom Order falls back to
  name order, since an arrangement belongs to one folder). New Folder and
  Paste go into the folder at the top of the tree.

### Design and why

- `TreeEnumerator` (MinivuCore/Search) walks breadth first through
  `FolderListing.contents`, the browser's own listing call, so each image
  arrives with the attributes the grid needs from the same system call
  (no stat per file), packages and hidden items are skipped exactly as in
  the browser, a symbolic link to a folder is never followed (no loops),
  and every folder passes `VolumePolicy` as it is listed, so an external
  disk mounted inside the tree is left out.
- **Limits** (`TreeEnumerator.Limits.standard`): 12 levels below the
  folder, 20,000 images, 5,000 folders. Breadth first means a limit cuts off
  the deepest material, never a folder near the top. A walk stopped by a
  limit says so: the status bar ends "— limit reached, not every image is
  shown" (`BrowserModel.truncatedNote`).
- **Cancellation:** a `CancellationFlag` checked before each folder; a new
  navigation, a new load, or closing the window sets it, and the model's
  generation number drops any result that lands late.
- **Keys:** the browser model knew entries by file name (every entry was a
  child of one folder). A list from many folders knows them by path
  (`FolderSnapshot.keysByPath`); marks, Finder tags, the filter's metadata
  and the grid's index all use `BrowserModel.key(_:)`.
- **Healing:** the flat view does not heal files moved in Finder (healing
  reads each folder again, doubling the walk). Their marks come back when
  their folder is opened on its own, as before.
- **Watching:** only the folder at the top of the tree is watched (the
  `FolderWatcher` is one level deep by design); changes deeper in the tree
  show at the next load. minivu's own moves, renames and batch work reload
  the list at once.

## More filters

### What the user can do

- **View > Filter > More Filters…** (and the toolbar's Filter menu) opens a
  sheet with: **Type** (JPEG, HEIF and AVIF, PNG, RAW, TIFF, GIF, WebP,
  Photoshop, PDF, SVG, Other; none ticked shows all), **Date Taken** (from
  and/or to, inclusive days), **Camera model** and **Lens** (part of the
  name, case and accents ignored: "5d" finds "Canon EOS 5D Mark IV"),
  **ISO**, **Aperture (f/)** and **Focal length (mm)** ranges (either end
  open; "f/2,8" and "2.8" both read), **Keywords** (all of these, comma
  separated, any letter case), **Label** (Any, No Label, or a colour),
  **Location** (Any, has one, has none), **Orientation** (Any, Landscape,
  Portrait, Square) and **minimum width × height** in pixels.
- Buttons: Clear, Cancel, Filter (Return). The Filter menu item has a
  checkmark while any of these is on, the toolbar's filter symbol fills,
  and the status bar says "12 of 340 shown" as for the rating filters.
- **Show All** clears these with the rating, tag and Finder tag filters.
- Like the other filters they apply to images, never folders, and stay as
  the user moves between folders.
- Type and label filter at once. The rest need each file's header: those
  are read in the background, 200 files a hop, and images appear as they
  are known to match (never shown and then taken away). A file without the
  value (no date taken, no ISO) fails a condition on it.

### Design and why

- Conditions are `MetadataCriteria` (MinivuCore/Search/SearchCriteria.swift),
  shared with Find and smart folders. The header values are
  `FilterMetadata`, read in one pass per file with ImageIO
  (`CGImageSourceCopyPropertiesAtIndex` and `…CopyMetadataAtIndex`, never a
  pixel), reusing wave 1's `MetadataFields.read` for keywords, date taken
  and location, with the XMP sidecar overlaid for files whose metadata
  lives in one (RAW), so the keywords match what Edit Metadata and the info
  panel show.
- Date taken compares the **wall-clock day** (yyyymmdd) the camera
  recorded, as Edit Metadata keeps it, not an instant in a time zone.
- Colour label comes from the Finder tags the browser already reads after
  each listing (`ColorLabelCommand.label`, Finder's localised names
  included); turning the filter on reads them with the listing, as the
  Finder tag filter does.
- **Cache:** catalog table `metadata` (schema 3), keyed by path, valid while
  the file's size and modification date are those recorded; anything that
  rewrites the file (a save, Edit Metadata, another app) makes it read
  again. minivu's moves and renames carry rows (`fileMoved`), removals drop
  them. Rows are written when read and dropped a year later (the first
  write of a launch prunes), so the table grows with what was searched, not
  with what was browsed.

## Find across folders

### What the user can do

- **Edit > Find…** (⌘F, as in Finder and Photos; it was free: the viewer's
  bare F is the filmstrip and ignores Command, full screen is ⌃⌘F and the
  slideshow ⇧⌘F). A sheet: **Search in** (Pictures, each sidebar folder,
  and the folder shown: only folders the user has granted), **Include
  subfolders** (on), **Name contains**, **Rating** (Any, ★ or more …),
  **Tagged only**, then every More Filters condition. Buttons: Clear,
  Cancel, Find (Return). Find starts from the last search, in the folder
  shown.
- Results replace the grid as a list titled "“IMG” in Pictures" (or
  "Search in Pictures"). It is a place in the history: Back returns to the
  folder. Everything the flat view supports works on it (open in viewer,
  rate, label, move, copy, trash, batch tools, Edit Metadata), except
  those that need one folder: New Folder, Paste, dropping files on the
  grid and Custom Order step aside. Enclosing Folder is disabled.
- **File > Save as Smart Folder…** (enabled while search results are
  shown) asks for a name and puts the search in the sidebar.

### Spotlight or the walk: measured, and why the walk

Find walks the tree (`ImageSearch`, MinivuCore/Search) and does not use
`NSMetadataQuery`. Measured on an M-series Mac, release build
(`SearchBenchmark`, `MINIVU_BENCH_DIR=~/latent/TestAssets`):

| What | Time |
|---|---|
| Walk 20,000 empty images in 201 folders (the image limit) | 128 ms |
| Find by name over the same tree | 137 ms |
| Header reads for a metadata condition, 82 real files (NEF, JPEG, HEIC, TIFF), cold | 906 ms (11 ms a file) |
| The same, second time (from the catalog) | 0.3 ms |
| `mdfind -onlyin TestAssets` by name | 70 ms, but found **0 of the 10 originals** at the top level (32 hits, all thumbnails in a cache folder) |
| `mdfind -onlyin TestAssets 'kMDItemAcquisitionModel == "*"'`, lens model the same | 30 ms, **0 results** |

Spotlight is faster when it has the answer, but on this Mac (indexing
enabled) it had not indexed the camera, lens or most of the files at all,
and it never knows minivu's ratings and tags (catalog), RAW keywords kept
in minivu's XMP sidecars, folders excluded in Privacy settings, or files
copied in moments ago. A search that silently misses files is worse than a
slower one, and the walk is fast where it matters: names, types, marks and
labels cost nothing beyond the listing, and metadata conditions read each
header once, ever, thanks to the cache. NSMetadataQuery would also need
its own run loop handling and gives no cancellation between folders.

Order of tests per folder: name and type (in memory), marks (one catalog
query), label (one extended attribute each, only with a label condition),
then headers only for files still in the running.

## Smart folders

### What the user can do

- Saved with **File > Save as Smart Folder…** from search results. They
  appear under **Smart Folders** in the sidebar (gear symbol; the section
  appears once there is one), sorted by name.
- Clicking one **runs its search again** and shows the results (a file made
  since is found). The row's context menu: **Edit Search…** (the Find sheet
  with Save; saving re-runs it if shown), **Rename…**, **Delete Smart
  Folder…** (asks; only the search is deleted). Deleting the one shown goes
  Back.

### Design and why

- Catalog table `smart_folders`: name and the `SearchQuery` as JSON. Every
  field decodes with a default and an unknown value (a type group renamed
  later) drops only that condition, so a smart folder saved by this minivu
  opens in a later one; one whose JSON can't be read at all is left out of
  the sidebar, not shown broken.
- The scope is a path; access comes from the sidebar's bookmarks or
  Pictures. A smart folder whose folder is no longer granted shows the
  browser's usual permission message (File > Open Folder…).

## Collections

### What the user can do

- **File > New Collection…** asks for a name and makes a collection holding
  the selected images, if any (Photos' New Album with Selection).
- **File > Add to Collection ▸** (also in the grid's right-click menu): each
  collection, then New Collection…. Images can also be dragged onto a
  collection's row in the sidebar (they join it; nothing moves).
- Collections appear under **Collections** in the sidebar (stack symbol);
  clicking one shows its images in the order they were added, as a list
  like search results.
- **File > Remove from Collection** (and the right-click menu) while a
  collection is shown takes the selected images out of it, never out of
  their folders.
- Row context menu: **Rename…**, **Delete Collection…** (asks; "The images
  in it stay where they are.").

### Design and why: membership by file identity

- Catalog table `collection_items`: collection, path, folder, volume UUID
  and file identifier, as `files` keeps for marks.
- **Renamed or moved by minivu** (rename, Move To, drag, batch rename, a
  batch convert that replaces its original, undo of any of them): the
  member follows, through the same `Catalog.fileMoved`/`filesMoved` that
  carries marks, including everything inside a moved folder.
- **Moved or renamed in Finder:** when the collection is opened, a member
  not at its path is looked for by its identifier on its volume
  (`fsgetpath`), which finds it anywhere on the same volume that the
  sandbox lets minivu see, and its row takes the new path. Healing a folder
  (any listing) also reattaches members moved into it, as marks are.
- **Saved over** (a save writes a new file under the same name): still the
  member, the path wins, as for marks.
- **Moved to the Trash by minivu:** left out of the list but kept, as its
  marks are kept, so moving it back with minivu (undo of a Replace) brings
  it back. **Removed by minivu** (an undone copy, the compare window's
  delete): it leaves its collections.
- **Gone** (deleted in Finder, moved to another volume, or somewhere
  outside the granted folders): left out and stamped missing; it comes back
  if it reappears or healing finds it, and is dropped after a year missing,
  as marks are. The sidebar's count (catalog) counts only members present.
- **Copies** are new files and are not members.

## Catalog schema 3

- `Catalog.schemaVersion` 2 → 3 adds `metadata`, `collections`,
  `collection_items` and `smart_folders`, in one transaction with the
  earlier steps, so a version 1 catalog goes 1 → 2 → 3.
- Tested against a **real version 2 catalog** written by the previous
  minivu (Tests/MinivuCoreTests/Fixtures/catalog-v2.sqlite: ratings, a tag,
  a row standing over a file's own marks, a custom order, a non-ASCII
  name), and a version 1 catalog built with that version's exact schema.
  Package.swift now copies the fixture as a test resource.
- No foreign keys (SQLite enforces them only with a per-connection
  pragma); deleting a collection deletes its members in the same
  transaction.

## Menus and shortcuts

Checked against every key equivalent in MainMenu.swift and the viewer's
and grid's key tables; `noShortcutIsUsedTwice` passes.

| Menu | Item | Shortcut |
|---|---|---|
| File | New Collection… / Add to Collection ▸ / Remove from Collection / Save as Smart Folder… | none |
| Edit | Find… | ⌘F |
| View | Flat View | ⌥⌘F |
| View | Filter > More Filters… | none |

Every new control has a VoiceOver label (type toggles "Show RAW files",
range fields "ISO, minimum", date pickers "Taken on or after", sidebar rows
"Trip, collection" / "Shots, smart folder", grid cells in a list "name, in
folder"). Nothing new animates.

## Limits

- Walk limits as above; the flat view and searches say when they hit one.
- The flat view and lists don't heal marks of files moved in Finder (their
  folders do when opened).
- Only the top folder of a flat view is watched; lists aren't watched.
- Spotlight is not used, so a search of a huge tree with metadata
  conditions reads every header once (about 11 ms a file cold).
- A collection member moved in Finder to a folder the sandbox can't see
  stays missing until that folder is granted and listed.
- The metadata cache is per path and file date; a file whose date is kept
  while its metadata changes (rare, `touch -r`) shows the old values until
  it changes again.

## Tests

- MinivuCoreTests/CatalogLibraryTests: v2 and v1 upgrades, reopening, the
  metadata cache (freshness, read once, cancellation, moves and removals),
  collections (order, rename and move by minivu, folder moves, removal,
  Trash, Finder moves by identity and by healing, missing members), smart
  folders (persistence across launches, tolerant decoding).
- MinivuCoreTests/SearchTests: header reading, every condition, unknown
  metadata, ranges, type groups, JSON, the walk (order, depth, image and
  folder limits, cancellation, unreadable root, symlink loops), Find (name,
  rating, metadata, subfolders, labels and file marks asked only when
  needed, cancellation).
- MinivuTests/BrowserOrganiseTests: flat view, namesakes, cancellation on
  navigating away, truncation, partial results, lists in the history,
  collections following a rename, deleted smart folders, the metadata
  filter (type at once, camera and shape after reads, cached), the label
  filter.
- MinivuTests/BrowserOrganiseWindowTests and CriteriaFormTests: Find to
  results to smart folder and back, collections from the selection, Add
  to Collection, Remove, delete, drops on a row, the flat view toggle and
  the cells' folder names, More Filters, ⌘F and ⌥⌘F, the form's parsing.
- SearchBenchmark (opt-in, `MINIVU_BENCH_DIR`): the figures above.

## What the documentation pass should change

- **DESIGN.md 1 (Goals):** add that searching and the flat view read on
  demand, cancellable, with no index (the no-import rule restated for G3).
- **DESIGN.md 4.6 (Catalog):** schema 3 tables (`metadata`, `collections`,
  `collection_items`, `smart_folders`); the metadata cache's validity
  (size and date) and pruning; collection membership by identity and every
  case above (minivu moves, Finder moves via `fsgetpath` and healing,
  Trash, removal, missing for a year); healing now also reattaches
  collection members.
- **DESIGN.md 4 (Architecture):** MinivuCore/Search (`TreeEnumerator`,
  `ImageSearch`, `SearchCriteria`); BrowserModel's lists and keys by path
  (`FolderSnapshot.keysByPath`, `VirtualList`); partial results every
  250 ms.
- **DESIGN.md 5 (Browser window):** the sidebar's Smart Folders and
  Collections sections; the flat view; lists in place of a folder and the
  commands that step aside; the status bar showing the lead's folder in a
  list. **Filter and sort:** More Filters and its conditions; Custom Order
  by name in lists. **Menu shortcuts** table: Find… ⌘F, Flat View ⌥⌘F, File's
  collection and smart folder items, Filter > More Filters….
- **DESIGN.md 6 (Efficiency):** walk limits; Spotlight measured and not used
  (the table above).
- **DESIGN.md 8 (Known limits):** the limits section above.
- **Wiki Browser.md:** Flat view, More Filters, Find, Smart folders,
  Collections (with what happens when a file moves or disappears).
- **Wiki Keyboard-Shortcuts.md:** ⌘F, ⌥⌘F (the in-app page is generated
  from the menu and already lists them).
- **Wiki Architecture.md:** MinivuCore/Search and catalog schema 3.
- **Wiki Limitations.md:** the limits above. **Accessibility.md:** the new
  VoiceOver labels.
- **Wiki Security-and-Privacy.md / help Privacy.md:** searches read only
  granted folders, locally; nothing is sent anywhere and Spotlight isn't
  queried.
- **Help Browser.md:** Flat View, More Filters, Find, Smart Folders and
  Collections sections.
