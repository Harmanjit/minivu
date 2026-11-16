# minivu – Punjabi (pa, Gurmukhi) glossary

Machine translation, needs review by a native speaker. Terminology aims to
follow Apple's Punjabi macOS/iOS UI where Apple ships it, and otherwise the
everyday Punjabi of mainstream software (Google, Mozilla, GNOME). Terms a
reviewer should check first against Apple's own Punjabi strings are marked
"check".

## Style

- Address: formal/polite "ਤੁਸੀਂ" with polite imperatives ending in -ਓ
  ("ਚੁਣੋ", "ਖੋਲ੍ਹੋ", "ਰੱਦੀ ਵਿੱਚ ਭੇਜੋ"), the Punjabi equivalent of Hindi
  "आप". Questions: "ਕੀ ਤੁਸੀਂ … ਚਾਹੁੰਦੇ ਹੋ?"; confirmations: "ਕੀ “%@” ਮਿਟਾਉਣਾ ਹੈ?".
- Register: plain modern Punjabi; common English loanwords stay as everyday
  Gurmukhi transliterations (ਫ਼ਾਈਲ, ਫ਼ੋਲਡਰ, ਪਿਕਸਲ, ਕੈਮਰਾ, ਜ਼ੂਮ, ਪ੍ਰੀਸੈੱਟ,
  ਮੈਟਾਡਾਟਾ). No heavy Sanskrit or Persian coinages.
- Nukta spellings as in current software Punjabi: ਫ਼, ਜ਼, ਖ਼ (ਫ਼ਾਈਲ, ਫ਼ੋਟੋ, ਜ਼ੂਮ).
- Word order is SOV; positional specifiers (%1$@, %2$lld) are used where the
  order changes ("%2$lld ਵਿੱਚੋਂ %1$lld" for "%lld of %lld").
- Menu commands and buttons: polite imperative ("ਸੰਭਾਲੋ", "ਕ੍ਰੌਪ ਕਰੋ…").
  Edit names (after "Undo") are nouns ("ਕ੍ਰੌਪ", "ਧੁੰਦਲਾ ਕਰਨਾ"), so
  "Undo %@" is "%@ ਵਾਪਸ ਕਰੋ". Progress: "… ਕੀਤਾ ਜਾ ਰਿਹਾ ਹੈ…".
- Sentences end with the danda "।". Ellipsis "…" (U+2026) with no space.
  Quotation marks “ ”; apostrophe-like "’ਤੇ" for "ਉੱਤੇ" in short forms.
- Digits stay Western (0–9), as Apple's Punjabi default. Unit symbols stay
  Latin (px, MP, fps, mm, Mbit/s, dpi); seconds are always written out as
  ਸਕਿੰਟ (“s”, “%lld s”), as hi, bn, gu and ta use a native form; other
  spelled-out units are Punjabi too (ਪਿਕਸਲ, ਪੌਇੰਟ).
- Key names stay as printed on the keyboard, in Latin: Return, Esc, Space,
  Tab, Home, End, Page Up/Page Down, Shift, Option ("Option-ਕਲਿੱਕ"); glyphs
  ⌘ ⇧ ⌥ ⌫ → ← kept. Arrow keys: "ਤੀਰ ਕੁੰਜੀਆਂ".
- Plurals: CLDR pa has `one` (n = 0..1) and `other`. Because `one` covers 0,
  every `one` form keeps the number. Many nouns don't change (ਚਿੱਤਰ, ਫ਼ੋਲਡਰ,
  ਸਟਾਰ, ਬਾਈਟ); feminine nouns take -ਆਂ (ਫ਼ਾਈਲ/ਫ਼ਾਈਲਾਂ, ਤਸਵੀਰ/ਤਸਵੀਰਾਂ,
  ਆਈਟਮ/ਆਈਟਮਾਂ) and the verb agrees (ਕੀਤੀ/ਕੀਤੀਆਂ ਗਈਆਂ).

## Menus

