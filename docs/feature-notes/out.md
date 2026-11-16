# Feature notes: slideshow video and web gallery export (branch feature/out)

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
- Nothing opens afterwards: minivu doesn't play video (superseded: G18 in
  video.md added video playback), and opening Finder
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
  the writer can interleave them. Planning checks Cancel before each
  header it reads, so Cancel works at once even on a folder of thousands
  of pictures (the progress sheet stays at 0% while it plans).
- **No wait for ever**: each pump also runs a `SlideshowVideoWatchdog`, a
  250 ms timer on its own queue that ends the track if Cancel was pressed
  or the writer has failed. Without it, a writer failing (full disk,
  encoder error) while one track is held back could leave AVFoundation
  never calling that track's block again, with Cancel doing nothing. A
  failed writer is never asked to finish; its error is reported.
- **Internal storage only** (DESIGN.md 1): the save panel greys out folders
  on other volumes (`InternalVolumesOnly`, now also used as a save panel
  delegate), and the export checks `VolumePolicy` on the destination's
  folder again before reading or writing anything, failing with
  `ExternalVolumeError` ("“X” isn’t on this Mac’s internal storage…"). This
  is stricter than Save As and Contact Sheet, which don't check yet.
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
  resolve/release, trash, `didWrite` and `isAllowedVolume`, the planner's
  `isCancelled`.
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
- The dialog's "12 pictures · 1:05" counts every picture given; pictures
  whose header turns out unreadable are left out when the export plans, so
  the video can be shorter than the summary said. Reading every header
  just to open the dialog would cost more than it is worth.

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
- **DESIGN.md 1 / 4.2 (volume policy)**: list Export Slideshow Video and
  Create Web Gallery among the places `VolumePolicy` is enforced (panel
  delegate plus a check before writing), next to Batch Convert. Save As and
  Contact Sheet still don't check; a later pass could give them the same.

## G21: HTML web gallery

### What the user can do

- **Tools > Create Web Gallery…** in the browser (no shortcut, like Contact
  Sheet and Montage; between Contact Sheet… and Montage Wallpaper…). It
  takes the tools' pictures (`toolImages`): the selected pictures, or every
  picture shown (filters applied) when none is selected. Greyed out with no
  pictures and while a sheet is up (`canPerformTools`, with the other
  sheet-opening tools). Not in the viewer.
- **The dialog** ("Create Web Gallery", a sheet):
  - *Title*, starting as the browser folder's name. It heads index.html,
    each page's way back, and names the gallery's folder.
  - *Pictures*: Thumbnails (CSS px, 64–512, default 200; written at twice
    that for Retina screens), Large pictures (long side in px, 320–8192,
    default 1600; smaller pictures keep their size), Include the original
    files (off). With originals on, the section's footer says what happens
    to their metadata (see Privacy below).
  - *Layout*: Columns (stepper; 0 shows "Fit the window", a responsive grid,
    the default; 1–12 fixed, falling to two on screens under 640 px), Theme
    (Light, Dark, Automatic: follows the viewer's appearance; default
    Automatic), Order (As Shown, Name, Date Taken, Date Modified; default As
    Shown).
  - *Captions*: File name (on), Title and caption from the metadata (on:
    the title under each thumbnail; title and caption on the picture's
    page), Date taken (off; the date taken, else the modification date).
  - *File*: Format (JPEG, HEIC, AVIF; only formats this Mac's ImageIO can
    write are listed), Quality slider (10–100%, default 85%), Keep metadata
    (on), Remove location (on; off is only possible with metadata kept).
    The footer says where the format shows (HEIC: Safari only; AVIF: current
    Safari, Chrome, Firefox, Edge).
  - The bottom bar: "24 pictures · 25 pages · up to 1600 px", Cancel (Esc),
    Create… (Return). Every choice except the title is remembered (defaults
    key `webGallerySettings`, one Codable value; missing fields take their
    defaults, numbers are clamped into range).
- **Create…** closes the dialog and opens an open panel (folders only, New
  Folder allowed, prompt "Create Gallery") for the folder the gallery goes
  in, starting in the browser's folder; folders on external drives, memory
  cards and network shares are greyed out (internal storage only, checked
  again before writing: "“X” isn’t on this Mac’s internal storage…").
  Cancel returns to the dialog with its choices. The gallery is a new folder in it named after the title
  ("Trip"), or "Trip 2" if that name is taken; nothing is ever replaced.
