# Feature notes: slideshow video export (branch feature/out)

Notes for the documentation pass. Nothing here has gone into DESIGN.md,
the wiki or the help pages yet; the last section of each goal says where
it should.

## G9: Export a slideshow to video

### What the user can do

- **Tools > Export Slideshow Video…** (no shortcut, like Contact Sheet and
  Montage) in the browser and in the viewer. It is directly under Start
  Slideshow.
  - In the browser it takes the pictures Start Slideshow would play: two or
    more selected pictures on their own, otherwise every picture shown
    (filters applied), starting at the selected one (`slideshowImages`).
  - In the viewer it takes the viewer's whole list from the picture shown,
    as the viewer's slideshow does.
  - Greyed out with no pictures, and while a sheet is up on the window (the
    browser lists it with the other sheet-opening tools in
    `canPerformTools`; the viewer checks `attachedSheet`).
- **The dialog** (a sheet, "Export Slideshow Video") has two sections:
  - *Video*: Resolution (720p 1280 × 720, 1080p 1920 × 1080, 4K
    3840 × 2160, or Screen size: the pixel size of the screen the window is
    on, shown in the menu, made even and kept within 8192 px), Frame rate
    (24, 30 or 60 fps, segmented), Codec (H.264 or HEVC), Quality (Low,
    Medium, High, segmented) and File (MPEG-4 .mp4 or QuickTime .mov).
    Defaults: 1080p, 30 fps, H.264, Medium, .mp4. The choices are
    remembered (defaults key `slideshowVideoSettings`, one Codable value;
    a missing or unknown field takes its default, a frame rate other than
    24/30/60 becomes 30).
  - *Slideshow*: three read-only lines saying what the video plays with,
    taken live from Settings > Slideshow (slide time and transition, order
    and captions, music), and a **Slideshow Settings…** button that opens
    that pane. Changing a setting there updates the lines while the dialog
    is open.
  - The bottom bar says "12 pictures · 1:05 · 1920 × 1080" (count, length
    rounded up to the second, size), with Cancel (Esc) and Export… (Return).
- **Export…** closes the dialog and opens a save panel, named "<folder>
  Slideshow.mp4" (or .mov), starting in the browser's folder or the
  viewer's picture's folder. Cancel in the save panel goes back to the
  dialog with its choices. Replace in the save panel is honoured: the old
  file goes to the Trash first, as Contact Sheet does.
- **Progress**: a sheet with a bar, "N%" and Cancel (Esc), shown after
  0.3 s so a very short video doesn't flash it. Cancel stops at the next
  frame and leaves no file. A failure shows the usual save alert, "The
  slideshow video couldn’t be exported."
- Nothing opens afterwards: minivu doesn't play video, and opening Finder
  or a player would launch another app. The file appears in the browser
  if it shows that folder.

### What the video shows

- **The order a slideshow plays.** One pass from the starting picture:
  in order round to the picture before it, or shuffled with the starting
  picture first (`SlideshowSequence`, as a looping show plays its first
  pass). Loop doesn't apply: each picture is in the video once.
- **Timing in whole frames** (`SlideshowVideoTimeline`): the first picture
  fades in from black over one transition (as the live show's first slide
  does), every picture stays for the interval after its transition, each
  later one comes on with its transition, and after the last picture the
  video fades to black over one more transition. Length =
  pictures × (transition + interval) + transition. A transition's last
  frame is the still slide, and the video's last frame is black.
- **Transitions** from Settings: a fixed one for every slide, or Random,
  which never repeats the one before (the same rule as the live show). The
  first slide's fade-in and the final fade-out are cross-fades.
  **Reduce Motion is not applied to the file**: it governs what moves on
  this Mac's screen, while the video is made for other people and other
  screens, and the dialog's footer says so.
- **Captions** as Settings > Slideshow chooses (none, file name, name and
  date, camera and exposure), with the live caption's text
  (`SlideshowCaptionText`), white medium system text with the same soft
  shadow, bottom left, scaled with the picture (15 pt on a 900 pt screen,
  so 18 px at 1080p, 36 px at 4K). It swaps at the start of each
  transition, as the live caption does, fades in over the first quarter
  second and fades out with the final fade to black.
- **Background** black, as the live show's (it has no background setting).
  "Enlarge small images" follows the viewer setting, as the live show does.
- **No Ken Burns / zoom**: the live slideshow has no such effect, so the
  video has none either; it would be a new slideshow feature first.
- **Music**: when Settings > Slideshow plays music, the playlist's songs
  (bookmarks resolved with security scope, folders expanded, shuffled if
  Shuffle is on) are laid one after another, round and round, cut at the
  end of the video, faded in over 1 s and out over the last 1.5 s (the live
  show's fades), and encoded as AAC, 48 kHz stereo, 192 kbit/s. Songs that
  can't be read are left out; with none readable the video is silent
  rather than failing. The Volume slider is the playback volume and is not
  applied to the file. Nothing is ever played aloud.
- **SDR, Rec. 709.** HDR photos are tone mapped to SDR white by the
  slideshow shader (display headroom 1), exactly as on an SDR screen.

### Design decisions and why

- **The live show's own shader.** Frames are drawn by `SlideshowRenderer`
  (the same pipeline, geometry, easing and tone map as the live show and
  the Settings preview) into a `kCVPixelFormatType_64RGBAHalf` pixel buffer
  from a `CVPixelBufferPool`, seen by Metal through a `CVMetalTextureCache`.
  The pipeline's colour attachment is half float (extended linear Display
  P3), which the encoder can't take, so Core Image converts each frame
  into the writer's 8-bit BGRA buffer (from the adaptor's pool) in
  Rec. 709. No resampling filter and no `clampedToExtent` are involved, so
  the macOS 27 clipping issue cannot arise; it isn't an edit operation, so
  `hdrHighlightsSurviveEveryKindOfTool` doesn't apply.