| English | Punjabi | Notes |
|---|---|---|
| File | ਫ਼ਾਈਲ | menu; `section.file` heading also ਫ਼ਾਈਲ |
| Edit | ਸੋਧੋ | check |
| View | ਵੇਖੋ | check |
| Go | ਜਾਓ | |
| Image | ਚਿੱਤਰ | |
| Tools | ਟੂਲ | |
| Window | ਵਿੰਡੋ | |
| Help | ਮਦਦ | |
| Settings… | ਸੈਟਿੰਗਾਂ… | |
| About minivu / Quit minivu / Hide minivu | minivu ਬਾਰੇ / minivu ਬੰਦ ਕਰੋ / minivu ਲੁਕਾਓ | |
| Hide Others / Bring All to Front | ਹੋਰਾਂ ਨੂੰ ਲੁਕਾਓ / ਸਭ ਨੂੰ ਅੱਗੇ ਲਿਆਓ | |
| Minimize / Zoom (window) | ਛੋਟਾ ਕਰੋ / ਜ਼ੂਮ | |
| Enter / Exit Full Screen | ਪੂਰੀ ਸਕ੍ਰੀਨ ਵਿੱਚ ਜਾਓ / ਪੂਰੀ ਸਕ੍ਰੀਨ ਤੋਂ ਬਾਹਰ ਜਾਓ | check |
| Services | ਸੇਵਾਵਾਂ | |

## Standard commands

| English | Punjabi |
|---|---|
| Open / Open Folder… | ਖੋਲ੍ਹੋ / ਫ਼ੋਲਡਰ ਖੋਲ੍ਹੋ… |
| Close Window | ਵਿੰਡੋ ਬੰਦ ਕਰੋ |
| Save / Save As… / Don’t Save | ਸੰਭਾਲੋ / ਇਸ ਵਜੋਂ ਸੰਭਾਲੋ… / ਨਾ ਸੰਭਾਲੋ |
| Revert to Saved | ਸੰਭਾਲੇ ਹੋਏ ’ਤੇ ਵਾਪਸ ਜਾਓ |
| Undo / Redo | ਵਾਪਸ ਕਰੋ / ਮੁੜ ਕਰੋ |
| Cut / Copy / Paste | ਕੱਟੋ / ਕਾਪੀ ਕਰੋ / ਪੇਸਟ ਕਰੋ |
| Select All / Invert Selection | ਸਭ ਚੁਣੋ / ਚੋਣ ਉਲਟਾਓ |
| Delete | ਮਿਟਾਓ |
| Duplicate | ਡੁਪਲੀਕੇਟ ਕਰੋ |
| Rename | ਨਾਮ ਬਦਲੋ |
| Move / Move To / Copy To | ਭੇਜੋ / ਇਸ ਵਿੱਚ ਭੇਜੋ / ਇਸ ਵਿੱਚ ਕਾਪੀ ਕਰੋ |
| New Folder / untitled folder | ਨਵਾਂ ਫ਼ੋਲਡਰ / ਬਿਨਾਂ ਨਾਮ ਦਾ ਫ਼ੋਲਡਰ |
| Trash | ਰੱਦੀ (check) |
| Move to Trash | ਰੱਦੀ ਵਿੱਚ ਭੇਜੋ |
| Put back (from Trash) | ਵਾਪਸ ਰੱਖੋ |
| Reveal in Finder | Finder ਵਿੱਚ ਦਿਖਾਓ |
| Share… | ਸਾਂਝਾ ਕਰੋ… |
| Print… / Page Setup… | ਪ੍ਰਿੰਟ ਕਰੋ… / ਪੰਨਾ ਸੈੱਟਅੱਪ… |
| Cancel / OK / Done | ਰੱਦ ਕਰੋ / ਠੀਕ ਹੈ / ਹੋ ਗਿਆ |
| Apply / Reset / Retry | ਲਾਗੂ ਕਰੋ / ਰੀਸੈੱਟ ਕਰੋ / ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ |
| Replace / Keep Both / Skip | ਬਦਲੋ / ਦੋਵੇਂ ਰੱਖੋ / ਛੱਡੋ (button only; Replace questions say “… ਦੀ ਥਾਂ ਨਵੀਂ … ਰੱਖਣੀ ਹੈ?”, because ਬਦਲਣਾ also means change) |
| save over the original | ਮੂਲ ਫ਼ਾਈਲ ਦੀ ਥਾਂ ਸੰਭਾਲੋ |
| Revert (alert button) | ਵਾਪਸ ਜਾਓ |
| Untitled / Untitled Collection | ਬਿਨਾਂ ਨਾਮ / ਬਿਨਾਂ ਨਾਮ ਦਾ ਸੰਗ੍ਰਹਿ |
| drag | ਘਸੀਟੋ / ਘਸੀਟਣਾ (never ਖਿੱਚ, which is “take a photo”) |
| Adjust / RAW Adjustments | ਅਡਜਸਟ / RAW ਅਡਜਸਟਮੈਂਟ |
| Orientation | ਓਰੀਐਂਟੇਸ਼ਨ |
| Strength / Magnification (lens) / Free (crop) | ਤੀਬਰਤਾ / ਜ਼ੂਮ / ਖੁੱਲ੍ਹਾ |
| embedded preview | ਫ਼ਾਈਲ ਵਿਚਲਾ ਪ੍ਰੀਵਿਊ |
| Spellings | ਮੈਮੋਰੀ, ਜਿਨ੍ਹਾਂ, ਖਾਲੀ |

