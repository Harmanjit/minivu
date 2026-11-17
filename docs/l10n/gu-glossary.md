# minivu Gujarati (gu) glossary

Tries to follow the terms of macOS in Gujarati (Finder, Photos, Preview).
Where Apple's exact word couldn't be checked, the word common in Gujarati
software was taken. Every translation is a machine translation and needs
review by a native Gujarati speaker; the last section lists what to check
first.

## Writing rules

- Address: “તમે” (respectful, as Apple's Gujarati, but not “આપ”). Commands in
  the plural respectful form: “ખોલો”, “પસંદ કરો”, “સાચવો”.
- Menu items and buttons: the short verb form (“ક્રૉપ કરો…”, “ટ્રેશમાં
  ખસેડો”). Edit names (the ones after “Undo”) are always nouns or verbal
  nouns, never bare stems: “ક્રૉપ કરવું”, “કદ બદલવું”, “ડાબે ફેરવવું”, “આડું
  ફ્લિપ કરવું”, so the Undo menu reads “આડું ફ્લિપ કરવું પૂર્વવત્ કરો” like its
  neighbours. “Undo %@” = “%@ પૂર્વવત્ કરો”.
- Settings checkboxes describe a behaviour, not a command to perform: “ફોલ્ડરના
  અંતે ફરી શરૂઆતથી બતાવો” (Wrap around at end of folder).
- Confirmation questions: “…ખસેડીએ?”, “…બદલીએ?”, “…ડિલીટ કરીએ?” (Apple's
  “Move to Trash?” style).
- Error messages: “… શકાયું નથી.” / “… શકાતું નથી.”, with a complete
  passive where a cause follows (“પરવાનગી નકારવામાં આવી”).
- Progress lines are passive, with no implied subject: ““%@” સચવાઈ રહ્યું
  છે…”, “રદ થઈ રહ્યું છે…”, “નામ તપાસાઈ રહ્યાં છે…”, “શોધ ચાલી રહી છે…”.
- Postpositions (માં, નું, થી, ને) attach to the word or placeholder:
  “Finderમાં”, ““%@”માં”, “%@ માટે”.
- Digits stay Latin (0–9); the system formats numbers. Unit abbreviations:
  સે (second), મિ (minute), ક (hour); px, MP, fps, Mbit/s, pt, mm, dpi in
  Latin.
- Quotation marks “ ” (as Apple). In the help a command or option named
  inside a sentence is bold or in “ ”, never bare, so two command names don't
  run together (“તેમના માટે “સાચવો” પસંદ કરવાથી “આ રૂપે સાચવો” ખૂલે છે”). Menu
  paths: ફાઇલ > ફોલ્ડર ખોલો…. Ellipsis “…” (U+2026) kept.
- Key names in English, as on the keyboard: Return, Esc, Space, Tab, Home,
  End, Page Up/Down, Shift, Option-ક્લિક. Glyphs (⌘ ⌥ ⇧ ⌫ → ←) unchanged. This
  is deliberate (as in ko), so those strings match English.
- Word order is SOV, so many strings use positional specifiers (%1$lld,
  %2$@), for example “%2$lld માંથી %1$lld”.
- Plurals: CLDR `one` and `other` for gu. `one` covers both 0 and 1, so every
  `one` form keeps the number. A Gujarati noun after a number often stays
  singular (“5 ઇમેજ”, “3 પેજ”); the plural is used in forms such as
  “ફાઇલ/ફાઇલો”, “ચિત્ર/ચિત્રો”, “રંગ/રંગો”.
- The letter-case options are explained in Gujarati with a Latin example in
  brackets (as in hi, pa, bn and ta): “મોટા અક્ષર (UPPERCASE)”, “નાના અક્ષર
  (lowercase)”, “દરેક શબ્દનો પહેલો અક્ષર મોટો (Title Case)”.

## Terms

| English | Gujarati | Note |
|---|---|---|
| browser | બ્રાઉઝર | the window with the folder list and the thumbnail grid |
| viewer | વ્યૂઅર | |
| catalog / ratings database | કૅટલૉગ / રેટિંગ ડેટાબેઝ | |
| collection | કલેક્શન | |
| smart folder | સ્માર્ટ ફોલ્ડર | as in Finder |
| saved search | સાચવેલી શોધ | |
| sidebar | સાઇડબાર | |
| Favorites | મનપસંદ | Finder sidebar heading |
| preview pane | પ્રિવ્યૂ પેન | |
| thumbnail | થંબનેલ | |
| filmstrip | ફિલ્મસ્ટ્રિપ | |
| tag (minivu's mark) | ટૅગ | verb: ટૅગ કરો / ટૅગ દૂર કરો; adjective: ટૅગ કરેલી |
| Finder tags | Finder ટૅગ | |
| rating / Rate N Stars | રેટિંગ / %lld સ્ટાર રેટિંગ આપો | |
| star | સ્ટાર | |
| label / colour label | લેબલ / કલર લેબલ | |
| Red, Orange, Yellow, Green, Blue, Purple, Gray | લાલ, નારંગી, પીળો, લીલો, વાદળી, જાંબલી, ગ્રે | Finder tag colours |
| crop | ક્રૉપ કરો / ક્રૉપ કરવું (edit name) | |
| straighten | સીધું કરો | |
| resize | કદ બદલો | edit name: કદ બદલવું |
| rotate left / right | ડાબે ફેરવો / જમણે ફેરવો | |
| flip horizontal / vertical | આડું ફ્લિપ કરો / ઊભું ફ્લિપ કરો | edit names: આડું ફ્લિપ કરવું / ઊભું ફ્લિપ કરવું |
| batch convert | બૅચ કન્વર્ટ | |
| batch rename | બૅચ નામ બદલો | |
| rename | નામ બદલો | |
| slideshow | સ્લાઇડશો | |
| transition | ટ્રાન્ઝિશન | |
| contact sheet | કૉન્ટેક્ટ શીટ | |
| image strip | ઇમેજ સ્ટ્રિપ | |
| montage wallpaper | મોન્ટાજ વૉલપેપર | |
| desktop picture | ડેસ્કટૉપ ચિત્ર | |
| web gallery | વેબ ગૅલરી | |
| watermark | વૉટરમાર્ક | |
| preset | પ્રીસેટ | |
| edits | સંપાદનો | |
| image / picture / photo | ઇમેજ / ચિત્ર / ફોટો | keeps the source's distinctions |
| Pictures folder | Pictures | Finder's display name; Latin in paths |
| Trash | ટ્રેશ | |
| Move to Trash | ટ્રેશમાં ખસેડો | |
| Put Back | પાછું મૂકો | |
| Reveal in Finder | Finderમાં બતાવો | |
| Open / Open With | ખોલો / આ વડે ખોલો | |
| Share… | શેર કરો… | |
| Page Setup… / Print… | પેજ સેટઅપ… / પ્રિન્ટ કરો… | |
| Save / Save As… / Don’t Save | સાચવો / આ રૂપે સાચવો… / સાચવશો નહીં | |
| Revert to Saved | સાચવેલા પર પાછું લાવો | |
| Undo / Redo | પૂર્વવત્ કરો / ફરી કરો | |
| Getting Started (help topic) | શરૂઆત | a noun, like the other topic titles |
| Strength / Free (crop) / aspect ratio | તીવ્રતા / મુક્ત આકાર / પાસા ગુણોત્તર | |
| Hardness (brush) | કઠોરતા | |
| Low / Medium / High (video quality) | નીચી / મધ્યમ / ઊંચી | a matching pair, not નીચી / ઉચ્ચ |
| deep / wide (frame border) | પહોળો | a border is wide, not deep (ઊંડો) |
| Use as Quick Action / Quick Actions | ઝડપી ક્રિયા તરીકે વાપરો / ઝડપી ક્રિયાઓ | the reviewer should check the Gujarati labels of macOS Shortcuts and Finder, and the Shortcuts app's Gujarati name |
| Cut / Copy / Paste / Select All | કાપો / કૉપિ કરો / પેસ્ટ કરો / બધું પસંદ કરો | |
| Duplicate | ડુપ્લિકેટ કરો | |
| Delete | ડિલીટ કરો | |
| Settings… | સેટિંગ્સ… | |
| Quit minivu / Hide minivu / Hide Others | minivuમાંથી બહાર નીકળો / minivu છુપાવો / અન્યને છુપાવો | |
| Minimize / Zoom (window) / Bring All to Front | નાનું કરો / ઝૂમ / બધું આગળ લાવો | |
| Enter / Exit Full Screen | પૂર્ણ સ્ક્રીનમાં જાઓ / પૂર્ણ સ્ક્રીનમાંથી બહાર નીકળો | |
| Zoom In / Zoom Out / Actual Size / Fit to Window | ઝૂમ ઇન કરો / ઝૂમ આઉટ કરો / વાસ્તવિક કદ / વિન્ડોમાં ફિટ કરો | |
| menus File / Edit / View / Go / Image / Tools / Window / Help | ફાઇલ / સંપાદિત કરો / જુઓ / જાઓ / ઇમેજ / ટૂલ્સ / વિન્ડો / મદદ | |
| window / folder / file | વિન્ડો / ફોલ્ડર / ફાઇલ | |
| Quick Look | ક્વિક લુક | not used in the current catalog |
| Live Text | લાઇવ ટેક્સ્ટ | |
| Services | સેવાઓ | |
| AirDrop, Messages, Mail | AirDrop, Messages, Mail | Apple's names kept in Latin; the reviewer should check Apple's Gujarati names |
| Reduce Motion | ગતિ ઘટાડો | |
| Screen & System Audio Recording | સ્ક્રીન અને સિસ્ટમ ઑડિયો રેકોર્ડિંગ | |
| Privacy & Security | ગોપનીયતા અને સુરક્ષા | |
| System Settings / Accessibility | સિસ્ટમ સેટિંગ્સ / ઍક્સેસિબિલિટી | |
| RAW / HDR / SDR / JPEG… | RAW / HDR / SDR / JPEG… | format names are not translated |
| metadata / keywords / caption / title / creator / copyright | મેટાડેટા / કીવર્ડ / કૅપ્શન / શીર્ષક / સર્જક / કૉપિરાઇટ | |
| location | લોકેશન | |
| date taken / date modified / date created | લીધાની તારીખ / સુધાર્યાની તારીખ / બનાવ્યાની તારીખ | the info panel's “Modified” is સુધાર્યાની તારીખ too |
| GPS position | GPS સ્થાન | not સ્થિતિ (that is “state”) |
| changed (by another app) / replaced | ફેરફાર કર્યો / બદલો | બદલો only for Replace; the replaced file = જૂની ફાઇલ, whose place the new file took. “Save over an existing file” = “હાલની ફાઇલ પર સાચવવું”, which “કાયમ માટે બદલી નાખે છે” |
| “A folder named … is in the way” | “… નામનું ફોલ્ડર નડે છે” | not the literal “વચ્ચે આવે છે” |
| channel / animated / transparency / aperture | ચેનલ / એનિમેટેડ / પારદર્શિતા / અપર્ચર | |
| Theme: System, Bright, Gray, Dark | સિસ્ટમ, બ્રાઇટ, ગ્રે, ડાર્ક | transliterated, as macOS does |
| Font weight | ફૉન્ટની જાડાઈ | not વજન |
| arrowhead size | તીરના માથાનું કદ | |
| From / To (range labels) | શરૂઆત / સુધી | “to” between two values = થી |
| Earlier / Later (date shift) | પહેલાંની તરફ / પછીની તરફ | |
| sidecar | સાઇડકાર | XMP સાઇડકાર |
| gain map / tone mapped | ગેઇન મૅપ / ટોન મૅપ કરેલું | |
| magnifier | મૅગ્નિફાયર | |
| Levels / Curves | લેવલ્સ / કર્વ્સ | |
| Lighting / Colors | લાઇટિંગ / રંગો | |
| Clone Stamp / Healing Brush | ક્લોન સ્ટૅમ્પ / હીલિંગ બ્રશ | |
| Red-Eye Removal | રેડ-આઇ દૂર કરવી | |
| Remove Background | બૅકગ્રાઉન્ડ દૂર કરો | |
| Frame (effect) / frame (video) | ફ્રેમ / ફ્રેમ | both “ફ્રેમ”; the reviewer should check the context |
| Text and Shapes | ટેક્સ્ટ અને આકારો | |
| Fill (print scaling) / Fill (shape, canvas) | ભરો / ભરણ | separate keys: Print's choice is a command, the shape's and canvas's colour a noun |
| canvas / anchor | કૅનવાસ / ઍન્કર | |
| Find Duplicates | ડુપ્લિકેટ શોધો | |
| Flat View | ફ્લૅટ વ્યૂ | |
| external editor | બાહ્ય એડિટર | |
| Custom Order | કસ્ટમ ક્રમ | |
| More Filters… | વધુ ફિલ્ટર… | |
| Show All | બધું બતાવો | |
| Select Tagged / Invert Selection | ટૅગ કરેલી પસંદ કરો / પસંદગી ઉલટાવો | |
| Canvas Size… / Perspective… | કૅનવાસનું કદ… / પર્સ્પેક્ટિવ… | |
| RAW Adjustments… | RAW ઍડજસ્ટમેન્ટ… | |
| Auto Enhance / Noise Reduction | ઑટો એન્હાન્સ / નોઇઝ રિડક્શન | |
| Vignette / Radius / Feather | વિનેટ / ત્રિજ્યા / ફેધર | |
| Mixed | મિશ્ર | |
| subject (of a photo) | વિષય | |
| Identical Files / Similar Images / Similarity | સમાન ફાઇલો / સમાન ઇમેજ / સમાનતા | |
| Mark Suggested | સૂચવેલાં ચિહ્નિત કરો | |
| Count Colors | રંગો ગણો | |
| codec / frame rate / data rate | કોડેક / ફ્રેમ રેટ / ડેટા રેટ | |
| mute / unmute | મ્યૂટ કરો / અનમ્યૂટ કરો | |

## Left in English

minivu, format names (JPEG, HEIC, TIFF…), names written to disk (minivu
Wallpapers, Pictures), pattern tokens ({name} and the others), the EXIF
compass letters N/S/E/W, key names, unit symbols (px, MP, fps, Mbit/s), US
Letter, Apple product names (Mac, MacBook Pro, Pro Display XDR, Liquid Retina
XDR, Safari, Spotlight).

## For the reviewer to check first

- Apple macOS Gujarati's exact words: Trash (ટ્રેશ or કચરાપેટી), the Edit menu
  (સંપાદિત કરો), Quit, Reveal in Finder, Minimize, Live Text,
  AirDrop/Messages/Mail.
- The effect “Frame” and a video “frame” are both “ફ્રેમ”.
- Gender and number agreement in composed sentences: “%@ સંબંધિત નવો
  ફેરફાર…” (MinivuCore, metadata field) and “%@ ડિલીટ કરવું/ખસેડવું” (Undo
  steps).
- Keys such as “%@ seconds” and “%@ × %@ pixels” are not plural keys; a
  Gujarati noun after a number is naturally singular, so this matters less.