- **Stills cost nothing.** A frame identical to the one before (every frame
  of a slide's stay) hands the encoder the same pixel buffer again: the
  GPU draws only transition frames.
- **Memory**: three slides at most (`SlideshowVideoSlides`: the one going
  away, the one arriving, and the next), each decoded fitted to the video
  size, one at a time on a decode queue of its own while frames draw. The
  decode is the viewer's (`ImageLoader.decodeOnce`, new: the same
  decode-and-upload as a load, embedded RAW preview or render as the RAW
  settings say, but outside the loader's queue and cache, so a 4K export
  doesn't fill the texture cache). Roughly 400 MB at 4K, 100 MB at 1080p.
  Pictures whose header can't be read are left out before writing starts
  (the live show skips them too); one that fails to decode later shows
  black for its time, so the length promised to the sound track holds.
- **Off the main thread**: planning (headers, caption metadata) and music
  resolution through `BlockingWork`; frames and sound each fed by
  `requestMediaDataWhenReady` on their own serial queue, side by side so
  the writer can interleave them.
- **Cancel leaves no file**: the video is written into a scratch folder on
  the destination's volume (`ContactSheetExport.scratchFolder`, the
  system's item-replacement folder, which the sandbox allows beside a file
  the save panel granted), the writer is cancelled and its file removed on
  cancel or failure, the scratch folder is always removed, and only a
  finished file is moved into place, through `FileWriteQueue.shared`
  (`enqueue(replacing:)`) with `ContactSheetExport.place`, then announced
  with `SavePresenter.didWrite` (own write, thumbnail and texture caches).
- **Bit rates** instead of the encoder's quality key, so sizes are
  predictable: H.264 0.04 / 0.08 / 0.16 bits per pixel per frame for Low /
  Medium / High (Medium is about 5 Mbit/s at 1080p30), HEVC 60% of that.
  A key frame every two seconds. H.264 uses High profile, auto level.
- **Seams for tests**: `SlideshowVideoExport.chooseDestination` (the save
  panel), the writer's `decode` and `isCancelled`, the export's music
  resolve/release, trash and `didWrite`.
- **Sandbox and privacy**: no entitlement added. AVFoundation writes a
  local file and reads local songs the user chose; no network.
- `SlideshowAudioPlayer` is no longer the only file importing
  AVFoundation: `SlideshowVideo.swift` and `SlideshowVideoWriter.swift`
  (MinivuRender) do too, for writing only.

### Limits

- **HDR video is a later step.** It would be HEVC Main10 with HLG (or PQ)
  for HDR sources: render with a display headroom of about 4.9 (HLG's
  1000 nit peak over 203 nit reference white), convert with Core Image into
  a `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` buffer in
  `itur_2100_HLG`, and tag BT.2020 / HLG colour properties. Not offered
  because checking that the levels come out right needs an HDR screen and
  a player, which the tests can't confirm.
- No per-video overrides of slide time, transitions or captions: the
  slideshow settings are the one place, so a show and its video agree.
- The final fade to black is always a cross-fade; random transitions
  differ from one export to the next (and from the live show's).
- An export can't be paused; quitting during one abandons it (the scratch
  folder is in the system's temporary space).

### Where the docs should change

- **DESIGN.md 4.8 Tools**, after "Slideshow playback": a paragraph
  "Slideshow video" with the frame path (SlideshowRenderer → CVMetalTextureCache
  half-float buffer → Core Image → writer pool BGRA, Rec. 709), the
  timeline, reused still buffers, three-slide memory, `ImageLoader.decodeOnce`,
  music composition and fades, scratch folder + FileWriteQueue placement.
  Amend the "Slideshow playback" bullet that says `SlideshowAudioPlayer` is
  the only AVFoundation file.
- **DESIGN.md 4.5 Memory**: one line for the export's three slides at video
  size, outside the texture cache.
- **DESIGN.md 5, menu table**: Tools gains "Export Slideshow Video… | none".
  The Tools paragraph: the browser takes the slideshow's pictures, the
  viewer its list from the picture shown.
- **DESIGN.md 8 Known limits**: HDR video not yet; Reduce Motion not applied
  to the file.
- **Wiki Tools.md** and help **HelpPages/Tools.md**, Slideshow section: a
  "Export as video" subsection with the dialog's choices, what the video
  follows from Settings, music, cancelling.
- **Wiki Keyboard-Shortcuts.md** / the keyboard-shortcuts page: nothing (no
  shortcut), unless it lists every Tools item.
- **Wiki Settings.md** / help Settings.md: Slideshow pane, note that the
  same settings drive exported videos; the dialog's choices are remembered
  separately.
- **Wiki Security-and-Privacy.md** / help Privacy.md: exporting writes only
  the chosen file; music is read through the bookmarks already kept.
