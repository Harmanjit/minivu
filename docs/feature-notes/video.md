# Feature notes: videos among the photos (branch feature/video)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section says where it should.

## G18, part 1: browse and play videos

minivu shows and plays videos in the folders it browses, FastStone-style.
It is not a video editor: nothing trims, converts, exports or edits a
movie.

### What the user can do

- **See videos in the grid.** Movies sit among the photos in every folder,
  sorted and selected like them. Each thumbnail is a frame from a little
  way in (a second in, or a tenth of the way through a clip shorter than
  ten seconds), so a clip that opens on black still shows what it is of.
  A dark capsule over the picture's bottom-right corner holds a play
  triangle and the length ("0:12", "1:02:03"); the length appears with
  the pixel dimensions on the detail line, a moment after the thumbnail.
  VoiceOver reads the cell as "clip.mov, video, 0:12, 2 stars, 1920 × 1080".
- **Filter by type.** View > Filter and the toolbar's Filter menu gain
  **Photos Only** and **Videos Only** (checkmarks, no shortcuts). Choosing
  the one in force shows both again; Show All clears it with the other
  filters. "Photos" means everything that isn't a video (RAW, PDF and SVG
  included). Folders always show, as with the other filters, and the
  filter stays as the user moves between folders. The status bar says
  "3 of 5 shown" as for any filter.
- **Open a video in the viewer** (double-click, Return, ⌘↓) like a photo.
  Its first frame appears on the canvas at once (cached and prefetched
  like a photo, HDR when the video is), with a large play button in the
  middle. Nothing plays until asked.
- **Play and pause:** Space, P, the play button, the control bar's
  play/pause button, or Image > Play Video / Pause Video (the Play
  Animation item, retitled while a video is shown). Once playing, AVKit's
  floating controls appear over the video: play/pause, the scrubber, the
  time, volume and mute. Pausing leaves the player where it is; playing
  again at the end starts from the beginning.
- **Mute:** M, the player's own volume control, or Image > Mute Video /
  Unmute Video (display-only M, as P is). The choice carries over to the
  next video for as long as the app runs, as in QuickTime.
- **Move on** with → ← ↓ ↑, Page Down/Up, Delete, Home, End, the
  filmstrip and the wheel, exactly as for photos. Moving on stops the
  video and releases its player. Esc, ⌘W, the close button and
  double-clicking the still close the viewer, which stops it too.
- **Full screen** (Return, ⌃⌘F) works while a video plays: the player
  moves with the viewer's content into the full-screen window and keeps
  playing. AVKit's own full-screen button is hidden.
