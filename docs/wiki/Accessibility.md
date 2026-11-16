# Accessibility

minivu gives VoiceOver names for the controls it draws itself, and follows two display settings, Reduce Motion and Increase Contrast. Both are read where they are used, so turning one on or off in **System Settings > Accessibility > Display** takes effect without relaunching. Everything built from standard AppKit and SwiftUI controls (menus, toolbars, Settings, sheets, the Help window) behaves as those controls do everywhere. In another language (see [Languages](Languages)) VoiceOver reads the translated names. The gaps are listed at the end and on [Limitations](Limitations).

## Keyboard

Every command is in the menu bar, and most have a key; see [Keyboard Shortcuts](Keyboard-Shortcuts). Culling and viewing need no pointer:

- **Browser.** The arrow keys move through the grid, typing a name selects a file, Return opens an image in the viewer or a folder in the grid, 0 to 5 rate the selection and `` ` `` tags it. **Image > Label** (⌥⌘0 to ⌥⌘7) sets a colour label and **Image > Edit Metadata…** (⌘I) edits the title, keywords, date and location. **Go > Enclosing Folder** (⌘↑), **Back** (⌘[) and **Forward** (⌘]) move between folders, and **File > Open Folder…** (⌘O) goes anywhere.
- **Finding.** **Edit > Find…** (⌘F) searches across folders and **View > Flat View** (⌥⌘F) shows a folder and its subfolders as one list. In the Find and **More Filters…** sheets, Return confirms and Esc cancels. **File > Add to Collection** adds the selection to a collection without dragging.
- **Files.** **File > Copy To** and **Move To** do what dragging onto a folder does, **Rename** is F2 and **Batch Rename…** ⇧F2.
- **Viewer.** The arrows, Space, Home and End step through the folder; +, -, / and \* zoom; Return switches between window and full screen, and Esc goes back. On a video, Space or P plays and pauses and M mutes, while the arrows still move between items.
- **Panels at the edges.** They open when the pointer reaches an edge, and three can be opened from the keyboard: F keeps the filmstrip open, ⇧⌘H (**Image > Histogram**) the info panel, and a tool chosen from the **Image** menu opens the tools panel with that tool's controls. The bottom control bar has no key, but its buttons, apart from Show Edit Tools, are menu commands too.
- **Tools.** Return applies the open editing tool and Esc cancels it. **Red-Eye Removal** has **Auto Detect**, which places its circles without a pointer.
- **Compare.** ⌘1 to ⌘4 or Tab choose a pane; the arrows change its image, 0 to 5 rate it, T tags it and ⌫ moves it to the Trash.
- **Find Duplicates.** Return starts the search and Esc stops it. The checkboxes, **Mark Suggested**, **Clear Marks** and **Move to Trash…** are standard controls, reached with Tab when keyboard navigation is on in **System Settings > Keyboard**.

## VoiceOver

- **Thumbnails read as one item.** A grid cell reads its name, stars, tag, Finder tags and pixel size, as in "IMG_2.jpg, 3 stars, tagged, Finder tags: Red, 6032 × 4032", and says whether it is selected. Unrated and untagged images say nothing about stars or the tag, as the cell shows nothing. A folder reads as "Trip, folder". A video says so with its length: "clip.mov, video, 0:12, 2 stars, 1920 × 1080". In the flat view, search results and other lists, the name is followed by its folder ("IMG_1.jpg, in 2024-06-01"), since two files there can share a name.
- **Sidebar.** Collections and smart folders say what they are: "Trip, collection", "Shots, smart folder".
- **The rating is one control.** The preview pane's stars read as "Rating" with a value from 0 to 5, and are adjustable: VO-↑ and VO-↓ rate the image as clicking a star would. The tag button beside them reads Tagged or Not Tagged.
- **Filmstrip.** Each frame reads the file's name, and the image shown is reported as selected.
- **Preview pane and info panel.** A video's play mark reads "Video, 0:12". Each keyword in the keyword editor has a remove button read as "Remove keyword Paris".
- **Live Text.** The layer over the viewer's picture that lets you select text is named "Text in the image".
- **Viewer and slideshow buttons** are read by what they do, without the key the tooltip adds: Previous Image, Next Image, Fit to Window, Actual Size, Zoom In, Rotate Left, Start Slideshow and so on. The ones that change say what a press will do next (Play or Pause, Full Screen or Show in a Window; in the slideshow, Play or Pause and Play Music or Mute Music).
- **Compare.** Each pane's stars read as "Rate 1 star" to "Rate 5 stars", its tag button as Tagged or Not Tagged, and its trash button as Move to Trash.
- **Sliders say their units.** Editing tools read each slider's name and the value as the panel shows it. In Settings, the magnifier's zoom reads in times and its size in points, the thumbnail size in points, and the slide time and transition duration in seconds; the slideshow volume is named too. Elsewhere, the montage spacing reads in points, and the rename pattern's minimum digits and the Save As comparison's quality slider are named.
- **Tool controls.** **Canvas Size…**'s anchor squares read as "Anchor: Top Left" and so on, and **Watermark…**'s position grid as "Position: Bottom Right". In Batch Convert, the preset menu's button reads "Preset Actions" and each step in **Edits** has a "Remove" button named after the step. In **Settings > Editors**, the row buttons read Move Up, Move Down and Remove with the app's name, and the warning triangle says the app is no longer where it was added.
- **Filters and duplicates.** In **More Filters…** and **Find…**, each type check box reads as, for example, "Show RAW files", range fields as "ISO, minimum" and date pickers as "Taken on or after". In **Find Duplicates**, the pickers read "Look in", "Find" and "Keep", the slider "Similarity threshold" with its value and the number of groups, and each row's checkbox "Mark IMG_1.jpg for the Trash", apart from the row, which reads its name, size, pixel size, date, folder and whether it is suggested to keep. Thumbnails there are hidden from VoiceOver.
- **Drawing and curves.** In **Text and Shapes…** the object buttons read their kind and which one is selected, the alignment buttons read Left, Center and Right, and number rows read their value with its unit. The **Curves…** and **Levels…** editors are named for their channel ("Curve for Red"). The histogram's channel buttons read RGB, Red, Green, Blue and Luminance rather than single letters.
- **Headings.** Help page headings and the info panel's section titles are marked as headings, so the rotor can jump between them.
- **Other names.** The toolbar's Sort, Filter and Thumbnail Size controls, the sidebar's Add Folder button and the rename field (Name) are labelled.

## Reduce Motion

- **Fly-out panels** fade in and out where they stand instead of sliding in from the edge.
- **View > Show Preview Pane** shows or hides the pane at once instead of sliding it.
- **The filmstrip** jumps to the current image instead of scrolling to it.
- **Slideshow transitions** that move the picture (Slide, Push, Wipe, Zoom and Iris) become a Cross-Fade. Cross-Fade, Fade Through Black and Dissolve change in place and stay as chosen. This applies to a Random choice too, and to a show that is already playing from its next slide.

The viewer's full screen has no animation in any case. The flat view, Find and the Find Duplicates window have none either.

A video made with **Tools > Export Slideshow Video…** always has the transitions you chose: Reduce Motion is a setting of this Mac, and the file plays elsewhere.

## Increase Contrast

A selected thumbnail gets a 2-point outline in the accent colour over its tinted fill, which on its own is faint against some photos. The grid redraws as soon as the setting changes. A folder under a drag is outlined whether or not the setting is on, and the focused pane in Compare always has an accent outline.

## Not yet

- minivu makes no VoiceOver announcements of its own: a rating set by key, or a batch conversion finishing, shows on screen but isn't spoken.
- The image in the viewer and in compare panes has no description; its name and details are in the info panel.
- The fly-out panels are hidden until opened, and VoiceOver can't reach a hidden one. The bottom control bar can only be opened with the pointer.
- Filmstrip frames and grid star ratings need a click; use the arrow keys and 0 to 5 instead.
- The magnifier needs a mouse button held down; / shows actual size instead.
- Selecting part of the text in a picture with Live Text needs a pointer. **Edit > Copy Text** (⇧⌘C) copies all of it from the keyboard.
- The video player's buttons and scrubber never take the keyboard focus, so Tab doesn't reach them; use Space, P and M, or VoiceOver, which can press them.
- Painting with **Clone Stamp…** and **Healing Brush…**, placing a red-eye circle by hand, drawing and resizing objects in **Text and Shapes…**, dragging the crop rectangle, moving the **Lens…** circle, dragging points in **Curves…**, and choosing an area with **Capture > Selection…** need a pointer.
- Arranging **Custom Order** needs dragging.
- Increase Contrast changes the grid's selection only.
