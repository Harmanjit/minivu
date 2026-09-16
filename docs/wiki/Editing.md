# Editing

Editing happens in the viewer (see [Viewer](Viewer)). Every change is kept as a step in a list and shown as you make it, but the file on disk stays exactly as it was until you save. The Image menu holds every tool; the File menu holds Save, Save As and Revert to Saved; the Edit menu holds Undo and Redo. The in-app help (**Help > minivu Help**, ⌘?) has a shorter version of this page under Editing and Effects & Retouching.

## How an edit works

An image gets an edit session the first time you open a tool on it or change it, so looking at photos costs nothing extra. The session decodes the original once at full resolution and keeps an ordered list of operations: a crop, a Lighting change, a frame. Undo and redo move a cursor through that list, and the picture is rendered again from it. Every change renders on a screen-sized copy of the original; zoom in past that copy and the current state renders at full resolution in the background. Saving renders at full resolution once more and encodes the result.

Lengths are stored in pixels of the full image, or as a share of its short side, so a 10 px blur looks the same on screen as in the saved file.

The render works in extended linear Display P3 in half floats, so wide-gamut colours and HDR highlights pass through every operation that isn't meant to clip them. An original wider or taller than 16384 px is shown at that size while you edit and saved at its own size.

Still images can be edited, including one page of a PDF or a multi-page TIFF. Animated GIFs and PNGs can't, because only one frame would be saved. Edits are not stored anywhere but the open session: move on without saving and they are gone, after you have been asked.

## The tools panel

Move the pointer to the left edge of the viewer, or click **Show Edit Tools** in the control bar, for the tools panel. It lists the tools in four groups: **Adjust** (Resize, Crop, Rotate & Flip, Straighten, Lighting, Colors, Curves, Levels, Sharpen, Blur), **Effects** (Color Effects, Drop Shadow, Frame, Bump Map, Sketch, Oil Painting, Lens), **Draw** (Text and Shapes) and **Retouch** (Clone Stamp, Healing Brush, Red-Eye Removal). The same tools are in the **Image** menu.

Opening a tool replaces the list with its controls and keeps the panel open; the chevron at the top goes back to the list. One tool is open at a time.

- **Apply** adds the change as one step, **Cancel** leaves it out, and **Reset** puts the controls back where they started. Return applies and Esc cancels, from the canvas or a number field.
- Sliders in the adjustment, effect and retouch tools have a number field beside them: type a value and it is clamped to the slider's range. Double-click a slider to reset it. (Text and Shapes sliders show their value but have no field.)
- Tools that preview as they open (Sharpen, Blur and every effect) show their starting settings at once, so opening Drop Shadow already shows a shadow.
- While a tool is open you can still zoom and pan.

**Switching tools.** Choosing another command while a tool is open closes it first. What happens to its changes depends on the kind of tool. Tools of settings (sliders, curves, levels, crop and the effects) are cancelled, so looking through the effects doesn't stack every one you looked at. Tools of hand-made steps (Clone Stamp and Healing Brush strokes, red-eye circles, Text and Shapes objects) apply what you have done, so a drawing doesn't vanish because you pressed ⌘R. Only Cancel, Esc, the back chevron or Undo drop those. Save and Save As apply whatever tool is open before they write.

## Undo and redo

**Edit > Undo** (⌘Z) and **Redo** (⇧⌘Z) step back and forward, up to 50 steps. Older steps stay applied; they just can't be undone. An undo is a cursor move and a render, so it costs no extra memory. The menu names the step, such as **Undo Crop**. Undoing back to what was last saved leaves nothing to save.

With a tool open, ⌘Z first takes back its unapplied change (closing the tool), or in the tools of hand-made steps, only the last stroke, circle or drawing change. After a save the viewer reloads the image from the saved file, keeping zoom and pan, and the history starts again from there.

## Rotate, flip, resize and crop

**Rotate Left** (⌘L), **Rotate Right** (⌘R), **Flip Horizontal** and **Flip Vertical** apply at once, each one step. In the panel they are under **Rotate & Flip**, which also has a **Straighten…** button and stays open for the next press until you click **Done**. In the viewer a rotation is an edit like any other, and Save re-encodes the file.

