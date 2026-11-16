# Wiki source

These pages are the GitHub wiki for minivu, kept here so they are versioned
with the code. This README is publishing notes, not a page, and is left out
when publishing.

To publish or update the wiki:

1. Once only: on GitHub, turn on the wiki (the repository's **Settings >
   General > Features > Wikis**), open the Wiki tab and create any first
   page. That creates the wiki repository.
2. Then, from the root of the repository:

```bash
git clone git@github.com:Harmanjit/minivu.wiki.git /tmp/minivu-wiki
cp docs/wiki/*.md /tmp/minivu-wiki/ && rm /tmp/minivu-wiki/README.md
cd /tmp/minivu-wiki && git add -A && git commit -m "Update wiki" && git push
```

A page deleted here is not deleted from the wiki by this copy; remove it in
the clone with `git rm` before committing.

## Rules for the pages

- The file name is the page name: `Getting-Started.md` is the page
  Getting Started.
- `_Sidebar.md` sets the order of the sidebar on GitHub. Add every new page
  to it, and to the Pages table on `Home.md`.
- Link between pages with bare page names, `[Viewer](Viewer)` or
  `[Keyboard Shortcuts](Keyboard-Shortcuts)`, with no `.md`. To link to a
  heading, add an *anchor*: the heading in lower case, with spaces turned
  into hyphens and punctuation dropped, as in `[Videos](#videos)` on the
  same page or `[Collections](Browser#collections)` on another. If you
  rename a heading, search the wiki for its old anchor.
- Link to files in the repository with full URLs,
  `https://github.com/Harmanjit/minivu/blob/main/DESIGN.md`, never relative
  paths: the wiki is a separate repository.
- Check every menu name, shortcut, setting, default and number against the
  code before writing it. `Sources/Minivu/App/MainMenu.swift` has the menus
  and their shortcuts, `Sources/Minivu/Help/KeyboardShortcutsPage.swift` the
  keys views take directly, `Sources/Minivu/App/PreferencesWindowController.swift`
  and `Sources/Minivu/Common/Preferences.swift` the Settings panes and
  their defaults, `Sources/Minivu/Automation/AutomationIntents.swift` the
  Shortcuts actions, and `DESIGN.md` the spec and its known limits.
  `docs/feature-notes/` has the notes each feature branch left, with what
  the user can do and its limits.
- The wiki is in English only. Use the English names of menus and
  commands; [Languages](Languages) says so for readers.

## The in-app help is separate

**Help > minivu Help** does not show these pages. It shows its own, shorter
set in `Sources/Minivu/Help/HelpPages/*.md`, bundled into the app by
`scripts/make_app.sh`:

- The pages, their order and their titles are the `HelpPage` enum in
  `Sources/Minivu/Help/HelpContent.swift`. Each page starts with a level-one
  heading equal to its title.
- They link to each other as `help:Browser`; the Help window refuses any
  other link.
- They are translated: each shipped language has a folder of its own,
  `HelpPages/<lang>/` (`de`, `pt-BR`, `zh-Hans`…), with the same files. A
  page missing in a language falls back to English. A change to an English
  page leaves the translations behind until they are updated too;
  `swift test --filter LocalizationTests` checks that every language has
  every page and that each starts with its translated title.
- The Keyboard Shortcuts page there has no Markdown file. Its menu
  shortcuts are read from the menu bar at runtime, so they can't fall
  behind the menus; the keys views take directly are listed in
  `Sources/Minivu/Help/KeyboardShortcutsPage.swift`, and HelpTests checks
  them against the key tables. `Keyboard-Shortcuts.md` in this folder is
  not generated, so keep it in step with `MainMenu.swift` and those tables.
- `swift test --filter HelpTests` checks that every help page loads, starts
  with its title, and links only to pages that exist.

When behaviour changes, update both: the help page that describes it and
the wiki page. Rebuild the app with `scripts/make_app.sh` to see help
changes in the bundle.
