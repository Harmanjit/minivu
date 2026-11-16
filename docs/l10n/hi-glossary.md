# minivu – Hindi (hi) glossary

Machine translation, needs review by a native speaker. Terminology follows
Apple's Hindi macOS (Finder, Photos, Preview) where Apple ships the term;
otherwise the everyday English loanword in Devanagari, as Indian software UI
uses it. Register: modern, plain Hindi, not Sanskritised or Persianised.

## Style

- Address: formal "आप". Menu commands and buttons use the polite imperative
  in -एँ / -ें ("खोलें", "ट्रैश में ले जाएँ", "इमेज कन्वर्ट करें"); a few
  short labels are nouns ("समायोजन", "इफ़ेक्ट", "स्लाइडशो").
- Questions and alerts: "क्या आप … चाहते हैं?", "… नहीं किया जा सका।",
  "… पहले से मौजूद है।" Progress messages: "… किया जा रहा है…".
- Sentences end with the danda "।"; "?" and ":" as in English. Ellipsis "…"
  (U+2026) kept, no space before it ("सेटिंग्ज़…", "चुनें…").
- Quotation marks “ ” (as in Apple's Hindi dialogs). Menu path in prose:
  फ़ाइल > फ़ोल्डर खोलें… ; settings path with › or > as the English has it.
- Digits: Western Arabic (0–9), as Apple's Hindi UI uses by default.
  Unit symbols stay Latin (px, MP, fps, Mbit/s, pt, mm, dpi, m); spoken
  abbreviations: से. (seconds), मि. (minutes), घं. (hours).
- Word order is SOV, so many strings reorder their arguments with
  positional specifiers ("%2$lld में से %1$lld" = "%1$lld of %2$lld").
- Nukta is written for loan sounds: फ़ाइल, फ़ोल्डर, फ़ोटो, ज़ूम, फ़ुल स्क्रीन.
- Key names stay as printed on the Mac keyboard, in Latin: Return, Esc,
  Space, Tab, Home, End, Page Up/Down, Shift, Option; glyphs ⌘ ⇧ ⌥ ⌫ → ←
  kept. Gestures are Hindi/loan: क्लिक, ड्रैग, पिंच, स्क्रॉल, दबाकर रखें.
- Plurals: CLDR `one` (i = 0 or n = 1) and `other`. Because `one` also
  covers 0, every `one` form keeps the number. Nouns: फ़ाइल → फ़ाइलें,
  तस्वीर → तस्वीरें, आँख → आँखें; इमेज, फ़ोटो, फ़ोल्डर, आइटम, पेज, वीडियो,
  स्टार, सेकंड, रंग, बाइट are the same in both forms. Verbs agree in
  gender/number (फ़ाइल कन्वर्ट हुई / फ़ाइलें कन्वर्ट हुईं; आइटम चुना गया /
  चुने गए). इमेज, फ़ाइल, फ़ोटो, तस्वीर are feminine; फ़ोल्डर, आइटम, पेज,
  वीडियो masculine.
- Letter-case choices (Title Case, UPPERCASE, lowercase) act on Latin file
  names, so they are glossed in Hindi with the English example in brackets.

## Menus

| English | Hindi |
|---|---|
| File | फ़ाइल |
| Edit | संपादित करें |
| View | देखें |
| Go | जाएँ |
| Image | इमेज |
| Tools | टूल्स |
| Window | विंडो |
| Help | सहायता |
| Settings… | सेटिंग्ज़… |
| About minivu / Quit minivu / Hide minivu | minivu के बारे में / minivu बंद करें / minivu छुपाएँ |
| Hide Others / Bring All to Front | अन्य छुपाएँ / सभी को सामने लाएँ |
| Minimize / Zoom (window) | छोटा करें / ज़ूम करें |
| Enter / Exit Full Screen | फ़ुल स्क्रीन में जाएँ / फ़ुल स्क्रीन से बाहर निकलें |
| Services | सेवाएँ |

## Standard commands

| English | Hindi |
|---|---|
| Open / Open Folder… | खोलें / फ़ोल्डर खोलें… |
| Close Window | विंडो बंद करें |
| Save / Save As… / Don't Save | सहेजें / इस रूप में सहेजें… / न सहेजें |
| Revert to Saved | सहेजे गए संस्करण पर वापस जाएँ |
| Undo / Redo | पूर्ववत करें / फिर से करें |
| Cut / Copy / Paste | कट करें / कॉपी करें / पेस्ट करें |
| Select All / Invert Selection | सभी चुनें / चयन उलटें |
| Delete | डिलीट करें |
| Duplicate | डुप्लिकेट करें |
| Rename | नाम बदलें |
| Move / Move To / Copy To | ले जाएँ / यहाँ ले जाएँ / यहाँ कॉपी करें |
| New Folder / untitled folder | नया फ़ोल्डर / बिना शीर्षक का फ़ोल्डर |
| Trash | ट्रैश |
| Move to Trash | ट्रैश में ले जाएँ |
| Put back (from Trash) | वापस रखें |
| Reveal in Finder | Finder में दिखाएँ |
| Share… | शेयर करें… |
| Print… / Page Setup… | प्रिंट करें… / पेज सेटअप… |
| Quick Look | क्विक लुक (not used in the strings) |
| Show … / Hide … | … दिखाएँ / … छुपाएँ |
| Show Hidden Files | छुपी हुई फ़ाइलें दिखाएँ |
| Sidebar | साइडबार |
| Favorites | पसंदीदा |
| Pictures (folder) | चित्र |
| Desktop picture / Set as Desktop Picture | डेस्कटॉप चित्र / डेस्कटॉप चित्र के रूप में सेट करें |
| Wallpaper | वॉलपेपर |
| System Settings | सिस्टम सेटिंग्ज़ |
| Privacy & Security › Screen & System Audio Recording | गोपनीयता और सुरक्षा › स्क्रीन और सिस्टम ऑडियो रिकॉर्डिंग |
| Reduce Motion / Accessibility | गति कम करें / पहुँच |
| Live Text | लाइव टेक्स्ट |
| AirDrop, Messages, Mail | AirDrop, संदेश, मेल |
| Application / app | ऐप्लिकेशन / ऐप |
| Item | आइटम |
| Extension (file name) | एक्सटेंशन |
| Kind / Type | प्रकार |
| Keyboard Shortcuts | कीबोर्ड शॉर्टकट |
| OK / Cancel / Done | ठीक है / रद्द करें / हो गया |

## minivu terms

| English | Hindi |
|---|---|
| browser | ब्राउज़र |
| viewer / full-screen viewer | व्यूअर / फ़ुल स्क्रीन व्यूअर |
| image / picture / photo | इमेज / तस्वीर / फ़ोटो (the English distinction is kept) |
| thumbnail / thumbnail cache | थंबनेल / थंबनेल कैश |
| filmstrip | फ़िल्मस्ट्रिप |
| preview pane / pane / panel | प्रीव्यू पेन / पेन / पैनल |
| info overlay | जानकारी ओवरले |
| catalog / ratings database | कैटलॉग / रेटिंग डेटाबेस |
| collection | संग्रह |
| smart folder | स्मार्ट फ़ोल्डर |
| saved search | सहेजी गई खोज |
| Flat View | फ़्लैट व्यू |
| tag (minivu's pick mark): verb / noun / tagged | टैग करें / टैग / टैग किया गया |
| Finder tags | Finder टैग |
| mark (for the Trash) | मार्क करें |
| label / colour label | लेबल / रंग लेबल |
| None, Red, Orange, Yellow, Green, Blue, Purple, Gray | कोई नहीं, लाल, नारंगी, पीला, हरा, नीला, बैंगनी, ग्रे |
| rating / Rate N Stars / star | रेटिंग / N स्टार की रेटिंग दें / स्टार |
| Custom Order | कस्टम क्रम |
| crop | क्रॉप करें (edit name: क्रॉप) |
| straighten | सीधा करें |
| rotate / flip | रोटेट करें / फ़्लिप करें |
| resize / resample | आकार बदलें / रीसैंपल करें |
| canvas / Canvas Size / anchor | कैनवस / कैनवस का आकार / एंकर |
| batch convert / Batch Convert… | बैच कन्वर्ट / बैच कन्वर्ट… |
| batch rename / Batch Rename… | बैच में नाम बदलें… |
| rename pattern / token / counter | पैटर्न / टोकन / काउंटर |
| letter case | अक्षरों का केस |
| preset | प्रीसेट |
| edits | संपादन |
| slideshow / slide / transition | स्लाइडशो / स्लाइड / ट्रांज़िशन |
| captions | कैप्शन |
| metadata | मेटाडेटा |
| keyword(s) | कीवर्ड |
| title / caption / creator / copyright / comment | शीर्षक / कैप्शन / निर्माता / कॉपीराइट / टिप्पणी |
| date taken / date modified / date created | लेने की तिथि / संशोधन की तिथि / बनाने की तिथि |
| location (where a photo was taken) | स्थान |
| GPS position / IPTC place names | GPS स्थिति / IPTC स्थानों के नाम |
| XMP sidecar | XMP साइडकार |
| RAW / camera raw / RAW Adjustments | RAW / कैमरा RAW / RAW समायोजन |
| HDR, SDR, gain map, tone mapped | HDR, SDR, गेन मैप, टोन मैप किया गया |
| contact sheet | कॉन्टैक्ट शीट |
| montage wallpaper | मोंटाज वॉलपेपर |
| image strip | इमेज स्ट्रिप |
| web gallery | वेब गैलरी |
| multi-page file | मल्टी-पेज फ़ाइल |
| Capture (screen) | कैप्चर |
| external editor / Editors | बाहरी संपादक / संपादक |
| Find Duplicates / duplicates / similarity | डुप्लिकेट ढूँढें / डुप्लिकेट / समानता |
| Identical Files / Similar Images / Mark Suggested | एक जैसी फ़ाइलें / मिलती-जुलती इमेज / सुझाए गए मार्क करें |
| magnifier | मैग्निफ़ायर |
| Lens (effect) | लेंस |
| Frame (picture border effect) | चौखट |
| frame (video / animation) | फ़्रेम |
| watermark | वॉटरमार्क |
| drop shadow | ड्रॉप शैडो |
| mat / matte / keyline | मैट / मैट / कीलाइन |
| Clone Stamp / Healing Brush | क्लोन स्टैम्प / हीलिंग ब्रश |
| Red-Eye Removal | रेड-आई हटाएँ (edit name: रेड-आई हटाना) |
| Text and Shapes / callout | टेक्स्ट और आकृतियाँ / कॉलआउट |
| Adjust (submenu) | समायोजन |
| Levels / Curves | लेवल्स / कर्व्स |
| Lighting / Colors | लाइटिंग / रंग |
| brightness / contrast / saturation / hue / tint | चमक / कंट्रास्ट / संतृप्ति / ह्यू / टिंट |
| highlights / shadows / exposure | हाइलाइट्स / शैडो / एक्सपोज़र |
| sharpen / blur / noise reduction | शार्प करें / ब्लर / नॉइज़ रिडक्शन |
| grayscale / sepia / negative | ग्रेस्केल / सीपिया / नेगेटिव |
| Auto / Auto Enhance | स्वतः / स्वतः बेहतर बनाएँ |
| Perspective | परिप्रेक्ष्य |
| Vignette / Radius / Feather | विनेट / त्रिज्या / फ़ेदर |
| opacity | अपारदर्शिता |
| subject / Copy Subject / Remove Background | सब्जेक्ट / सब्जेक्ट कॉपी करें / बैकग्राउंड हटाएँ |
| Mixed (differing values) | मिश्रित |
| Edit Metadata… | मेटाडेटा संपादित करें… |
| Keep Both / Replace / Skip | दोनों रखें / बदलें / छोड़ें |
| display / screen | डिस्प्ले / स्क्रीन |
| internal storage | आंतरिक स्टोरेज |
| Find… | ढूँढें… |
| Export Slideshow Video… | स्लाइडशो वीडियो एक्सपोर्ट करें… |
| codec / frame rate / data rate | कोडेक / फ़्रेम दर / डेटा दर |
| mute / unmute | म्यूट करें / अनम्यूट करें |
| Copy Text / Copy Frame / Save Frame As… | टेक्स्ट कॉपी करें / फ़्रेम कॉपी करें / फ़्रेम को इस रूप में सहेजें… |
| Count Colors | रंग गिनें |
| clipboard | क्लिपबोर्ड |

## Left in English

minivu; format and codec names (JPEG, HEIC, AVIF, TIFF, PNG, PDF, GIF,
sRGB, Display P3, ImageIO); Apple and third-party product names (Mac,
Finder, Spotlight, Safari, AirDrop, MacBook Pro, Pro Display XDR, Liquid
Retina XDR, Lightroom, Bridge, digiKam, Windows); names written to disk
(minivu Wallpapers, minivu Captures); rename tokens ({name}, {#}, {date}…);
EXIF compass letters N/S/E/W; unit symbols; key names; paper size "US
Letter"; abbreviations DPI, ISO, GPS, HDR.

## Points for the reviewer

- Check the Apple-shipped terms first: सेटिंग्ज़, ट्रैश, Finder में दिखाएँ,
  पूर्ववत करें, सहेजें, चित्र (Pictures folder), लाइव टेक्स्ट, गति कम करें,
  पहुँच (Accessibility), स्क्रीन और सिस्टम ऑडियो रिकॉर्डिंग.
- "Frame" the picture-border effect is चौखट, to keep it apart from a
  video/animation फ़्रेम; a reviewer may prefer फ़्रेम for both.
- Units after a formatted number ("%@ seconds", "%@ × %@ pixels") don't
  inflect in Hindi, so they need no plural keys.