- **Progress**: the contact sheet's progress sheet, "Picture 3 of 24", then
  "Writing the pages", with Cancel (Esc); shown after 0.3 s. Cancel leaves
  nothing in the chosen folder. Pictures that can't be read are left out
  and listed afterwards in an alert (up to eight); if none can be made, the
  usual save alert says why ("The web gallery couldn’t be created.") and no
  gallery is placed. Nothing opens afterwards (opening Safari or Finder
  would launch another app); the folder appears in the browser if it shows
  that folder.

### What is written

```
Trip/
  index.html          thumbnail grid: title, count, a linked thumbnail each
  style.css           the only style sheet
  pages/<stem>.html   one page per picture
  images/<stem>.jpg   large pictures (.heic / .avif as chosen)
  thumbnails/<stem>.jpg
  originals/<name>    only with Include the original files
```

- **One page per picture with Previous and Next, no JavaScript at all**
  (chosen over a lightbox). It works with scripts off and from `file://` in
  any browser, each picture has its own address to bookmark or send, Back
  works, large pictures load only when their page opens, and screen readers
  get plain links and headings. Each page has a bar (the title linking back
  to its thumbnail in the grid, "3 of 24", Previous, Next; at the ends the
  missing step is a dimmed `aria-disabled` span), `<link rel="prev/next">`,
  the large picture (clicking it steps on; the last goes back to the grid),
  its captions, and "Download the original file (name)" when included.
- **Nothing from outside**: no fonts (the system font stack), no scripts,
  analytics or CDN links; every `href`/`src` is a relative path inside the
  gallery. Each page carries a Content-Security-Policy meta forbidding
  scripts, objects, frames, forms and `<base>` (a second line of defence),
  `referrer: no-referrer`, and `generator: minivu`. The CSP deliberately
  leaves images and styles unrestricted, since `'self'` is unreliable for
  `file://` pages.
- **Pictures** go through Batch Convert's own path: `BatchConverter.image`
  with a long-side `BatchResize` (Lanczos, never enlarging), the viewer's
  RAW setting, always SDR; then `ImageEncoder` with the Save As rules,
  always **sRGB**, progressive JPEG. Thumbnails are drawn from the large
  picture with Core Graphics (high interpolation) and carry no metadata.
  AVIF is not a Save As format: the new `ImageEncoder.encode(_:typeIdentifier:options:metadataSource:)`
  writes it with HEIC's rules (both are HEIF files; EXIF and IPTC survive,
  checked). `img` tags carry width and height, so pages don't jump while
  loading; thumbnails use `loading="lazy"`.

### Security

- **Escaping**: `WebGalleryHTML.escape` is applied to every string from a
  file name or metadata (and the title) in text and attributes alike:
  `& < > " '` become references, attributes are always double-quoted, and
  control characters HTML forbids (and U+FFFE/U+FFFF) become U+FFFD.
- **Links**: `WebGalleryHTML.link` percent-encodes each path component as
  precomposed UTF-8, keeping only RFC 3986 unreserved characters, so a name
  can't add a scheme (`javascript:`), a query, a fragment or a `/`; the only
  `..` is the one the page itself adds. Thumbnail anchors are `p1`, `p2`…,
  never names.
