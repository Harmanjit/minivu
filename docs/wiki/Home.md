<p align="center"><img src="https://raw.githubusercontent.com/Harmanjit/minivu/main/Assets/minivu-icon.png" width="160" alt="minivu icon"></p>

# minivu

**A lightweight image browser, viewer and editor for Apple Silicon Macs, in the spirit of FastStone Image Viewer.**

minivu opens a folder of thousands of photos without a stutter, shows every image with correct colour and real HDR, and edits without touching the original until you save. It is built natively with Swift, AppKit and Metal, uses only Apple's frameworks, and has no network access of any kind.

- **Status:** version 0.9, a review release: every planned feature is implemented and covered by 1013 automated tests. Download it from [Releases](https://github.com/Harmanjit/minivu/releases), and report problems as [issues](https://github.com/Harmanjit/minivu/issues/new/choose). It is young software, tried in earnest on one Mac only, so read [Limitations](Limitations) before relying on it.
- **Licence:** GPLv3.
- **Platform:** macOS 15 (Sequoia) or newer on Apple Silicon. Developed and tested on an M1 Pro MacBook Pro.

The app has its own, shorter help: **Help > minivu Help** (⌘?) shows bundled pages with search, and **Help > Keyboard Shortcuts** (⌘/) lists every shortcut: those of the menus are read from the menu bar as the page opens, and the keys the grid, viewer and tools take directly are listed with them. Nothing is fetched from the network. These wiki pages are the fuller reference.

## Pages

| | |
|---|---|
| [Motivation](Motivation) | Why minivu exists, and what it deliberately leaves out |
| [Installation](Installation) | Requirements, building from source, the Gatekeeper dialog, updating and uninstalling |
| [Getting Started](Getting-Started) | First launch, opening a folder, the viewer, stars and tags, a first edit |
| [Browser](Browser) | The sidebar, the thumbnail grid and preview pane, sorting and filtering, stars and tags, file management |
| [Viewer](Viewer) | Zoom and pan, full screen and its panels, documents and animations, colour and HDR, two displays, Compare |
| [Editing](Editing) | The edit tools, effects and retouching, undo, Save and Save As |
| [Tools](Tools) | Slideshow, Batch Convert, Batch Rename, printing, contact sheets, montage wallpaper, capture, external editors |
| [Settings](Settings) | Every pane of Settings and what it changes |
| [Keyboard Shortcuts](Keyboard-Shortcuts) | The full list |
| [Architecture](Architecture) | Modules, the decode and render paths, performance, tests |
| [Security and Privacy](Security-and-Privacy) | Sandbox, no network, what minivu reads and writes, and where |
| [Accessibility](Accessibility) | VoiceOver, Reduce Motion, Increase Contrast |
| [Limitations](Limitations) | What it does not do, honestly |
| [Troubleshooting](Troubleshooting) | The problems people hit first |
