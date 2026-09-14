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
- **Crop…**: drag the rectangle or its handles. Choose Free, the image’s own
  shape, or 1:1, 4:3, 3:2, 16:9 or 5:4, in portrait or landscape.
- **Straighten…** turns the image up to 45° either way and crops the empty
  corners.
- **Adjust > Lighting…**: brightness, contrast, gamma, shadows and
  highlights.
- **Adjust > Colors…**: hue, saturation, lightness, temperature and tint,
  and separate red, green and blue.
- **Adjust > Curves…** and **Levels…** for precise tone control.
- **Adjust > Sharpen…** and **Blur…**.
- **Edit Comment…** sets the comment stored in a JPEG file. It is written
  into the file when you click Save in the comment editor.

For effects, drawing and retouching, see
[Effects & Retouching](help:Effects).

## Undo

**Edit > Undo** and **Redo** step back and forward through your edits, up
to 50 steps. Undo costs no extra memory, so step back as often as you like.
After you save, the undo history starts again.

## Save

- **File > Save** writes the edited image over the original, in the same
  format, color space and bit depth, with its metadata. minivu asks before
  replacing the original; if you told it not to ask again, turn **Ask before
  saving over the original** back on in **Settings > General**.
- minivu can’t write some formats back, such as RAW, WebP, AVIF, PDF,
  animated and multi-page files. For those, Save opens Save As.
- **File > Save As…** saves a new file. Choose the format (JPEG, PNG, HEIC,
  TIFF, BMP, GIF, TGA, JPEG 2000 or ICO) and its options: quality, color
  profile, metadata, progressive, 16-bit, TIFF compression and the
  background for transparency. The panel shows the file size the options
  will give, and can open a side-by-side comparison of the original and the
  compressed result at 100, 200 or 400%. Options are remembered for each
  format.
- **File > Revert to Saved** throws away your unsaved edits.
- If you move to another image, go back to the browser or quit with unsaved
  edits, minivu asks whether to save them first.

> If another app changes the file while you have unsaved edits, minivu asks
> whether to keep your edits or reload the file. If you keep them, Save
> becomes Save As, so neither version is lost.

Saving an HDR photo over the original writes it as a standard dynamic range
image.
