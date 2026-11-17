# minivu Tamil (ta) glossary

Follows the terms of Apple's macOS in Tamil (Finder, Photos, Preview) where
they could be found. Everything is a machine translation and needs review by
a native Tamil speaker. The Tamil words below are the ones the catalog and
the help pages use; the notes say why.

## Writing rules

- Respectful plural (“நீங்கள்”): verbs in sentences take the “-ங்கள்” form
  (தேர்ந்தெடுங்கள், கிளிக் செய்யுங்கள்). Menu items and buttons use the short
  imperative, as Apple does (திற, சேமி, நகலெடு, குப்பைக்கு நகர்த்து). Questions
  end in “-வா?” (நீக்கவா?, “…-க்குப் பதிலாகப் புதிய ஃபைலை வைக்கவா?”).
- Style: present-day software Tamil; literary and heavily Sanskritised words
  are avoided. Everyday English loanwords are written in Tamil script: ஃபைல்,
  ஃபோல்டர், பிக்சல், கேமரா, வீடியோ, டிஸ்பிளே, மெட்டாடேட்டா, ஸ்லைடுஷோ, பூஸ்ட்.
- Case endings after Latin letters, symbols or quotation marks take a hyphen:
  “%@”-ஐ, minivu-இல், %@-க்கு, Finder-இல், 100%-க்கு, %@-ஆக, SDR-ஆக.
- Word order is SOV, with positional specifiers where needed (%1$@, %2$lld).
  “X of Y” is “%2$lld-இல் %1$lld”; progress text “… %2$lld-இல் %1$lld”. When
  the first number may be 1, it takes no noun (“%2$lld ஃபைல்களில்
  %1$lld-இன் பெயர்…”), so “1 ஃபைல்களின்” can't happen.
- Quotation marks “ ” (as Apple). Menu paths: ஃபைல் > ஃபோல்டரைத் திற….
  Ellipsis “…” (U+2026) kept.
- Key names are lowercase English, as printed on the Mac keyboard (return,
  esc, space, tab, home, end, page up/down, shift, option, control), also in
  the help (“option-கிளிக்”, “control-கிளிக்”); glyphs (⌘ ⌥ ⇧ ⌫ → ←) and
  letter keys (P, T, F) unchanged.
- Plurals: CLDR `one` (exactly 1) and `other`. The `one` form keeps the
  number too (%lld படம் / %lld படங்கள்). One exception: “The pattern has an
  unknown token”, whose `one` form is “டோக்கன் ஒன்று” without the number.
- Units: px, MP, fps, Mbit/s, pt, dpi in Latin; மீ (metre), மி.மீ.
  (millimetre), வி. (second), நிமி. (minute), ம.நே. (hour) in Tamil.

## Replace and overwrite

மாற்றியமை is the label of the Replace button only. In a sentence it reads
as “modify, edit”, so a sentence or question about replacing a file never
uses it:

- Replace questions: “…-க்குப் பதிலாகப் புதிய ஃபைலை வைக்கவா?” (put the new
  file in place of …), also for the copy and move conflict (“நீங்கள்
  நகலெடுக்கும் உருப்படியை அதற்குப் பதிலாக வைக்கவா?”).
- Replace in statements and errors: “X-க்குப் பதிலாக Y-ஐ வை” (“%@-க்குப் பதிலாக
  ஒரு ஃபோல்டரை வைக்க முடியாது”).
- Save over / overwrite a file: “… மேல் சேமி” / “… மேல் எழுது” (“அசலின் மேல்
  சேமிக்கும் முன் கேள்”); a permanent overwrite in help is “நிரந்தரமாக
  மேலெழுதும்”.
- Sentences with convert (மாற்று) never use மாற்றியமை either: “அசலுக்குப்
  பதிலாக மாற்றப்பட்ட ஃபைலை வைக்கவா?”. The replaced file is “பழைய ஃபைல்”.
- Put பதிலாக (instead) after the thing being replaced, never after a
  “-க்கும் … -க்கும்” list, where it reads as “instead of these files”: “RAW
  ஃபைல்களுக்கும் … வடிவமைப்புகளுக்கும், அதற்குப் பதிலாக … XMP சைட்கார்”.

## Terms