**Rotating in the browser is lossless.** The same four commands in the browser change the orientation tag of JPEG, HEIC, TIFF and PNG files without re-encoding a pixel, a few files at a time off the main thread. Camera raw files are never modified; they, GIFs, BMPs and anything else without an orientation tag are skipped and named in one alert afterwards. In a multi-page TIFF only the main image turns; the other pages keep their orientation. Two quick presses of ⌘R turn a photo twice.

**Resize/Resample…** (⌥⌘I) opens the Resize Image sheet: **Unit** (Pixels or Percent), **Width**, **Height**, **Keep aspect ratio**, and **Resampling**, one of 11 filters: Box, Triangle (Bilinear), Hermite, Bell, B-Spline, Mitchell, Catmull-Rom, Cosine, Quadratic, Lanczos 3 and Lanczos 8. Lanczos 3 is the default, and the last filter chosen is remembered. The sheet shows the current and new size in pixels and megapixels. A side can be at most 32,768 px. Filtering is done in linear light on the GPU.

**Crop…** (⌘K) puts a rectangle over the image, with the outside darkened. Drag a corner or edge handle to resize it, drag inside to move it, or drag outside it to draw a new one; a rule-of-thirds grid shows while you drag. **Aspect** is Free, Original (the image's own shape), 1:1, 4:3, 3:2, 16:9 or 5:4, and **Orientation** swaps Portrait and Landscape (not for 1:1). The panel shows the size and position in pixels. Double-click inside the rectangle, press Return or click **Apply** to crop.

**Straighten…** turns the image by **Angle**, −45° to 45°, over a grid for lining up a horizon or a wall, and crops the empty corners away to the largest upright rectangle inside.

## Tone and colour

| Tool | Controls | Shortcut |
|---|---|---|
| **Image > Adjust > Lighting…** | Brightness, Contrast, Gamma, Shadows, Highlights | ⌥⌘L |
| **Image > Adjust > Colors…** | Hue, Saturation, Lightness, Temperature, Tint; Red, Green, Blue | ⌥⌘C |
| **Image > Adjust > Curves…** | a curve for RGB, Red, Green and Blue | ⇧⌘M |
| **Image > Adjust > Levels…** | input black, gamma and white; output black and white, per channel | ⇧⌘L |
| **Image > Adjust > Sharpen…** | Amount, Radius | none |
| **Image > Adjust > Blur…** | Radius | none |

**Lighting.** Brightness, Contrast, Shadows and Highlights run from −100 to 100. Brightness lifts or lowers every tone by up to half the range; Contrast scales the distance from middle grey by up to three times either way; Shadows and Highlights brighten or darken one end of the range by up to 1.5 stops, fading out towards the other end. **Gamma** runs from 0.20 to 5.00 on a logarithmic slider, with 1 in the middle; above 1 brightens the midtones.

**Colors.** **Hue** turns every colour around the wheel, −180° to 180°. **Saturation** goes from grey to twice as saturated, **Lightness** fades towards black or white, **Temperature** moves the white point warmer or cooler, and **Tint** towards magenta or green. The **RGB** section's Red, Green and Blue are a gain per channel of up to one stop either way, so black stays black. The **Color** and **RGB** sections are two operations, but changing both in one visit to the tool is still one undo step, **Undo Colors**.

**Curves.** Pick a channel above the graph; a faint histogram of the image sits behind it. Click to add a point, drag it between its neighbours, and drag it off the grid or double-click it to remove it. The two end points can move but not be removed. The selected point's input and output show as 0–255. The curve passes smoothly through its points without overshooting them. Each colour channel's curve applies first and the RGB curve to the result, so an S curve on RGB adds contrast on top of a colour correction.

**Levels.** Under the histogram are the black, midtone and white input handles, and under those a grey ramp with the two output handles. The same five values can be typed: **Input** Black, Gamma and White, and **Output** Black and White, as 0–255 (gamma 0.10 to 9.99). Output white below output black inverts the channel. As with curves, a colour channel applies before RGB.

**Sharpen** is an unsharp mask: **Amount** 0 to 5 (1.00 to start) and **Radius** 0.5 to 20 px (1.5 px). **Blur** is a Gaussian blur with **Radius** 0.5 to 100 px (2 px); the image's edge pixels are repeated outward, so the edges don't fade. Both lengths are pixels of the full image.

## Effects

**Image > Effects > Grayscale**, **Sepia** and **Negative** apply at once, each one step; in the panel they are together under **Color Effects**. Grayscale keeps each colour's brightness, and Negative inverts on the encoded scale, so middle grey stays middle grey.

The other effects open with their settings in the panel and a live preview. Sizes given as a percentage are a share of the photo's short side, so an effect looks the same on a 2 MP and a 50 MP photo.

- **Drop Shadow…** puts the photo on a larger canvas with a soft shadow. **Shadow:** Offset X and Offset Y (−10% to 10%, 2% to start), Blur (0–10%), Opacity (60% to start) and Color. **Canvas:** Margin (0–20%), Corner radius for the photo (0–25%) and Background, which can be transparent. JPEG and BMP flatten transparency when saved.
- **Frame…** adds a border on a larger canvas. **Style** is Solid, Matte, Bevel or Polaroid, with **Width** (0–25%, 4% to start) and **Color** (called **Mat** for Matte). Matte is a mat inside a thin outer band, with a keyline around the photo; its section sets **Outer band**, **Keyline** (0–2%) and **Keyline color**. Bevel is a raised moulding lit from the top left. Polaroid's bottom is three and a half times as deep as its other sides.
- **Bump Map…** lights the photo as if its brightness were a relief. **Strength** 0 to 5, **Relief size** 1 to 8 px (larger follows broader shapes), **Color** 0–100% (at 0% the relief shows alone, in grey), and the **Light**'s **Angle** (135° is the top left) and **Elevation** (10° to 90°).
- **Sketch…** draws the photo from its edges. **Style** is Pencil, Charcoal or Colored Pencil; **Strength** sets how dark the lines are, and **Line width** (1–40 px) how far a line spreads, so wider lines pick up softer edges. The width starts at 6 px for a 24 MP photo, scaled with the photo's size.
- **Oil Painting…** paints the photo in brush strokes. **Brush size** is 1 to 16 px of the full image, starting at 4 px for 24 MP scaled with the size, so zoom to 100% to judge it. **Levels** (10–60, 30 to start) sets how many brightness steps there are; fewer paints flatter patches.
- **Lens…** magnifies a round part of the image as if under a lens. **Magnification** runs from 0.5× to 3× (below 1× the lens pinches), **Radius** from 2% to 100%, and **Glass rim** adds a glassy edge. Drag inside the circle to move it, drag its edge to resize it, and double-click inside to apply.

## Retouch

**Clone Stamp…** copies one part of the image over another exactly. **Healing Brush…** copies texture the same way, then matches its tone and colour to what surrounds the spot, which suits dust and blemishes.

Option-click where to copy from, then paint. The source follows the brush at the same distance for every stroke (**Aligned**, always on). A circle under the pointer shows the brush and a dashed one the source. The panel sets:

- **Size** in pixels of the full image, starting at 3% of the short side. [ and ] make it a fifth smaller or a quarter larger.
- **Hardness**, 50% to start, and **Opacity**, 100% to start.

The panel also shows whether a source is set and how many strokes there are. ⌘Z takes back the last stroke and ⇧⌘Z brings it back. **Apply** adds every stroke as one step.

**Red-Eye Removal…** darkens red pupils inside circles. **Auto Detect** looks for faces with Apple's Vision framework, on this Mac, in a 1600 px rendering of the image with its edits so far, and adds a circle for each eye that is red and not already covered by one of yours. Or drag from a pupil's centre to draw a circle, or click one for a circle of the default size. Drag a circle to move it; Delete removes the selected one. Only reddish pixels inside a circle change, so the catchlight stays. Each circle is listed under **Eyes** with its own **Strength** and a button to remove it, and ⌘Z removes the last circle.

## Text and Shapes

**Image > Text and Shapes…** adds text, lines, arrows, highlights, rectangles, ovals and callouts. The toolbar at the top of the panel picks Select or one kind of object, and the hint under it says how to draw:

- **Text:** click or drag. **Callout:** drag to draw the bubble, then drag its yellow handle to point.
- **Line** and **Arrow:** drag; Shift keeps it to 45°. **Highlight** and **Rectangle:** Shift makes a square. **Oval:** Shift makes a circle.
- **Select:** click an object, drag it to move it, and use its handles to resize or turn it (lines, arrows and callouts don't turn). Double-click text to edit it.

The style section applies to the selected object, or with nothing selected, to the next object of that kind: **Stroke** (or **Border** for text), **Width**, **Line** (Solid, Dashed or Dotted), **Arrowheads** (None, End or Both) and **Head size** for lines and arrows, **Fill** or **Background** with a colour, **Opacity** and **Shadow**. A highlight has a single **Color** in place of stroke and fill, and multiplies with what is under it, as a marker does. Text objects and callouts add a **Text** section: **Font** (System or any installed family), **Weight**, **Size**, **Alignment**, **Color**, **Outline** and **Fit height to text**. A selected object gets **Bring to Front**, **Send to Back**, **Duplicate** and **Delete** buttons.

Arrow keys nudge the selection by one pixel of the image, ten with Shift. ⌘D duplicates, Delete removes, and Esc deselects (with nothing selected, Esc cancels the tool). ⌘C, ⌘X and ⌘V copy, cut and paste the selected object; the copied object stays while minivu runs, so it can go from one image to the next. The tool has its own undo of up to 100 changes, and ⌘Z takes back one change at a time.

Objects are drawn as vectors at whatever size the image renders, so text stays sharp at 100% and in the saved file. **Apply** adds the drawing as one step. Open Text and Shapes again while that drawing is still the last step, and it comes back as objects to edit. Once another edit is on top of it, or the image is saved, the tool starts a new drawing.

## Saving

| Command | Shortcut |
|---|---|
| **File > Save** | ⌘S |
| **File > Save As…** | ⇧⌘S |
| **File > Revert to Saved** | none |

Every write to an image file (Save, Save As, a comment, a lossless rotate) goes through one queue, so ⌘S, an edit and ⌘S again land in that order. A small progress sheet appears only if a save takes long enough to notice. Quitting waits for queued writes to finish.

### Save

**File > Save** writes the edited image over the original, in the same format, colour space and bit depth, with the options last used in Save As for that format (or its defaults). Grey, CMYK, Lab and indexed-colour originals are written in sRGB, HDR originals in Display P3, and 16 bits per channel is kept only in PNG and TIFF. The file's metadata is always kept where the format can hold it (JPEG, PNG, HEIC and TIFF): the orientation is reset, because the pixels are now upright, the pixel size is updated, any embedded thumbnail is dropped, and a JPEG's comment is carried over. Camera Raw's edit settings and descriptions of an old gain map are left out.

Before writing, minivu asks **Replace the original “name”?** and says the format and quality it will write, because that quality is the last one chosen in Save As. The alert has **Don’t ask again**; to be asked again, turn **Ask before saving over the original** back on in **Settings > General** (see [Settings](Settings)).

The new file is written beside the old one under a hidden temporary name and swapped into place when complete, so a crash or a full disk never leaves a half-written photo. The swap keeps the file's creation date, permissions and Finder tags. Because the file is new, a hard link to the old one keeps the old picture; a symbolic link is written through to the file it points at.

minivu can't write some formats back: camera raw, WebP, AVIF, JPEG XL, PDF, SVG, PSD, animated files and multi-page files. For those, and for a file that has been renamed or moved away, Save opens Save As.

**HDR.** Saving a JPEG or HEIC that has a gain map keeps it HDR: the edit is rendered with the original's highlights and written as a new SDR image with a new gain map, whatever the viewer's HDR setting. PQ and HLG files, and gain maps in other formats, are saved tone mapped to SDR, and the Replace alert says so.

### Save As

**File > Save As…** opens the save panel as a sheet, in the folder last saved to (or the image's own folder). It starts with the file's own format if minivu can write it, otherwise the last format used, otherwise JPEG, and the extension follows the format you pick. The options under the file browser show only what applies to the format:

| Option | Formats | Notes |
|---|---|---|
| **Format** | JPEG, PNG, HEIC, TIFF, BMP, GIF, TGA, JPEG 2000, ICO | |
| **Quality** | JPEG, HEIC, JPEG 2000 | 1 to 100; starts at 90, or 80 for HEIC |
| **Color profile** | JPEG, PNG, HEIC, TIFF, JPEG 2000 | Keep original, sRGB, Display P3 or Adobe RGB (1998); the other formats are written in sRGB |
| **Compression** | TIFF | None, LZW (the default) or PackBits, all lossless |
| **Background** | JPEG, BMP | only when the image has transparency to flatten |
| **Progressive** | JPEG | |
| **16 bits per channel** | PNG, TIFF | on to start when the source is deeper than 8 bits, unless you have saved in that format before |
| **Keep metadata (EXIF, GPS, IPTC, XMP)** | JPEG, PNG, HEIC, TIFF | |

Options are remembered for each format. **Estimated size** is the size of the file these options would write, from a full encode shortly after the last change; for a large image that takes a while, it shows a figure worked out from a centre crop until the exact one arrives. **Compare…** (not for ICO) opens a Compare Quality window with the original and the saved result side by side at 100%, 200% or 400% (⌘= and ⌘-); for JPEG, HEIC and JPEG 2000 it has its own **Quality** slider that moves the panel's.

Save As always writes SDR: an HDR photo is tone mapped. **Keep original** on an edited image keeps a wide-gamut source's colour space and otherwise saves in Display P3, so colours an edit pushed past sRGB aren't clipped; grey, CMYK, Lab and indexed-colour sources are saved in sRGB. Saving over the image's own file counts as saving the edits; saving anywhere else leaves them unsaved in the viewer.

In the browser, **Save As…** converts the one selected image as it is. To convert many, use **Tools > Batch Convert…** (see [Tools](Tools)).

### Revert to Saved

**File > Revert to Saved** asks, then throws away every unsaved edit and shows the file as saved.

### Unsaved edits

minivu asks **Do you want to save the changes made to “name”?** before anything would lose unsaved edits: moving to another image or page, going back to the browser, opening another image from the browser, moving the image to the Trash (from the viewer, or from the browser while the viewer has it open), and quitting. **Save** saves first, **Don’t Save** (⌘D) discards the edits, and **Cancel** stays where you are. Changes in an open tool that you haven't applied count, since they are on screen; Save applies them.

### When another application changes the file

A document remembers the file's modification date and size from when editing began. If the file changes while you have unsaved edits (an external editor opened from minivu saves it, or Save finds it changed), minivu asks: **Reload** shows the new version and discards your edits, and **Keep My Edits** keeps them, after which Save asks for a new name so neither version is lost. The check runs again just before the file is written, and the write fails rather than replace a version saved while the question was up. minivu's own writes, such as an earlier Save or a comment, don't count as a change; a lossless rotate from the browser does, because the edits were made on the unrotated pixels. With no unsaved edits, the viewer simply shows the new version. For external editors, see [Tools](Tools).

## JPEG comments

**Image > Edit Comment…** edits the comment stored in a JPEG: the image shown in the viewer, or the one JPEG selected in the browser. The JPEG Comment sheet shows the text and its size in bytes. Return starts a new line; **Save** (⌘Return) writes the comment without re-encoding the image, replacing the file atomically, and Esc cancels. A comment longer than 65,533 bytes is stored in several segments, which minivu reads back as one.

Ratings and tags are kept in minivu's catalog rather than in the file; see [Browser](Browser). There is no editor for other metadata.

## What editing doesn't do

- No layers, masks or local adjustments; every tool changes the whole image, except the retouching tools, the lens and drawn objects.
- Edits aren't kept once you move on without saving, and undo doesn't reach back past a save.
- Save As writes SDR only, and Save keeps HDR only for gain-map JPEG and HEIC files.
- Animated files can't be edited.
- Adjustments can't be applied to many files at once; Batch Convert resizes, rotates and flips.

See [Limitations](Limitations) for the full list, and [Keyboard Shortcuts](Keyboard-Shortcuts) for every key.
