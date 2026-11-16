# Wave 2 integration fixes

Defects found when the wave 2 branches (videos, organisation, output tools,
the catalog) met on main, with the fix for each and what to check by hand.
Every fix has a focused test unless noted.

## Videos in the tools and filters

| # | Defect | Fix |
|---|--------|-----|
| 4, 23 | The viewer's Export Slideshow Video drew videos as slides (frame 0), unlike Start Slideshow and the browser's export. | `ViewerSlideshowVideo` runs `SlideshowSequence.withoutVideos` and refuses an empty list. |
| 5, 6, 7, 8, 22 | Extract Pages, Create Multi-Page File, Image Strip and Create Web Gallery took `toolImages` (videos included). Only their menu check left videos out. | All four take `toolStills`, with an empty guard. |
| 1, 9 | Find Duplicates > Similar Images paired a video with a still by its poster frame. Highest Resolution then ranked the video at 0 px, so Mark Suggested marked it. | `DuplicateFinder.featurePrints` skips videos (Identical Files still finds copies of a clip). `pixelSizes` reads a video's size from `VideoFrames.info`. The decision is in video.md. |
| 2 | The filter metadata never read a video's date, camera or location, so Date Taken, Camera and Location filters were wrong for clips. | `FilterMetadata.read` has a video branch that reads `VideoFrames.metadata` and `info`. It uses the camera's wall clock and falls back to this Mac's zone, as the info panel does. Catalog schema 4 clears the `metadata` cache so rows cached before this are read again. |
| 3 | No Video type group: clips were filed under Other. | `FileTypeGroup.video` ("Video") is checked before the extension switch. The criteria form shows the toggle automatically. org.md's Type list is updated. |
| 10 | Batch Rename `{date}` used a video's modification date. | `RenameSource.withImageMetadata` has a `.video` case that reads the recording date (with its zone) and the size. |
| 29 | A search or smart folder saved with Other ticked stopped finding videos once Video became its own group. | Criteria saved since carry `"videoGroup": true` beside `fileTypes`. A saved query with Other and no marker decodes with Video added. No catalog migration: the JSON is fixed up when read, and the next save writes the marker. |
| 30 | Find Duplicates > Similar Images counted videos as compared, and they took places under the memory cap (`maximumSimilarImages`). | `DuplicatesModel.find` leaves videos out in similar mode before the cap and `scanned`. Identical Files still counts them. |

## Browser lists and the flat view