| English | Tamil | Note |
|---|---|---|
| browser | உலாவி | the window with the folder list and the thumbnail grid |
| viewer | பார்வையி | the window that shows one image |
| catalog | கேட்டலாக் | the database of ratings, tags and custom order |
| ratings database | மதிப்பீட்டுத் தரவுத்தளம் | |
| collection | தொகுப்பு | |
| smart folder | ஸ்மார்ட் ஃபோல்டர் | as in Finder |
| saved search | சேமித்த தேடல் | |
| sidebar | பக்கப்பட்டி | |
| Favorites | பிடித்தவை | Finder sidebar heading |
| preview pane | முன்னோட்டப் பலகம் | |
| thumbnail | சிறுபடம் | |
| filmstrip | ஃபிலிம்ஸ்ட்ரிப் | |
| tag (minivu's pick mark) | டேக் | verb: டேக் செய் / டேக்கை நீக்கு; tagged: டேக் செய்யப்பட்டது |
| orientation tag (EXIF) | திசையமைவு மதிப்பு (EXIF) | never டேக், which is minivu's pick mark |
| Compare (window, noun) | ஒப்பீடு | the command stays ஒப்பிடு |
| Finder tags | Finder குறிச்சொற்கள் | kept apart from minivu's tag |
| rating / Rate N Stars | மதிப்பீடு / %lld நட்சத்திர மதிப்பீடு கொடு | |
| star | நட்சத்திரம் | |
| label / colour label | லேபிள் / வண்ண லேபிள் | |
| Red, Orange, Yellow, Green, Blue, Purple, Gray | சிவப்பு, ஆரஞ்சு, மஞ்சள், பச்சை, நீலம், ஊதா, சாம்பல் | |
| crop (verb / edit name) | செதுக்கு / செதுக்கல் | as in Photos |
| straighten | நேராக்கு | |
| resize | அளவை மாற்று | |
| rotate left / right | இடப்புறம் சுழற்று / வலப்புறம் சுழற்று | |
| flip horizontal / vertical | கிடைமட்டமாகப் புரட்டு / செங்குத்தாகப் புரட்டு | |
| batch convert | மொத்தமாக மாற்று (noun: மொத்தமாக மாற்றுதல்) | |
| Replace (button) / replace (in sentences) | மாற்றியமை / “X-க்குப் பதிலாக Y-ஐ வை” | see “Replace and overwrite” above |
| save over, overwrite | … மேல் சேமி / மேலெழுது | see “Replace and overwrite” above |
| deselect / delete the selection | தேர்வை விலக்கு / தேர்ந்தெடுத்தவற்றை நீக்கு | |
| Copy To / Move To (submenu) | ஃபோல்டருக்கு நகலெடு / ஃபோல்டருக்கு நகர்த்து | not “இங்கே” |
| Retouch / Effects & Retouching | ரீடச் / எஃபெக்ட்களும் ரீடச்சும் | சீரமை = align |
| Capture (submenu) | திரைப் பிடிப்பு | |
| Remove Tag | டேக்கை நீக்கு | |
| Aperture | துளை (அபர்ச்சர்) / அபர்ச்சர் | |
| Animated GIF / Animated HEIC | அனிமேஷன் GIF / அனிமேஷன் HEIC | |
| Theme / appearance: Bright, Light, Dark | ஒளிர்வான, ஒளிர்வான, இருண்ட | Bright is the app theme, Light the web gallery look; they never appear in the same place |
| Light (font weight) / Light (Bump Map section) | மெல்லிய / ஒளி | |
| hidden files / cache | மறைக்கப்பட்ட ஃபைல்கள் / தற்காலிகச் சேமிப்பு | |
| Drop Shadow | விழும் நிழல் | Shadows (Levels) = நிழல்கள் |
| standard (dynamic range, print panel) | நிலையான | not “தர” (that is quality) |
| range “to” (between two fields) / rename “with” (find → replace) | – / → | symbols, as in ja and ko; the reviewer should check they read naturally |
| find and replace (Batch Rename) / replacement text | கண்டறிந்து மாற்றுதல் / மாற்று உரை | not மாற்றியமைத்தல் |
| batch rename | மொத்தமாகப் பெயர்மாற்று | |
| rename | பெயர்மாற்று | not “பெயரை மாற்று”: “படங்களைப் பெயர்மாற்று”, “முன்னமைவைப் பெயர்மாற்று” |
| sheet (dialog attached to a window) | தாள் | as in the UI (“இந்தத் தாளை அப்படியே சேமியுங்கள்”); not the transliteration ஷீட் |
| slideshow | ஸ்லைடுஷோ | |
| transition | மாற்றம் / மாற்ற விளைவு | |
| contact sheet | தொடர்புத் தாள் | |
| image strip | படப் பட்டை | |
| montage wallpaper | மாண்டேஜ் வால்பேப்பர் | |
| desktop picture | டெஸ்க்டாப் படம் | |
| web gallery | வலைக் கேலரி | |
| watermark | நீர்க்குறி | |
| preset | முன்னமைவு | |
| edits | திருத்தங்கள் | |
| image / picture / photo | படம் / படம் / புகைப்படம் | |
| Pictures folder | Pictures | the folder's name on disk, not translated |
| file / folder | ஃபைல் / ஃபோல்டர் | |
| item | உருப்படி | |
| window | சாளரம் | |
| Trash | குப்பை | |
| Move to Trash | குப்பைக்கு நகர்த்து | |
| Put Back | திரும்ப வை | |
| Reveal in Finder | Finder-இல் காட்டு | |
| Share… | பகிர்… | |
| Page Setup… | பக்க அமைவு… | |
| Print… | அச்சிடு… | |
| Save / Save As… / Don’t Save | சேமி / இவ்வாறு சேமி… / சேமிக்க வேண்டாம் | |
| Revert to Saved | சேமித்ததற்கு மீட்டமை | |
| Undo / Redo | செயல்தவிர் / மீண்டும் செய் | “Undo %@” → “செயல்தவிர்: %@”, “Redo %@” → “மீண்டும் செய்: %@”, HUD “திருத்தப்பட்டது  ·  செயல்தவிர்: %@” (a case ending on %@ breaks with imperative or consonant-final names); the MinivuRender edit names (“Name of an edit”) are verbal nouns: சுழற்றல், இடப்புறச் சுழற்றல், அளவு மாற்றம், கிடைமட்டப் புரட்டல், கூர்மையாக்கல், பின்னணி நீக்கம்; the Minivu menu commands of the same names stay imperatives |
| Cut / Copy / Paste / Select All | வெட்டு / நகலெடு / ஒட்டு / அனைத்தையும் தேர்ந்தெடு | |
| Duplicate | நகலாக்கு | |
| Settings… | அமைப்புகள்… | |
| Quit minivu / Hide minivu / Hide Others | minivu-இலிருந்து வெளியேறு / minivu-ஐ மறை / பிறவற்றை மறை | |
| Minimize / Zoom (window) / Bring All to Front | மினிமைஸ் செய் / ஜூம் / அனைத்தையும் முன்னால் கொண்டுவா | |
| Enter / Exit Full Screen | முழுத்திரைக்குச் செல் / முழுத்திரையிலிருந்து வெளியேறு | |
| Zoom In / Zoom Out / Actual Size / Fit to Window | பெரிதாக்கு / சிறிதாக்கு / உண்மையான அளவு / சாளரத்துக்குப் பொருத்து | zoom in and out together: பெரிதாக்கு/சிறிதாக்கு |
| zoom (noun) / magnification | பெரிதாக்கல் / உருப்பெருக்கம் | |
| menus File, Edit, View, Go, Image, Tools, Window, Help | ஃபைல், திருத்து, காட்சி, செல், படம், கருவிகள், சாளரம், உதவி | |
| Quick Look | Quick Look | not in the current catalog |
| Live Text | நேரடி உரை | |
| Services | சேவைகள் | |
| AirDrop, Messages, Mail | AirDrop, Messages, Mail | Apple names |
| Reduce Motion | இயக்கத்தைக் குறை | |
| Screen & System Audio Recording | திரை & சிஸ்டம் ஆடியோ பதிவு | |
| Privacy & Security | தனியுரிமை & பாதுகாப்பு | |
| System Settings | சிஸ்டம் அமைப்புகள் | |
| metadata / keywords / caption / title / creator / copyright | மெட்டாடேட்டா / முக்கியச்சொற்கள் / தலைப்புக்குறிப்பு / தலைப்பு / உருவாக்கியவர் / பதிப்புரிமை | |
| location | இருப்பிடம் | |
| date taken / date modified / date created | எடுத்த தேதி / மாற்றிய தேதி / உருவாக்கிய தேதி | |
| sidecar | சைட்கார் | XMP சைட்கார் |
| gain map / tone mapped | கெயின் மேப் / டோன் மேப் செய்யப்பட்ட | |
| highlights / shadows | ஹைலைட்கள் / நிழல்கள் | |
| Boost (RAW) | பூஸ்ட் | the amount of the camera's contrast curve; not ஊக்கம் (“encouragement”) |
| magnifier | உருப்பெருக்கி | |
| Levels / Curves | நிலைகள் / வளைவுகள் | |
| Lighting / Colors | ஒளியமைப்பு / வண்ணங்கள் | |
| Clone Stamp / Healing Brush | குளோன் ஸ்டாம்ப் / குணப்படுத்தும் தூரிகை | |
| Red-Eye Removal | சிவப்புக் கண் நீக்கம் | |
| Remove Background | பின்னணியை அகற்று | |
| Frame (effect) / frame (video, animation) | சட்டகம் / ஃபிரேம் | |
| Text and Shapes | உரையும் வடிவங்களும் | |
| Stroke (shape) / Outline (text) / Fill | வெளிக்கோடு / வெளிக்கோடு / நிரப்பு | Stroke and Outline never share a panel (shapes show Stroke, text shows Outline) |
| canvas / anchor | கேன்வாஸ் / நங்கூரம் | |
| Forever (animation loop) | முடிவின்றி | not எப்போதும் (“always”) |
| min / max (range placeholders) | குறைந்தபட்சம் / அதிகபட்சம் | |
| “… and N more” | இன்னும் %lld | the same wording for “%lld more” and “…and %lld more.” |
| Find Duplicates | நகல்களைக் கண்டறி | |
| Flat View | தட்டைக் காட்சி | |
| external editor | வெளிப்புற எடிட்டர் | |
| Custom Order | தனிப்பயன் வரிசை | |
| More Filters… | மேலும் வடிகட்டிகள்… | |
| Show All (filter) | அனைத்தையும் காட்டு | |
| Select Tagged / Invert Selection | டேக் செய்தவற்றைத் தேர்ந்தெடு / தேர்வைத் தலைகீழாக்கு | |
| Find… | கண்டறி… | |
| Canvas Size… | கேன்வாஸ் அளவு… | |
| Perspective… | தோற்றக் கோணம்… | |
| RAW Adjustments… | RAW சரிசெய்தல்கள்… | |
| Auto Enhance | தானியங்கு மேம்பாடு | |
| Noise Reduction… | இரைச்சல் குறைப்பு… | |
| Vignette… / Radius / Feather | விக்னெட்… / ஆரம் / மென்விளிம்பு | |
| Mixed (differing values) | கலப்பு | |
| GPS position / place names | GPS நிலை / இடப் பெயர்கள் | |
| Copy Subject / Copy Text / Copy Frame | பொருளை நகலெடு / உரையை நகலெடு / ஃபிரேமை நகலெடு | |
| subject (of a photo) | பொருள் | |
| Export Slideshow Video… | ஸ்லைடுஷோ வீடியோவை ஏற்றுமதி செய்… | |
| Extract Pages… / Create Multi-Page File… | பக்கங்களைப் பிரித்தெடு… / பல பக்க ஃபைலை உருவாக்கு… | |
| Identical Files / Similar Images / Similarity | ஒரே மாதிரியான ஃபைல்கள் / ஒத்த படங்கள் / ஒற்றுமை | |
| Mark Suggested | பரிந்துரைத்தவற்றைக் குறி | |
| Count Colors | வண்ணங்களை எண்ணு | |
| codec / frame rate / data rate | கோடெக் / ஃபிரேம் வீதம் / தரவு வீதம் | |
| mute / unmute | முடக்கு / ஒலியை இயக்கு | |
| pattern / token / counter | பேட்டர்ன் / டோக்கன் / எண்ணி | Batch Rename |
| app | ஆப் (plural: ஆப்ஸ்) | |

## Left in English

minivu; format names (JPEG, HEIC, TIFF, GIF…); RAW, HDR, SDR, GPS, ISO,
DPI, XMP, IPTC, EXIF; Apple product and feature names (Mac, Finder,
Spotlight, Safari, AirDrop, Messages, Mail, Liquid Retina XDR, Pro Display
XDR, Display P3); names written to disk (Pictures › minivu Wallpapers);
pattern tokens ({name} and the others); the EXIF compass letters N/S/E/W;
unit symbols (px, MP, fps, Mbit/s, kbit/s, pt, dpi).