## minivu terms

| English | Punjabi | Notes |
|---|---|---|
| browser | ਬ੍ਰਾਊਜ਼ਰ | folder list + thumbnail grid window |
| viewer | ਵਿਊਅਰ | |
| catalog / ratings database | ਕੈਟਾਲਾਗ / ਰੇਟਿੰਗ ਡਾਟਾਬੇਸ | |
| collection | ਸੰਗ੍ਰਹਿ | |
| smart folder | ਸਮਾਰਟ ਫ਼ੋਲਡਰ | |
| saved search | ਸੰਭਾਲੀ ਖੋਜ | |
| sidebar / Favorites | ਸਾਈਡਬਾਰ / ਮਨਪਸੰਦ | check Finder |
| preview pane | ਪ੍ਰੀਵਿਊ ਪੈਨ | |
| thumbnail | ਥੰਬਨੇਲ | |
| filmstrip | ਫ਼ਿਲਮਸਟ੍ਰਿਪ | |
| tag (minivu's pick mark) | ਟੈਗ; ਟੈਗ ਕਰੋ / ਟੈਗ ਹਟਾਓ; ਟੈਗ ਕੀਤਾ | |
| Finder tags | Finder ਟੈਗ | |
| rating / Rate N Stars | ਰੇਟਿੰਗ / %lld ਸਟਾਰ ਰੇਟਿੰਗ ਦਿਓ | |
| star | ਸਟਾਰ | |
| label / colour label | ਲੇਬਲ / ਰੰਗ ਲੇਬਲ | |
| Red, Orange, Yellow, Green, Blue, Purple, Gray | ਲਾਲ, ਸੰਤਰੀ, ਪੀਲਾ, ਹਰਾ, ਨੀਲਾ, ਜਾਮਣੀ, ਸਲੇਟੀ | |
| crop (verb / edit name) | ਕ੍ਰੌਪ ਕਰੋ / ਕ੍ਰੌਪ | |
| straighten | ਸਿੱਧਾ ਕਰੋ | |
| resize | ਆਕਾਰ ਬਦਲੋ | |
| rotate left / right | ਖੱਬੇ ਘੁਮਾਓ / ਸੱਜੇ ਘੁਮਾਓ | |
| flip horizontal / vertical | ਖਿਤਿਜੀ ਉਲਟਾਓ / ਲੰਬਕਾਰੀ ਉਲਟਾਓ | |
| batch convert | ਬੈਚ ਕਨਵਰਟ | |
| batch rename | ਬੈਚ ਵਿੱਚ ਨਾਮ ਬਦਲੋ | |
| slideshow / transition | ਸਲਾਈਡਸ਼ੋ / ਟ੍ਰਾਂਜ਼ੀਸ਼ਨ | |
| contact sheet | ਸੰਪਰਕ ਸ਼ੀਟ | |
| image strip | ਚਿੱਤਰ ਸਟ੍ਰਿਪ | |
| montage wallpaper | ਮੋਂਟਾਜ ਵਾਲਪੇਪਰ | |
| desktop picture | ਡੈਸਕਟਾਪ ਤਸਵੀਰ | |
| web gallery | ਵੈੱਬ ਗੈਲਰੀ | |
| watermark | ਵਾਟਰਮਾਰਕ | |
| preset | ਪ੍ਰੀਸੈੱਟ | |
| edits / edit (verb) | ਸੋਧਾਂ / ਸੋਧੋ | |
| image / picture / photo | ਚਿੱਤਰ / ਤਸਵੀਰ / ਫ਼ੋਟੋ | English distinction kept |
| Pictures folder | ਤਸਵੀਰਾਂ | check Finder's display name |
| Quick Look | Quick Look | Apple feature name, not in the current catalog |
| Live Text | ਲਾਈਵ ਟੈਕਸਟ | check |
| AirDrop, Messages, Mail | AirDrop, ਸੁਨੇਹੇ, ਮੇਲ | check |
| Reduce Motion | ਹਿਲਜੁਲ ਘਟਾਓ | check |
| Privacy & Security | ਪਰਦੇਦਾਰੀ ਅਤੇ ਸੁਰੱਖਿਆ | check |
| Screen & System Audio Recording | ਸਕ੍ਰੀਨ ਅਤੇ ਸਿਸਟਮ ਆਡੀਓ ਰਿਕਾਰਡਿੰਗ | check |
| System Settings | ਸਿਸਟਮ ਸੈਟਿੰਗਾਂ | |
| RAW / HDR / SDR | RAW / HDR / SDR | kept Latin |
| metadata / keyword(s) | ਮੈਟਾਡਾਟਾ / ਕੀਵਰਡ | |
| caption / title / creator / copyright | ਕੈਪਸ਼ਨ / ਸਿਰਲੇਖ / ਰਚਨਾਕਾਰ / ਕਾਪੀਰਾਈਟ | |
| location | ਟਿਕਾਣਾ | GPS position: GPS ਸਥਿਤੀ |
| date taken / modified / created | ਖਿੱਚਣ ਦੀ ਮਿਤੀ / ਸੋਧ ਦੀ ਮਿਤੀ / ਬਣਾਉਣ ਦੀ ਮਿਤੀ | |
| sidecar | ਸਾਈਡਕਾਰ | XMP ਸਾਈਡਕਾਰ |
| gain map / tone mapped | ਗੇਨ ਮੈਪ / ਟੋਨ ਮੈਪ ਕੀਤਾ | |
| magnifier | ਵਡਦਰਸ਼ੀ | |
| Levels / Curves | ਲੈਵਲ / ਕਰਵ | |
| Lighting / Colors | ਲਾਈਟਿੰਗ / ਰੰਗ | |
| Clone Stamp / Healing Brush | ਕਲੋਨ ਸਟੈਂਪ / ਹੀਲਿੰਗ ਬੁਰਸ਼ | |
| Red-Eye Removal | ਰੈੱਡ-ਆਈ ਹਟਾਉਣਾ | |
| Remove Background | ਬੈਕਗ੍ਰਾਊਂਡ ਹਟਾਓ | |
| Frame (effect) / frame (video) | ਚੌਖਟਾ / ਫ਼ਰੇਮ | |
| Text and Shapes | ਟੈਕਸਟ ਅਤੇ ਆਕਾਰ | |
| canvas / anchor | ਕੈਨਵਸ / ਐਂਕਰ | |
| Find Duplicates | ਡੁਪਲੀਕੇਟ ਲੱਭੋ | |
| Flat View | ਸਮਤਲ ਦ੍ਰਿਸ਼ | |
| external editor | ਬਾਹਰੀ ਐਡੀਟਰ | |
| Custom Order | ਕਸਟਮ ਕ੍ਰਮ | |
| Auto Enhance | ਆਟੋ ਸੁਧਾਰ | |
| Noise Reduction | ਨੌਇਜ਼ ਘਟਾਉਣਾ | |
| Vignette / Radius / Feather | ਵਿਨਯੈੱਟ / ਅਰਧ-ਵਿਆਸ / ਨਰਮ ਕਿਨਾਰਾ | |
| Mixed (differing values) | ਮਿਸ਼ਰਤ | |
| subject (of a photo) | ਵਿਸ਼ਾ | |
| Opacity / Saturation / Hue | ਅਪਾਰਦਰਸ਼ਤਾ / ਸੰਤ੍ਰਿਪਤਾ / ਰੰਗਤ | |
| font weights | ਲਾਈਟ, ਰੈਗੂਲਰ, ਮੀਡੀਅਮ, ਸੈਮੀਬੋਲਡ, ਬੋਲਡ, ਹੈਵੀ | |

## Left in English / Latin

minivu, format names (JPEG, HEIC, TIFF, PNG, AVIF…), names written to disk
(minivu Wallpapers, minivu Captures), rename tokens ({name}, {date}…),
compass letters N/S/E/W, unit symbols (px, MP, fps, mm, dpi, Mbit/s),
key names, Apple product names (Mac, Finder, Spotlight, Safari, MacBook Pro,
Pro Display XDR, Liquid Retina XDR, Display P3), US Letter.

## Notes for the reviewer

- `metadata.field.*` are slotted into "%@ ਵਾਲੀ ਤਬਦੀਲੀ ਲਾਗੂ ਨਹੀਂ ਹੋਈ…", so
  "location removal" is the oblique "ਟਿਕਾਣਾ ਹਟਾਉਣ".
- "%@ seconds", "%@ × %@ pixels" and similar keys put a formatted number
  before a noun and can't be plural keys; Punjabi ਸਕਿੰਟ/ਪਿਕਸਲ don't change
  form, so they read naturally for any number.
- "Replace %@ and %@?" takes the pieces "%lld ਮੂਲ ਫ਼ਾਈਲਾਂ" and "%lld
  ਫ਼ਾਈਲਾਂ"; its verb is feminine plural (ਰੱਖਣੀਆਂ), which fits both.
