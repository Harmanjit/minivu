# Languages

minivu is in English and ten other languages. It has no language setting of its own: it uses the language macOS gives it, so you choose it in System Settings, as for any Mac app.

## The languages

| Language | Shown in macOS as |
|---|---|
| English | English |
| German | Deutsch |
| French | Français |
| Spanish | Español |
| Italian | Italiano |
| Portuguese (Brazil) | Português (Brasil) |
| Dutch | Nederlands |
| Polish | Polski |
| Japanese | 日本語 |
| Chinese (Simplified) | 简体中文 |
| Korean | 한국어 |

## Machine translations, not yet reviewed

Every language other than English is a *machine translation*: a computer translated it, and no native speaker has checked it yet. Expect some odd wording, and in a few places a word that doesn't agree with the number beside it (Polish unit labels, for example). The menus, buttons and help pages are all there, so minivu is usable in each language, but the English text is the reference.

If a translation is wrong or unclear, please open an [issue](https://github.com/Harmanjit/minivu/issues/new/choose). Say the language, where the text appears (the menu, window or alert), what it says, and what it should say. Reviews by native speakers are welcome.

## Change minivu's language

To use one language in every app, put it at the top of **Preferred Languages** in **System Settings > General > Language & Region**. minivu shows the first language in that list that it has, and English when it has none of them.

To change minivu alone:

1. Quit minivu.
2. Open **System Settings > General > Language & Region**.
3. Scroll down to **Applications** and click **+**.
4. Choose **minivu** as the application.
5. Choose the language, then click **Add**.
6. Open minivu again.

To go back, select minivu in that list and click **−**. minivu then follows your preferred languages again.

To try a language for one launch only, quit minivu and run this in Terminal (here German, `de`; the others are `fr`, `es`, `it`, `pt-BR`, `nl`, `pl`, `ja`, `zh-Hans` and `ko`):

```bash
open /Applications/minivu.app --args -AppleLanguages '(de)'
```

## What changes with the language

- The menu bar, every window, sheet and alert, and **Settings**.
- **Help > minivu Help** (⌘?): the help pages are translated too. **Help > Keyboard Shortcuts** (⌘/) is built from the menus, so it follows them.
- The colour labels under **Image > Label**. The tag written to the file is Finder's own name for that colour in your system's language, the name Finder itself would write.
- The names and descriptions of minivu's actions in the Shortcuts app.
- Numbers, dates and units follow your region (**System Settings > General > Language & Region > Region**), so 1,5 or 1.5 is written as you expect.

Keyboard shortcuts never change: a translated command keeps its key.

## What stays in English

- **Names of files minivu writes**: the folders **minivu Captures** and **minivu Wallpapers** in Pictures, and the names of captures and montages. They stay the same in every language so that they sort and are recognised the same way.
- **Pages a web gallery writes** (**Tools > Create Web Gallery…**): words such as "Previous" and "Next" on the pages are English.
- **In the Shortcuts app**: the spoken phrases of minivu's ready-made shortcuts, and the one-line summary under each action.
- **A few technical details** inside error messages, such as a system error code, and messages that only appear in the system log.
- **This wiki.** The pages here are English only.

## When text doesn't fit

German, French and Polish text is often 30 to 40 percent longer than English. If a label is cut short or overlaps something, that is a bug: please report it as above, with a screenshot if you can.