- **File names** (`WebGalleryPlanner.safeName`): control characters, `/`,
  `:` and `\` become `-`, leading dots and spaces go (no hidden files, no
  `..`), names are cut to 200 bytes of UTF-8, then checked with
  `FileOperations.nameProblem` ("picture" stands in when unusable). Pages,
  large pictures and thumbnails share one stem per picture; stems (and
  originals' names) are made unique with Batch Convert's
  `BatchNameKey.uniqueName` ("photo 2"), compared without case or Unicode
  normalisation whatever the volume, so the gallery survives being copied
  to a case-insensitive disk or a web server. The gallery folder's name is
  the title made safe ("Web Gallery" if nothing is left), numbered with
  `FileOperations.uniqueName`.
- **Atomic and cancellable**: everything is written into a scratch folder
  on the destination's volume (`ContactSheetExport.scratchFolder`, the
  system's item-replacement folder), then the finished folder is moved in
  with one exclusive rename (`FileOperations.moveExclusively`, retried
  under the next free name if another app took it) through
  `FileWriteQueue.shared.enqueue(replacing:)`. Cancel, a failure or a quit
  leaves either no gallery or a complete one; the scratch folder is always
  removed.
- **Privacy**: Remove location is on by default; thumbnails never carry
  metadata. **Originals** are copied byte for byte except their location:
  unless the large pictures keep it (Keep metadata on *and* Remove location
  off, `WebGallerySettings.originalsKeepLocation`), each copy that has a
  location is rewritten in place by wave 1's lossless `MetadataWriter`
  (`MetadataEdit(removeLocation: true)`: GPS, its XMP mirror and the IPTC
  place names; no pixel re-encoded; other metadata kept) and read back. An
  original it can't be removed from (a camera raw, which gets only a
  sidecar; GIF, WebP and other formats the writer doesn't rewrite; a write
  that didn't take) is left out of originals/, its page has no download
  link, and an alert after the gallery is made names it ("1 original file
  was left out of the gallery." with the reason), alongside any pictures
  left out. Original copies without a location are untouched. Sidecars are
  never copied.
- **Internal storage only**: the open panel has the `InternalVolumesOnly`
  delegate, and the export checks `VolumePolicy` on the chosen folder
  before writing anything (`ExternalVolumeError`), as Batch Convert does
  for its output folder. No entitlement was added: the open panel grants the folder,
  and the sources are already readable. No network code.

### Design decisions and why

- **One picture at a time**, on GCD threads through `BatchWorkExecutor`
  (the render and two encodes block): memory stays one picture plus its
  thumbnail, and at most one camera RAW render is in hand, matching
  `BatchConvertJob`'s RAW rule without its slot. Headers are read for
  titles, dates or Date Taken order only (`WebGallerySettings.needsMetadata`),
  through `MetadataFields.read` (XMP first, then IPTC/EXIF, sidecars laid
  over).
- **Thumbnails at 2×** of a CSS size rather than a pixel size, so the grid
  is sharp on Retina screens and the setting means what the reader sees.
- **sRGB always**: browsers assume it for untagged pictures, and it shows
  right even without colour management; the dialog says HDR photos look as
  on a standard display.
- Code: `Sources/MinivuCore/WebGallery/` (settings, planner and names, HTML
  and CSS; pure and tested in milliseconds), `Sources/Minivu/Tools/WebGallery/`
  (`WebGalleryExport`, `WebGallerySheet` with model, view and controller,
  `BrowserWebGallery`). Seams for tests: `WebGalleryExport.chooseFolder`,
  the converter, `readFields`, `formatDate`, `isAllowedVolume`.

### Limits

- Pictures are made one at a time, so a large gallery takes a while (about
  as long as a one-at-a-time Batch Convert).
- Fixed English text on the pages ("Previous", "Next", "3 of 24"); the
  page's `lang` is "en".
- No per-gallery colours or custom templates; three themes only.
- HEIC galleries only show in Safari; the dialog says so.
- Animated pictures become stills (the first frame).
- Multi-page files contribute their first page.

### Where the docs should change

- **DESIGN.md 4.8 Tools**: a "Web gallery" paragraph: the folder layout,
  pages without script, the escaping and link-encoding rules, safe and
  unique names via `nameProblem` and `BatchNameKey`, rendering through
  `BatchConverter` + `ImageEncoder` (sRGB, AVIF via HEIC rules), scratch
  folder + one exclusive rename through `FileWriteQueue`, one picture at a
  time.
- **DESIGN.md 4.7 Editing / export**: `ImageEncoder` can now write a
  destination type outside `ExportFormat` (AVIF) with another format's rules.
- **DESIGN.md 5, menu table**: Tools gains "Create Web Gallery… | none"
  after Contact Sheet…; the Tools paragraph describes the dialog.
- **DESIGN.md 8 Known limits**: one picture at a time; English page text;
  HEIC galleries Safari only.
- **Wiki Tools.md** and help **HelpPages/Tools.md**: a "Web Gallery"
  section with the dialog's choices, the folder it makes, opening it from
  disk, Cancel, and what each format plays in.
- **Wiki Security-and-Privacy.md** / help Privacy.md: galleries contain no
  external links or scripts; location removed by default, from the large
  pictures and from included originals (an original whose location can't
  be removed, such as a camera raw, is left out); thumbnails carry no
  metadata; galleries are written to internal storage only.
- **Wiki Keyboard-Shortcuts.md** / the keyboard-shortcuts page: nothing (no
  shortcut), unless it lists every Tools item.
