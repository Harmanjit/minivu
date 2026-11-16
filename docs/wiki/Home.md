<p align="center"><img src="https://raw.githubusercontent.com/Harmanjit/minivu/main/Assets/minivu-icon.png" width="160" alt="minivu icon"></p>

# minivu

**A lightweight image browser, viewer and editor for Apple Silicon Macs, in the spirit of FastStone Image Viewer.**

minivu opens a folder of thousands of photos without a stutter, shows every image with correct colour and real HDR, plays the videos among them, and edits without touching the original until you save. It is built natively with Swift, AppKit and Metal, uses only Apple's frameworks, and has no network access of any kind. It speaks English and ten other languages.

- **Status:** version 0.9, a review release: every planned feature is implemented and covered by over 1,500 automated tests. Download it from [Releases](https://github.com/Harmanjit/minivu/releases), and report problems as [issues](https://github.com/Harmanjit/minivu/issues/new/choose). It is young software, tried in earnest on one Mac only, so read [Limitations](Limitations) before relying on it.
- **Licence:** GPLv3.
- **Platform:** macOS 15 (Sequoia) or newer on Apple Silicon. Developed and tested on an M1 Pro MacBook Pro.

The app has its own, shorter help: **Help > minivu Help** (⌘?) shows bundled pages with search, in minivu's language, and **Help > Keyboard Shortcuts** (⌘/) lists every shortcut: those of the menus are read from the menu bar as the page opens, and the keys the grid, viewer and tools take directly are listed with them. Nothing is fetched from the network. These wiki pages, in English, are the fuller reference.

## Pages

| | |
|---|---|
| [Motivation](Motivation) | Why minivu exists, and what it deliberately leaves out |
| [Installation](Installation) | Requirements, building from source, the Gatekeeper dialog, updating and uninstalling |
| [Getting Started](Getting-Started) | First launch, opening a folder, the viewer, stars and tags, a first edit |
| [Browser](Browser) | The sidebar, the thumbnail grid and preview pane, sorting and filtering, Flat View and Find, collections and smart folders, stars, tags and labels, file management |
| [Viewer](Viewer) | Zoom and pan, full screen and its panels, documents, animations and videos, Live Text, colour and HDR, two displays, Compare |
| [Editing](Editing) | The edit tools, effects and retouching, RAW adjustments, metadata, undo, Save and Save As |
| [Tools](Tools) | Slideshow and slideshow video, Batch Convert and presets, Batch Rename, multi-page files, Find Duplicates, printing, contact sheets, web galleries, montage wallpaper, capture, sharing, external editors, Shortcuts actions |
| [Settings](Settings) | Every pane of Settings and what it changes |
| [Keyboard Shortcuts](Keyboard-Shortcuts) | The full list |
| [Languages](Languages) | The eleven languages, machine translation, and how to choose minivu's language |
| [Architecture](Architecture) | Modules, the decode and render paths, the catalog, localisation, Shortcuts actions, measuring, tests |
| [Security and Privacy](Security-and-Privacy) | Sandbox, no network, crafted files, location, Shortcuts, what minivu reads and writes, and where |
| [Accessibility](Accessibility) | Keyboard use, VoiceOver, Reduce Motion, Increase Contrast |
| [Limitations](Limitations) | What it does not do, honestly |
| [Troubleshooting](Troubleshooting) | The problems people hit first |
