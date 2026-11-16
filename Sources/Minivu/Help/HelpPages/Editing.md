# Editing

Editing happens in the viewer. Your changes are kept as a list of steps and
shown as you make them, but nothing on disk changes until you save.

## Open a tool

Choose a tool from the **Image** menu, or move the pointer to the left edge
of the viewer and pick one from the panel. The tool’s controls take the
panel’s place and it stays open while you work.

- **Apply** adds the change to the image, **Cancel** leaves it out, and
  **Reset** puts the controls back where they started.
- In the panel, **Rotate & Flip** and **Color Effects** apply each button
  at once; **Done** closes them.
- In the tools you draw or paint with, choosing another command applies
  what you have done so far, rather than dropping it.

## The tools

- **Rotate Left**, **Rotate Right**, **Flip Horizontal**, **Flip Vertical**.
- **Resize/Resample…** sets a new size in pixels or percent, with or
  without keeping the aspect ratio, using one of 11 resampling filters, from
  Box and Bilinear to Lanczos 8.
- **Canvas Size…** makes the canvas around the image larger or smaller, in
  pixels or percent. Choose where the image sits with the 3 × 3 anchor, and
  fill the new space with a color or leave it transparent. A smaller canvas
  crops the image.
- **Crop…**: drag the rectangle or its handles. Choose Free, the image’s own
  shape, or 1:1, 4:3, 3:2, 16:9 or 5:4, in portrait or landscape.
- **Straighten…** turns the image up to 45° either way and crops the empty
  corners.
- **Perspective…** straightens something photographed at an angle, such as
  a document or a building. Drag the four corner handles onto the corners of
  something that should be rectangular, or click **Auto** to find one.
  **Show result** previews the correction.
- **Adjust > RAW Adjustments…**, for camera RAW files only: exposure,
  boost (contrast), highlight recovery, white balance and noise reduction,
  starting from the camera’s own settings. minivu can’t save over a RAW
  file, so save the result with **Save As…**.
- **Adjust > Lighting…**: brightness, contrast, gamma, shadows and
  highlights.
- **Adjust > Colors…**: hue, saturation, lightness, temperature and tint,
  and separate red, green and blue.
- **Adjust > Curves…** and **Levels…** for precise tone control.
- **Adjust > Auto Enhance** improves the tone and color in one click. If
  the photo needs nothing, minivu beeps.
- **Adjust > Sharpen…**, **Blur…** and **Noise Reduction…**. Noise
  reduction smooths grain and keeps edges; its Sharpness slider brings back
  detail.
- **Edit Comment…** sets the comment stored in a JPEG file. It is written
  into the file when you click Save in the comment editor.
- **Edit Metadata…** (**⌘I**) changes the file’s details. See Metadata
  below.

For effects, drawing and retouching, see
[Effects & Retouching](help:Effects).

## Metadata

Metadata is the information stored with a photo: who took it, when, where,
and a title or keywords. **Image > Edit Metadata…** (**⌘I**) edits it for
the image shown, or for every image selected in the browser.

- **Description:** title, caption, creator and copyright.
- **Keywords:** add keywords, separated by commas, or remove one from every
  image.
- **Date Taken:** shift the date by days, hours, minutes and seconds, or
  set a new date and time.
- **Location:** **Remove location** takes out the GPS position and place
  names.

With several images, a field whose value differs shows “Mixed”. Leave it
empty to keep each file’s own value. Only fields you change are written.

Metadata is written into the file without re-encoding the picture. Camera
RAW files, and formats minivu can’t rewrite, get an XMP sidecar instead: a
small file of the same name beside the photo, which other apps read too.

## Undo

**Edit > Undo** and **Redo** step back and forward through your edits, up
to 50 steps. Undo costs no extra memory, so step back as often as you like.
After you save, the undo history starts again.

## Save

- **File > Save** writes the edited image over the original, in the same
  format, color space and bit depth, with its metadata. minivu asks before
  replacing the original; if you told it not to ask again, turn **Ask before
  saving over the original** back on in **Settings > General**.
- minivu can’t write some formats back, such as RAW, WebP, PDF, animated
  and multi-page files. For those, Save opens Save As.
- **File > Save As…** saves a new file. Choose the format (JPEG, PNG, HEIC,
  AVIF where your Mac can write it, TIFF, BMP, GIF, TGA, JPEG 2000 or ICO)
  and its options: quality, color profile, metadata, progressive, 16 or 10
  bits per channel, TIFF compression and the background for transparency.
- **Remove location**, under Keep metadata, leaves the GPS position and
  place names out of the new file. It starts turned on. Save, and Save As over
  the original file, always keep the location. The panel shows the file size the options
  will give, and can open a side-by-side comparison of the original and the
  compressed result at 100, 200 or 400%. Options are remembered for each
  format.
- **File > Revert to Saved** throws away your unsaved edits.
- **File > Save Edits as Preset…** keeps the edits as a preset, so **Tools >
  Batch Convert…** can apply them to many images. The sheet lists the steps
  it can use and those it leaves out, with the reason. See
  [Tools](help:Tools).
- If you move to another image, go back to the browser or quit with unsaved
  edits, minivu asks whether to save them first.

> If another app changes the file while you have unsaved edits, minivu asks
> whether to keep your edits or reload the file. If you keep them, Save
> becomes Save As, so neither version is lost.

Saving an HDR photo over the original writes it as a standard dynamic range
image.