| # | Defect | Fix |
|---|--------|-----|
| 11 | A Duplicates list (`.files`) dropped any file renamed, batch-renamed or moved inside it. | `BrowserModel.followMoves` rewrites the list's URLs, and those in Back/Forward, after rename, Batch Rename, Move To and its undo/redo. |
| 12 | Batch Convert never refreshed a list, and in the flat view it refreshed only the top folder. | Mirrors Batch Rename: `showsManyFolders` reloads and selects the outputs. |
| 13 | A file trashed or moved from the viewer or Compare stayed in a search, smart-folder or Duplicates list. | `catalogChanged` drops shown list entries whose file no longer exists. The catalog names both paths of every minivu move or trash. The Save and metadata-write parts of the report were overstated: those files stay at their path. |
| 31 | The list check in 13 ran a `stat` on the main thread for every changed file shown, ratings included. | `Catalog.didChange` now has a userInfo with the moves (`movesKey`) and removals (`removedKey`). Only those source paths are checked on disk. A rating never touches the disk. |
| 32 | A Duplicates list still dropped a file renamed outside the browser: by Shortcuts, or by a Batch Convert Replace whose name changed letter case (a.JPG to a.jpg). | `BrowserModel.followRenames` takes the catalog's reported moves within one folder through `followMoves`, then reloads the list with the selection kept. Moves to another folder (the Trash, Move To elsewhere) are not followed and are dropped as in 13. Note: the viewer has no Rename command of its own. Its renames reach the list the same way if one is added. |
| 14 | A collection could never be shown in the order its images were added. | Under Custom Order a collection keeps the catalog's order (reversed when descending) and is read again on a resort. org.md now says Custom Order is how to see it. |
| 16 | After Move To out of a list, nothing was selected. | Files that left are removed and the next image is selected, as in a folder. Arrivals the list still holds win after the reload. |
| 17 | In the flat view, dragging a thumbnail onto the grid moved it from its subfolder into the top folder. | `GridDropPlan.decide` leaves out files the flat view lists from a folder below. |
| 18 | While a list was shown, Web Gallery, Contact Sheet, Export Slideshow Video and Create Multi-Page File opened their panels in no particular folder, and the gallery and sheet lost their title. | `toolStartFolder` (the folder shown, else the lead or first image's folder) and `toolTitle` (the folder's name, else the list's title). |
| 28 | New Folder in the flat view made a folder the grid could not show or name. | New Folder is disabled in the flat view (validation and action). org.md is updated. |

## Menus

| # | Defect | Fix |
|---|--------|-----|
| 15, 24 | Reveal in Finder was disabled for a selection in any list. | Enabled when there is a selection or a folder. |
| 25 | Filter > Show All was ticked while a More Filters condition hid images. | Show All is ticked only when neither the marks filter nor More Filters is active. |
| 26 | Start Slideshow stayed enabled while a sheet was up (browser and viewer). | Added to the browser's sheet-blocked tools; the viewer checks `attachedSheet`. |
| 27 | Open Folder and Add Folder to Sidebar queued their panel behind a browser sheet. | `AppDelegate.validateMenuItem` disables them while the browser has a sheet. No automated test: the browser lives inside the app delegate. |

## Catalog races

| # | Defect | Fix |
|---|--------|-----|
| 19 | Trashing a file into a Trash slot whose rows still belonged to a file put back in Finder deleted that file's marks and collection membership. | `applyMove` first re-homes destination rows whose file is found elsewhere by identity, unless rows are already there. A change of letter case is skipped, because those rows are the source's own. |
| 20 | A folder heal's collection pass committed without checking for moves begun since the listing. | `healCommit` lock: the collection pass and the marks pass check `isHealingPaused` under it right before committing, and `pauseHealing` takes it, so no move can begin between the check and the commit. |
| 21 | `collectionMembers` wrote re-homed paths back during a move, and the move's report then deleted them. | The write-back is skipped while healing is paused (under the same lock). The members found are still returned. |

## Open items for Harman

- An older minivu build that opens a schema 4 catalog can cache empty video metadata again. The `metadata` table has no reader-version column, so the newer build never re-reads those rows. Not changed here. Options: add a reader version per row, or clear video rows on every schema-4 open from an older writer.

## Manual checks for Harman

1. Live Photo folder: Tools > Find Duplicates…, Similar Images, Highest Resolution. The MOV is in no group and the HEIC is not paired with it. Identical Files still groups two copies of one clip.
2. Geotagged iPhone clips: More Filters with Date Taken set to the clip's day, Camera "iPhone" and Location "has" finds them. The first search after updating re-reads every file once, because the cache was cleared.
3. More Filters and Find show a Video toggle. A smart folder saved with only Video ticked reopens with clips only.
4. Batch Rename `{date}` on an AirDropped clip gives its recording date.
5. Viewer on a clip: Tools > Export Slideshow Video… says the right number of pictures and starts at the next photo.
6. Find Duplicates > Show in Browser: rename a file with F2, then Move To a subfolder. It stays in the list, selected. Trash one from the viewer, return, and it is gone from the list.
7. Smart folder: Move To ~/Desktop selects the next image.
8. Collection: add C, A, B, choose View > Sort By > Custom Order, and see C, A, B.
9. Flat View: dragging a thumbnail onto another does nothing. New Folder is greyed out.
10. Collection shown: Create Web Gallery is titled after the collection and its panel opens in the images' folder.
11. With Batch Rename's sheet up: ⇧⌘F, ⌘O and ⇧⌘O are greyed out. Also click the viewer control bar's slideshow button while a viewer sheet is up. That button sends its action straight to `NSApp`, so validation may not cover it (not fixed).
12. Reveal in Finder works from search results. Filter > Show All is unticked while More Filters hides images.
13. A smart folder saved before this build with Other ticked still lists videos.
14. Find Duplicates > Show in Browser on two copies named IMG.JPG: Batch Convert to JPEG beside the originals, Replace. The list now shows IMG.jpg.