- **File commands work as for photos:** Move to Trash (⌘⌫), rating
  (0–5, ⌃0–⌃5), tag (T, `, ⌘T), Finder colour labels (⌥⌘0–7), Reveal in
  Finder, Share…, Open in External Editor, Rename (F2), Batch Rename,
  Copy To / Move To, copy and paste, drag and drop.

### Keys: one scheme for a mixed folder

| Key (viewer) | On a photo | On a video |
|---|---|---|
| Space | next image | play / pause |
| P | play / pause an animation | play / pause |
| M | (nothing) | mute / unmute |
| → ↓ ← ↑ Delete Page Down/Up Home End | move between items | the same |

Space on a video plays and pauses because that is what it does in every
Mac player (QuickTime, Photos, Finder's Quick Look), and a user arriving
at a video expects it. The arrows keep moving between items on a video,
so the keys that flip through a folder never change meaning, and the only
key whose meaning changes is one that would otherwise skip the clip the
user has just reached. M was free in the viewer's key table, and as a
display-only shortcut it clashes with nothing in the menus (⇧⌘M is
Curves, ⌘M Minimize); the shortcut-uniqueness test covers it.

The player view never takes the keyboard (`VideoPlayerView` refuses first
responder and hands any key it is given to the viewer's table), so
AVPlayerView's own keys (the arrows stepping frames) never apply.

### What is turned off for a video, and why

Disabled through menu validation (the items grey out; the tools panel and
the control bar's edit button follow `canEditCurrent`):

- every edit tool, Rotate/Flip, Resize, Canvas Size, Crop, Straighten,
  Perspective, Adjust, Effects, Retouch, Text and Shapes, Watermark,
  Remove Background, Auto Enhance, Save, Save As, Revert: the still is
  only the first frame, and minivu writes no video;
- Live Text and Copy Text, Copy (⌘C) and Copy Subject: a frame is not the
  video;
- Histogram and Count Colors (the histogram panel shows nothing for a
  video);
- Zoom In/Out, Actual Size, Fit to Window: a video is shown fitted, as its
  player shows it;
- Print and Set as Desktop Picture, in the viewer and for a browser
  selection whose lead is a video;
- Edit Comment (JPEG only, as before) and Edit Metadata: the metadata
  writer refuses movies (`MetadataWriter.method` is `.unsupported` for
  `.video`), so a video alone greys the item out, and in a mixed
  selection the videos are skipped and named in the summary, like any
  other file it can't write. No XMP sidecar is made for a video (no video
  application reads one). Ratings and tags of videos stay in the catalog;
  the opt-in XMP rating sync skips them for the same reason.
- In the browser: Save As (convert) and lossless Rotate/Flip of a video
  (a mixed selection rotates the photos and names the videos as skipped,
  as for RAW files).

### Tools and videos (decision)

- **Slideshow skips videos.** A slideshow shows pictures for an interval;
  playing clips inside one would need a second playback path with its own
  timing, audio against the music, and HDR transitions. Showing a video's
  first frame as a slide would misrepresent it. From a video, the show
  starts at the next picture (wrapping to the first). A folder or
  selection of nothing but videos disables Start Slideshow.
- **Batch Convert, Print, Contact Sheet and Montage Wallpaper skip videos**
  (they work on `toolStills`); with only videos chosen they are disabled.
  A video given to the batch converter some other way (a Convert Images or
  Resize Images shortcut) fails for that file with "contains no image
  minivu can decode", and the rest of the batch goes on.
- **Batch Rename includes videos**: renaming is a file operation.
- **Compare Selected** shows a video by its first frame (decided in part
  2; see below).

### Design decisions

- **One `ImageKind`, `.video`.** Videos are listed, sorted, selected,
  rated, tagged, moved and trashed by exactly the code that does it for
  photos, so file operations needed no change. `ImageFormats.isImage`
  stays true for videos ("image" is the app's word for a non-folder item
  of a folder); `ImageFormats.isVideo` and `entry.kind == .video` are the
  checks for what differs.
- **Which files count.** `ImageFormats.videoCandidates` (mov, qt, mp4,
  mpg4, m4v, 3gp, 3gpp, 3g2, 3gp2, mts, m2ts, mpg, mpeg, dv) intersected
  with the extensions of the movie types `AVURLAsset.audiovisualTypes()`
  reports (`videoExtensions`, worked out once). Not everything
  AVFoundation reports: its list includes subtitles (vtt, scc, ttml),
  audio (mpa, m1a), "ts" (in most folders TypeScript, not a transport
  stream) and AVI, whose container AVFoundation opens but whose codecs it
  mostly can't play. A listed file AVFoundation can't decode shows no
  thumbnail and "minivu can't display …" in the viewer.
- **Reading videos (`VideoFrames`, MinivuCore).** Size (natural size
  turned by the track's transform, so portrait phone videos are tall),
  length, frame rate, codec, audio and HDR come from the first video
  track with AVFoundation's async `load`; frames from
  `AVAssetImageGenerator` (`generateCGImageAsynchronously`) with
  `maximumSize` set to the size needed (never more pixels than shown) and
  the preferred transform applied. Callers are GCD threads (thumbnail
  workers, the image loader, `BlockingWork`), which wait on a semaphore
  with a 10 s limit, so a damaged file can't hold a worker. At most three
  frames decode at once (`frameSlots`): a 4K HEVC frame holds tens of MB
  in the decoder, and the thumbnail service runs a worker per core.
- **Thumbnails** go through `ImageDecoder.thumbnail` and therefore the
  existing `ThumbnailService` and `ThumbnailStore`: same tiers, same
  memory and disk caches, same failure memory, never enlarged past the
  video's own size, always SDR. The poster frame is taken with a
  tolerance (half the poster time before, 1 s after) so a nearby keyframe
  can be used, which is much faster than an exact frame.
- **The viewer's still** goes through `ImageDecoder.decode` and therefore
  the image loader: cached, prefetched for neighbours at screen size,
  shown in the same event when cached. It is the exact first frame
  (zero tolerance), where playback starts. With Show HDR on, an HDR video's
  still is decoded with `dynamicRangePolicy = .matchSource` and shown with
  its highlights on an HDR screen, like an HDR photo; otherwise it is tone
  mapped (`.forceSDR`).
- **AVKit's `AVPlayerView`, not an `AVPlayerLayer` with minivu's own
  controls.** AVPlayerView brings the scrubber, time, volume and mute,
  HDR on screens that have it, VoiceOver labels and actions, Reduce Motion
  and the system's look; a layer would need all of that written,
  localised and kept in step with macOS. minivu hides its full-screen,
  picture-in-picture and sharing buttons (the viewer has its own full
  screen; Share is in the File menu), turns off Now Playing (minivu isn't
  a media player to steer from the menu bar), and keeps the keyboard.
- **Idle means idle.** No player exists until the user asks to play:
  flipping through a folder of videos costs one decoded frame each, like
  photos, and never a player, decoder session or audio route. The player
  is released (`VideoPlayback.stop()`: pause, `replaceCurrentItem(nil)`,
  view detached) when the user moves to another item, the item is
  trashed, or the viewer closes. While the viewer window is hidden,
  minimised or covered (occlusion), a playing video pauses; it doesn't
  resume on its own. A paused player costs no CPU.
- **HDR playback.** AVPlayerView shows HDR video as HDR on EDR screens by
  default. Show HDR off asks for standard range with
  `preferredDisplayDynamicRange = .standard` on macOS 26 and later; on
  macOS 15 that API doesn't exist, and AVKit decides (HDR where the screen
  has it). Changing Show HDR while a video plays applies at once.
- **Play button** (`VideoStageView`): a 72 pt `play.circle.fill` button,
  white with a soft shadow so it reads on any frame, VoiceOver label
  "Play Video", tooltip "Play Video (Space)". It refuses first responder.
  The stage lies over the canvas on its frame (above Live Text, below tool
  overlays, the HUD and panels); empty parts of it pass clicks, the wheel
  and the magnifier to the canvas. Nothing animates, so Reduce Motion has
  nothing to change.
- **HUD** shows "Video, 1:05" where a document shows its page; the length
  is read off the main thread when the video is shown. It does not tick
  while playing (no timers; AVKit's controls show the time).
- **Info panel**: a Video section (dimensions, duration, frame rate,
  codec as its four-character code, audio, HDR, and "Playable: No" when
  AVFoundation can't decode it) replaces the Image section. Kind comes
  from the system ("QuickTime movie", "MPEG-4 movie").
- **The grid's detail line** reads a video's size and length in one read
  (`PixelSizeCache` now keeps a length beside the size).

### Limits

- Videos are never edited, trimmed, converted, exported or written; their
  metadata isn't edited.
- No frame stepping, playback speed or loop controls (AVKit's floating
  style has none; part 2 may add keys for them).
- Clicks on the playing video go to AVKit (which shows or hides its
  controls), not to the canvas: double-clicking a playing video does not close the viewer as
  double-clicking a photo does (the still, before playing, still does).
- Before macOS 26, Show HDR off can't make AVKit play an HDR video in
  standard range; the still is tone mapped either way.
- The length in the grid comes from the container (precise timing is off,
  to avoid reading the whole file), so a few files with odd containers
  may be a frame or two out.
- Slideshow, Batch Convert, Print, Contact Sheet and Montage skip videos;
  Compare shows only a video's first frame, never plays it.
- Only internal volumes, as for photos.

### Tests

- MinivuCoreTests/VideoFramesTests: which extensions count (and that ts,
  vtt, mpa, avi, scc don't); listing; size, length, codec and portrait
  orientation from a generated movie; a fake .mov reads as nothing;
  the thumbnail is from a little in (not the black first frame) and the
  still is the first frame, screen-sized when asked; thumbnails cached in
  memory and in `ThumbnailStore`; the info panel's Video section; Edit
  Metadata refuses videos and writes no sidecar.
- MinivuRenderTests/BatchConvertEngineTests.refusesAVideo.
- MinivuTests/VideoTests: the file type filter (model, menus, checkmarks,
  toggling off); slideshow start mapping; the cell's VoiceOver text and
  badge frame; the viewer's key table on a video; the Mute item's
  display-only M; the browser's tools with videos selected (picture tools
  off, file commands on); in a real viewer, the first frame on the canvas,
  the play button, every command that must be off for a video and the
  ones that must stay on, the player made on demand, paused and released
  on navigation and on close, and mute carrying across videos.
- Every movie is made in the test with AVAssetWriter (`TestVideos`, in
  both test targets): H.264, silent (no audio track), first frame black,
  then a flat colour. The player in tests is muted besides.

## G18, part 2: describe, copy and save frames, Compare, resources

### What the user can do

- **Read about a video** in the viewer's info panel (I) and the browser's
  preview pane. The Video section gives dimensions, duration, frame rate,
  codec, audio, HDR and now the **data rate** ("12.4 Mbit/s", the file's
  size over its length, as QuickTime Player's inspector gives it). From
  the movie's own metadata, as an iPhone or camera writes it, come a
  **Camera** section (make, model), **Dates** > Original (when recording
  began, on the camera's clock with its offset, "1 May 2024 at 14:30:05
  +02:00"; a movie without one shows the container's creation time in the
  Mac's zone) and **GPS** (latitude, longitude, altitude, written as for a
  photo). All are shown only.
- **Preview pane:** a video's still has the grid's play mark and length
  beside the stars ("▶ 0:12"), read by VoiceOver as "Video, 0:12".
  Double-clicking the still opens the viewer, where it plays; the pane
  never plays.
- **Copy Frame** (Edit menu, after Copy Subject, no shortcut): puts the
  frame on screen on the clipboard as a picture at the video's own size
  (a 4K clip gives a 3840 × 2160 picture whatever the window's size).
  The frame on screen is where the player stands, playing or paused, or
  the first frame (the still) before anything has played.
- **Save Frame As…** (File menu, after Save As…, no shortcut): the same
  frame through the Save As panel, with its formats, quality, size
  estimate and quality comparison. It pauses a playing video first, so the
  panel saves what the user sees. The name starts as "clip frame 0.12"
  (the time as a player shows it, dots for the colons a file name can't
  hold). The metadata options are hidden: the picture carries none of the
  movie's metadata.
- Both are greyed out for photos, in the browser and in Compare. ⌘C stays
  off for a video (part 1): its still is not the video, and a command named
  for the frame says what the user gets.
- **Compare Selected** accepts videos and compares each by its first
  frame, zoomable like a photo. The pane's second line reads "Video, 0:12"
  where a photo's gives the exposure. Compare never plays a video.

### Design decisions

- **Metadata read only when asked.** `VideoFrames.metadata(for:)` (data
  rate, creation date, ISO 6709 location, make, model) is a separate read
  from `VideoFrames.info(for:)`, which the grid's detail line and every
  thumbnail use; the info panel alone pays for it, once per file shown.
- **Dates.** QuickTime's `creationdate` key keeps the zone the camera was
  in ("2024-05-01T14:30:05+0200"), so it is shown on that clock with its
  offset, as a photo's EXIF date with OffsetTimeOriginal is; the
  container's creation time is an instant, shown in the Mac's zone.
- **Location.** ISO 6709 in all three forms phones and cameras use
  (decimal degrees, degrees and minutes, degrees minutes and seconds, each
  with an optional fraction) and an optional altitude; anything else, or
  out of range, is left out rather than guessed.
- **Remove location for videos: out of scope (verified).**
  `AVAssetExportSession` with the passthrough preset and
  `AVMetadataItemFilter.forSharing()` does strip the location without
  re-encoding the samples, but it is not lossless for the file or trivial
  for minivu: it writes a whole new movie (gigabytes for a long 4K clip,
  minutes of disk work in the write queue), it supports only QuickTime and
  MPEG-4 outputs (not the MTS, MPEG or DV minivu lists), and passthrough
  rewrites the container, dropping what the export session doesn't carry
  (timed metadata tracks such as Cinematic mode's and spatial video's
  extra data, chapter tracks, some vendor atoms) and the sharing filter
  also removes other personal items. Save As's Remove location and Batch
  Convert's are for pictures; a video's location is shown, not edited, as
  the rest of its metadata (part 1: Edit Metadata refuses videos).
- **The frame.** `VideoFrames.still(of:at:)`: an exact frame
  (`AVAssetImageGenerator`, zero tolerance, no `maximumSize`, preferred
  transform applied, `forceSDR`). A player paused at the very end reports
  a time just past the last frame, which has no exact frame; the last one
  before it (within 1 s) is taken then. It is decoded from the file, not
  read back from the screen, so it is the video's own pixels at its own
  size, never the scaled or tone-mapped picture on screen.
- **SDR.** Copy and Save As give every picture in standard range, and so
  do these: the clipboard's consumers and the formats Save As writes are
  SDR. An HDR clip's frame is tone mapped by AVFoundation.
- **Save Frame As reuses Save As** (`SavePresenter.presentSaveFrameAs`):
  `SaveImageSource` gains a `videoFrame` origin, decoded once and shared by
  the estimate, the comparison and the write, which goes through
  `FileWriteQueue` like every save. `SaveAsModel` gains `suggestedName`
  and `carriesMetadata` (false for a frame, hiding Keep metadata and Remove
  location); the write passes no metadata source. The panel only writes
  picture types, so the movie can't be chosen as the target.
- **Copy Frame writes the pasteboard only once the frame is decoded**, as
  Copy does, so a failure leaves the clipboard as it was and beeps.
- **Compare: allowed, by the still (decision).** Compare is for judging
  pictures side by side with synchronised zoom; a player per pane would
  mean up to four decoders and audio routes at once, and playing in step
  isn't what Compare is for. Leaving videos out (as the slideshow does)
  would make choosing between two takes of a clip impossible here, and
  the still is free: it is the viewer's own first frame, through the same
  loader and cache. The pane says "Video, 0:12" so it is never taken for a
  photo. No frame commands or playback exist in the Compare window.
- **No hover scrubbing in the grid** (not wanted: lean). A thumbnail is one
  frame; nothing decodes as the pointer moves.
- **Memory and battery.**
  - Idle means idle: no player exists until the user asks to play; a
    paused player decodes nothing; a hidden or covered viewer pauses
    (part 1).
  - One player at a time: only the viewer makes one, minivu shows one
    viewer, and it stops its player before showing another item.
    `VideoPlayback.liveCount` counts players made and not stopped, and the
    tests hold it to 0 or 1.
  - No thumbnail storms: the thumbnail service runs at most a worker per
    core (less two), last in first out, dropping thumbnails scrolled past
    before their turn; inside that, `VideoFrames.frameSlots` lets at most
    three frames decode at once, whatever the number of workers. A video's
    thumbnail now opens its file once (the length is read from the asset
    the frame is taken from, not from a second `info` read).
    `VideoFrames.decoding` counts frames in flight and their peak, for the
    test.
  - The grid's lengths are read one file at a time on a utility queue
    (`PixelSizeCache`, part 1).

### Limits

- A video's metadata (location included) is shown, never removed or
  edited.
- The saved or copied frame is SDR and carries no metadata (no date or
  location from the movie).
- Copy Frame and Save Frame As are in the viewer only; in the browser, open
  the video first.
- Compare shows a video's first frame only.

### Tests

- MinivuCoreTests/VideoFramesTests: `infoPanelShowsDataRateDateAndLocation`
  (a movie written with an iPhone's QuickTime keys: sections, data rate,
  date on the camera's clock with its offset, GPS, make and model);
  `readsISO6709AndQuickTimeDates` (all three ISO 6709 forms, bad input,
  zoned and unzoned dates, the data-rate text); `infoPanelDescribesTheVideo`
  now expects the Dates section the container's own date gives and the
  data rate; `aFolderOfVideosDecodesAFewFramesAtATime` (ten videos, a
  worker each: every thumbnail arrives, at most three frames decode at
  once, cancelled ones never decode; it fails with eight at once if the
  cap is lifted).
- MinivuTests/VideoTests: `copyFrameAndSaveFrameAsTakeTheFrameOnScreen`
  (private pasteboard: the black first frame at the video's size before
  playing, the blue frame after seeking to 1.5 s, Save Frame As pausing and
  handing over that time, both off for a photo, ⌘C still off);
  `VideoFrameSaveTests.savesTheFrameAtItsOwnSize` (the write through
  `SavePresenter.write`: size, colour, name, no metadata, the movie
  untouched); `onePlayerAtATime`; `VideoCompareTests.aVideoIsComparedByItsStill`;
  `VideoPreviewPaneTests.showsTheStillWithTheLength`.
- MainMenuTests: Copy Frame after Copy Subject, Save Frame As… after Save
  As…, neither with a key; the File menu's titles.

## HDR check: every effect keeps highlights on macOS 27

`hdrHighlightsSurviveEveryKindOfTool` (MinivuRenderTests/EditRendererTests)
now runs every effect: bump map, sketch, oil paint, lens, frame,
grayscale, sepia and negative, beside drop shadow ("effect"). Preview
(through the Lanczos proxy) and full resolution are both checked.

- **Found and fixed: the bump map.** It handed the photo and its height
  field to its sampling kernel with their edges repeated by
  `clampedToExtent()`, which macOS 27 brings back clipped to 1: an HDR
  photo's brightest value came out 1.0 in both lanes. Now the photo is
  passed as it stands (the kernel reads it only at the pixel it writes),
  the height field is made from the unclamped photo and cropped to it,
  blurred over repeated edges only where a Gaussian blur reads them (which
  doesn't clip), and the kernel holds its height samples to the image's
  bounds itself (`bounds` argument), as the noise-reduction kernel already
  did. `EffectsTests.bumpMapKeepsAndShadesHDRHighlights` (a 3.0 square on
  1.5 ground, from a bitmap and from a half-float texture) failed with 1.0
  before the fix and passes after: the flat middle keeps 3.0, the edge
  facing away is shaded, the picture's edges stay 1.5.
- **Measured and fine:** oil paint (already fixed with `sourceBounds`),
  lens (a warp kernel over a clamped image does not clip), frame,
  grayscale, sepia.
- **By design not HDR:** the sketch is a drawing on white paper, so its
  test checks the highlights reach white (between 0.95 and 1.01) rather
  than stop short; the negative turns values above white into values below
  black, so its test checks the darkest value goes below -0.2 (a highlight
  clipped to 1 first would stop at 0).

### Where the documentation should change

- **DESIGN.md 1 (Goals and non-goals):** videos are shown and played; add
  "video editing, trimming and conversion" to the non-goals.
- **DESIGN.md 3 (Formats):** a row for videos (the extensions above,
  decoded by AVFoundation, played by AVKit), and that
  `ImageFormats.videoExtensions` is the candidate list intersected with
  what AVFoundation reports.
- **DESIGN.md 4.2 (The decode path):** a paragraph on videos: still and
  thumbnail through `VideoFrames`/`AVAssetImageGenerator`, GCD callers,
  the 10 s limit, three frame slots.
- **DESIGN.md 4.3 (Colour and HDR):** HDR video stills via `.matchSource`;
  playback HDR is AVKit's; Show HDR off and macOS 26's
  `preferredDisplayDynamicRange`.
- **DESIGN.md 4.5 (Memory):** the frame slots and that no player exists
  until asked.
- **DESIGN.md 5, Browser window / Filter and sort:** the badge and length;
  Photos Only / Videos Only.
- **DESIGN.md 5, Viewer, Keyboard (viewer):** Space and P play/pause a
  video, M mutes; the arrows still move.
- **DESIGN.md 5, Menu shortcuts table:** Image > Play Video / Pause Video
  shares P with Play Animation; Image > Mute Video, M (display);
  View > Filter > Photos Only, Videos Only (none).
- **DESIGN.md 5, Tools (Phase 7):** slideshow, Batch Convert, Print,
  Contact Sheet and Montage skip videos; Batch Rename includes them.
- **DESIGN.md 4.8 Slideshow playback:** "`SlideshowAudioPlayer` is the only
  file that imports AVFoundation" is no longer true (MinivuCore's
  `ImageFormats`/`VideoFrames` and the viewer's `ViewerVideo.swift` do).
- **DESIGN.md 6 (Efficiency rules) / 4.4:** the viewer's "idle means
  idle" note: a player only while asked for, paused when hidden.
- **DESIGN.md 8 (Known limits):** the limits above.
- **Wiki:** Browser (videos in the grid, filter), Viewer (playing videos,
  keys), Formats (video types), Tools (what skips videos).
- **Help pages (Sources/Minivu/Help/HelpPages):** Browser.md (badge,
  filter), Viewer.md (a "Videos" section: play, pause, mute, keys, what is
  greyed out), Tools.md (slideshow and batch tools skip videos),
  Getting Started (videos are shown too).
- **Keyboard Shortcuts page (`KeyboardShortcutsPage.directKeySections`):**
  Viewer: "Play or pause a video: Space, P" and "Mute or unmute a video: M";
  "Next image" stays "→ ↓ Space" with a note that Space plays a video
  instead. HelpTests' `directKeysMatchTheKeyTables` should then press
  `ViewerKeyCommand.command(…, isVideo: true)` for those rows.

Part 2 and the HDR check add:

- **DESIGN.md 4.2 / 4.5:** `VideoFrames.metadata` is read only for the
  info panel; a video's thumbnail opens its file once; `VideoFrames.decoding`
  and `VideoPlayback.liveCount` as the checks behind "three frames at
  once" and "one player".
- **DESIGN.md 5, Viewer:** Copy Frame and Save Frame As (the frame on
  screen, the video's own size, SDR, no metadata).
- **DESIGN.md 5, Browser window / preview pane:** the play mark and length
  beside the stars; the info panel's Data rate, Camera, Dates and GPS for
  a video.
- **DESIGN.md 5, Compare:** videos allowed, compared by their first frame,
  "Video, 0:12" in the header, never played.
- **DESIGN.md 5, Menu shortcuts table:** Edit > Copy Frame and File > Save
  Frame As… (no shortcuts).
- **DESIGN.md 4.x Save As:** the `videoFrame` source, `suggestedName`,
  metadata options hidden for a frame.
- **DESIGN.md, "Core Image on macOS 27" (end of section 7):** add that a `clampedToExtent()`
  image read by a sampling general kernel (`CIKernel` with a sampler) is
  also clipped to 1, and that the bump map now passes the photo unclamped
  and holds its height samples to the image's bounds in the kernel (as the
  noise-reduction kernel does), with the Gaussian blur the only consumer
  of a repeated edge. Note that every effect is now in
  `hdrHighlightsSurviveEveryKindOfTool`, with the sketch and negative
  checked for what they do with a highlight.
- **DESIGN.md 8 (Known limits):** a video's location can't be removed
  (with the reasons above); frames are saved and copied in SDR without
  metadata.
- **Wiki:** Viewer (Copy Frame, Save Frame As), Browser (preview pane
  badge, video metadata), Compare (videos by their still).
- **Help pages:** Viewer.md's "Videos" section (Copy Frame, Save Frame
  As…, what the info panel shows), Browser.md (the preview pane's badge),
  Compare (videos by their first frame).
- **Keyboard Shortcuts page:** nothing new (both commands have no key).

