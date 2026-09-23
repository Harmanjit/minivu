# minivu audit, tag v0.9.1

Method: full build and test run, then 15 subsystem and cross-cutting review agents
(64 raw findings), deduplicated to 59, each checked by two independent agents that
were told to refute it. 47 confirmed, 8 plausible, 4 refuted. No code was changed.

## 1. Bug and regression check

### Active breakages: none

| Check | Result |
|---|---|
| swift build | clean, 0 warnings |
| swift test | 1021 tests in 153 suites, all pass, 90 s |
| Skipped or disabled tests | none |
| Linter | none configured in the repo |

### Verified findings, highest severity first

No finding is a crash, a data-loss bug or a remote attack. Seven reach medium,
meaning a user meets them in ordinary use and something visibly goes wrong.

**M1. A malicious or broken image header can exhaust memory.**
Sources/MinivuCore/ImageDecoder.swift:156. There is no pixel budget before a
full-size decode. DecodeError.tooLarge exists but only the RAW renderer throws it.
A 2 KB PNG declaring 30000x30000 makes ImageIO allocate about 3.6 GB. Three of
them in one folder can push minivu past 10 GB while thumbnailing, and because
the decode never finishes, the failure is never recorded, so reopening the folder
repeats it. Fix: budget the thumbnail and display paths by megapixels, and leave
the deliberate unbounded export path in EditRenderer.loadSource alone so Save As
and Batch Convert keep every pixel.

**M2. The catalog can silently fall back to memory.**
Sources/MinivuCore/Catalog.swift:53. If opening the catalog throws, minivu logs
an error and runs on a temporary in-memory database. A user can rate and tag a
whole shoot, quit, and find every mark gone. The corrupt-file branch sets the real
catalog aside with no notice either. Fix: record the storage mode on the Catalog
and let the browser say once that marks will not be kept this session.

**M3. Batch Rename does not wait for queued saves.**
Sources/Minivu/Tools/Batch/BrowserBatch.swift:167. A save still rendering when a
rename starts lands after it, so the save is refused with an alert that blames
another application. This is one of the known limits already recorded in the
design notes. Fix: await FileWriteQueue.shared for the old and the new names,
the way the browser's transfer path already does.

**M4. The unsaved-edits sheet can open on a hidden window.**
Sources/Minivu/Viewer/ViewerWindowController.swift:287. retarget resolves unsaved
edits before performRetarget raises the viewer, so if the viewer is behind the
browser the sheet is invisible. Every further double-click is swallowed. Fix:
raise the viewer before asking.

**M5. Compare panes ignore display-settings changes.**
Sources/Minivu/Compare/CompareWindowController.swift:90. Change the RAW or HDR
setting and the viewer reloads but Compare does not. Zooming one pane then loads
the new rendering into that pane only, so the two panes disagree. Fix: observe the
display-settings notification and reload both panes without clearing the pane's
displayed entry, which would black it out.

**M6. A Finder-tag filter loses the pending selection.**
Sources/Minivu/Browser/BrowserModel.swift:473. Tags are read asynchronously after
the filter runs, so every image fails the filter for a moment. The pending
selection is consumed against an empty list. Going Back loses the selection, and
double-clicking a tagged file in Finder fails to open the viewer at all, silently.
Fix: read the tags with the listing when a tag filter is active.

**M7. Multi-file copy and move report to the catalog one file at a time.**
Sources/Minivu/Browser/FileTransfer.swift:154. Dragging 1000 photos costs about
2000 SQLite write transactions and 1000 main-thread notifications, roughly 20 to
40 percent on top of the copy. Fix: batch the catalog update per transfer, and
resolve the shared parent folder once instead of per file.

### Low-severity findings, grouped

Forty confirmed items sit at low severity. They cluster:

- **Stale state after a late result.** Save's quality compare can stick showing a
  spinner, an older render can overwrite a newer one, the animation player can
  stick in playing with no frames, and the viewer's exposure line is not re-read
  after an external edit.
- **Swallowed errors.** The catalog posts didChange even when the SQLite write
  failed. Undo of New Folder drops its trash error. Batch rename can leave a photo
  under a hidden .minivu-rename name without saying so. RAW engine failures fall
  back silently to the slow CPU path the module documents avoiding.
- **Main-thread work.** Catalog change handling runs a synchronous SQLite query on
  the main thread. The grid opens every visible file a second time just to read
  pixel dimensions. Thumbnail cache hits turn reads into write transactions.
- **Leftovers.** Hidden copy and rename temporaries are never swept after a crash.

### Checked and found sound

Worth recording, because it is where the risk would have been: the thumbnail
service lock ordering, the catalog's identity healing against concurrent moves,
SQL parameterisation throughout, statement finalisation, the FSEvents watcher
lifetime, exclusive rename with RENAME_EXCL, texture cache accounting and memory
pressure handling, the image loader's slot and cancellation logic, and the JPEG
comment splice bounds. The symlink behaviour in SafeFileWriter is deliberate,
documented in the source and already listed as a known limit.

## 2. Low-hanging features, ranked by effort then impact

**F1. Close the two file-queue tracking gaps. Low, 1 to 2 hours.**
Batch Rename waits for queued saves, and captures, montages and desktop copies
name their output inside the queue. Files: BrowserBatch.swift, the capture and
montage writers. This also fixes M3 and deletes two entries from the known-limits
list. It plugs straight into FileWriteQueue.shared, the pattern the transfer path
already follows.

**F2. Re-stamp the info panel after an in-place save. Low, 1 to 2 hours.**
Today the date, size and colour count keep the old values after saving over the
original. Files: SavePresenter.swift and the viewer's entry refresh. It reuses the
stamp helper the external-editor watcher already has. Closes a third known limit.

**F3. Select Tagged and Invert Selection. Low, 2 to 4 hours.**
Two Edit-menu commands for the browser grid, about 25 lines across four files.
Files: the menu definition, MinivuActions, BrowserWindowController, BrowserModel.
It follows the existing responder-chain selector and MenuStateTitles pattern
exactly. Users of this kind of browser expect Invert Selection on day one.

**F4. Copy and Paste files with the clipboard. Medium, 6 to 10 hours.**
Make Edit > Copy put the selected files on the pasteboard as file URLs, Paste
bring them in, and Copy Image in the viewer put pixels on the pasteboard. Files:
BrowserWindowController, ViewerWindowController, the menu definition, plus tests.
The grid's drag source already writes exactly the same pasteboard objects, so the
copy half is mostly reuse. Highest user-visible payoff of the set.

**F5. A GitHub Actions workflow on macOS. Medium, 3 to 5 hours.**
Build and test on every push and pull request, and upload the built app as an
artifact. File: a new .github/workflows/ci.yml. There is no CI today. It runs on
GitHub, not in the app, so the no-network and Apple-frameworks rules are untouched.
This matters now specifically because reviewers are about to file bugs against 0.9.

Runners-up, all judged sound and kept: slideshow resume continuing the remaining
interval, Copy To and Move To from the viewer, Lock Zoom across images, and a
file-type filter in the browser. One idea was dropped: a swift-format lint config,
because making the check pass means reformatting 267 files.

## 3. Suggested order

1. F1 and F2 together. Two hours, closes three known limits and one medium bug.
2. M1 and M2. The two findings with real consequences, memory and lost marks.
3. F5, so reviewer-driven fixes land with tests running automatically.
4. M4, M5, M6, then F3 and F4.
