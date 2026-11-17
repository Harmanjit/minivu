# minivu Bengali (bn) glossary

The terms try to stay close to Apple's macOS in Bengali (Finder, Photos,
Preview). Every translation is a machine translation and needs review by a
native Bengali speaker. Where it isn't certain which word Apple uses
(especially Save and Undo, below), the reviewer should check those first.

## Writing rules

- Register: formal “আপনি” (as Apple). Menu items and buttons use the polite
  imperative: খুলুন, বন্ধ করুন, ট্র্যাশে সরান, শেয়ার করুন…. Menu titles that are
  not commands are nouns: ফাইল, সম্পাদনা, দেখুন, যান, টুল, উইন্ডো, সহায়তা. The
  Edit menu is “সম্পাদনা” and the View menu “দেখুন” (as Apple).
- Edit names (the Crop in “Undo Crop”) are verbal nouns: ক্রপ, বাঁয়ে ঘোরানো,
  আকার পরিবর্তন. “Undo %@” is “পূর্বাবস্থায় ফেরান: %@” and “Redo %@” is “আবার
  করুন: %@”; with the colon any name fits without breaking the grammar.
- Sentences end with the dari “।”. Question mark “?” and colon “:” as in
  English. Quotation marks “ ” and ellipsis “…” (U+2026). A button or command
  named inside a sentence, in the UI and in the help, goes in ‘ ’ (‘এই নামে সেভ
  করুন’, ‘গতি কমান’, ‘মেটাডেটা রাখুন’-এর অধীনে), so an imperative name doesn't
  run into the sentence. Menu paths are written “ফাইল > ফোল্ডার খুলুন…”.
- Numbers and words: the classifier “টি” follows the number directly
  (“%lldটি ছবি”, “%lldটি ফাইল”). A unit symbol follows a space (“%@ px”,
  “%lld বাইট”, “4 GB”). Case endings attach with a hyphen: “%@-এ”, “Mac-এর”,
  ““%@”-এর”.
- Plurals: CLDR bn has `one` (i = 0 or n = 1) and `other`. A Bengali noun
  doesn't change after a number, so both forms are the same and `one` keeps
  the number too (0 takes this form). Even where the English `one` form has
  no number (“The pattern has an unknown token: %2$@.”), the Bengali `one`
  form keeps `%1$lld`.
- Word order is SOV. Positional specifiers (%1$@, %2$lld) reorder where
  needed, as in “%2$lldটির মধ্যে %1$lldটি নির্বাচিত”. A string never mixes
  positional and plain specifiers.
- Digits: numbers written in a string (16, 4 GB, 1 থেকে 100) stay in Western
  digits. Numbers from specifiers come in the system locale's digits. If the
  locale shows Bengali digits (০–৯), the reviewer should check whether the
  mix looks odd.
- Key names stay in English as printed on the keyboard (Return, Esc, Space,
  Tab, Home, End, Page Up/Down, Shift, Option); glyphs unchanged (⌘ ⌥ ⇧ ⌫ →
  ←); “Option-ক্লিক”, “⌥-ক্লিক”. This is deliberate (as in ko), so those
  strings match English.
- The three letter-case options are explained in Bengali with a Latin
  example in brackets (“বড় হাতের অক্ষর (UPPERCASE)”, “ছোট হাতের অক্ষর
  (lowercase)”, “শব্দের প্রথম অক্ষর বড় (Title Case)”), as in hi, pa and ta,
  because they apply to Latin file names. Bengali script has no letter case.
- Units: মিটার is written out (“%@ মিটার”), because the abbreviation মি
  differs from the minutes abbreviation মি. only by the dot.

## Terms

| English | Bengali | Note |
|---|---|---|
| browser | ব্রাউজার | the window with the folder list and the thumbnail grid |
| viewer | ভিউয়ার | |
| catalog / ratings database | ক্যাটালগ / রেটিং ডেটাবেস | |
| collection | সংগ্রহ | sidebar section: “সংগ্রহ” |
| smart folder | স্মার্ট ফোল্ডার | as in Finder |
| saved search | সেভ করা অনুসন্ধান | |
| sidebar / Favorites | সাইডবার / পছন্দসই | |
| preview pane | প্রিভিউ প্যান | |
| thumbnail | থাম্বনেল | |
| cache | ক্যাশ | not “ক্যাশে”, which sounds like a locative |
| drop (drag and drop) | ড্রপ করা | in the UI and the help |
| Make / Lens make / Creator | প্রস্তুতকারক / লেন্সের প্রস্তুতকারক / নির্মাতা | |
| Altitude / Elevation (light angle) | সমুদ্রপৃষ্ঠ থেকে উচ্চতা / আলোর কোণ | Height = উচ্চতা |
| filmstrip | ফিল্মস্ট্রিপ | |
| tag (minivu's own mark) | ট্যাগ | verb: ট্যাগ করুন / ট্যাগ সরান; adjective: ট্যাগ করা |
| Finder tags | Finder ট্যাগ | |
| rating / Rate N Stars | রেটিং / %lldটি তারা রেটিং দিন | |
| star | তারা | |
| label / colour label | লেবেল / রঙের লেবেল | |
| Red, Orange, Yellow, Green, Blue, Purple, Gray | লাল, কমলা, হলুদ, সবুজ, নীল, বেগুনি, ধূসর | |
| crop (verb / edit name) | ক্রপ করুন / ক্রপ | |
| straighten | সোজা করুন | |
| resize | আকার পরিবর্তন করুন | |
| rotate left / right | বাঁয়ে ঘোরান / ডানে ঘোরান | |
| flip horizontal / vertical | অনুভূমিকভাবে উল্টান / উল্লম্বভাবে উল্টান | |
| batch convert | ব্যাচ রূপান্তর | |
| batch rename | ব্যাচে নাম পরিবর্তন | |
| rename | নাম পরিবর্তন করুন | |
| find … replace with … (Batch Rename row) | [খুঁজুন] এর বদলে [প্রতিস্থাপন] | “with” = “এর বদলে” (Y instead of X); the replacement field's label is “প্রতিস্থাপনের টেক্সট” |
| Remove … / Delete … | … সরান / … মুছুন | মুছুন only for Delete (“এই বৃত্তটি সরান”) |
| slideshow / transition | স্লাইডশো / ট্রানজিশন | |
| contact sheet | কন্ট্যাক্ট শিট | |
| image strip | ছবির স্ট্রিপ | |
| montage wallpaper / desktop picture | মন্টাজ ওয়ালপেপার / ডেস্কটপ ছবি | |
| web gallery | ওয়েব গ্যালারি | |
| watermark | ওয়াটারমার্ক | |
| preset | প্রিসেট | |
| edits | সম্পাদনা | |
| image / picture / photo | ছবি / ছবি / ফটো | “image” and “picture” are both ছবি; ফটো only for “photo” |
| Pictures folder | Pictures | the folder's name as Finder shows it |
| file / folder | ফাইল / ফোল্ডার | |
| Trash | ট্র্যাশ | |
| Move to Trash | ট্র্যাশে সরান | |
| Put Back | ফিরিয়ে আনুন | |
| Reveal in Finder | Finder-এ দেখান | |
| Share… | শেয়ার করুন… | |
| Quick Look | Quick Look | Apple's feature name, not used in the current catalog |
| Live Text | লাইভ টেক্সট | review: check Apple's Bengali name |
| Page Setup… / Print… | পৃষ্ঠা সেটআপ… / প্রিন্ট করুন… | |
| Save / Save As… / Don’t Save | সেভ করুন / এই নামে সেভ করুন… / সেভ করবেন না | review: if Apple uses “সংরক্ষণ করুন”, change it everywhere |
| Revert to Saved | সেভ করা অবস্থায় ফিরিয়ে নিন | |
| Undo / Redo | পূর্বাবস্থায় ফেরান / আবার করুন | |
| Cut / Copy / Paste / Select All | কাট করুন / কপি করুন / পেস্ট করুন / সবকিছু নির্বাচন করুন | |
| Duplicate | ডুপ্লিকেট করুন | |
| Move To / Copy To (submenu) | ফোল্ডারে সরান / ফোল্ডারে কপি করুন | |
| Enclosing Folder | উপরের ফোল্ডার | not “মূল”, so it isn't confused with “আসল” (original) |
| save over the original | আসল ফাইলের জায়গায় সেভ / ওভাররাইট করা | not “উপর সেভ”, in the UI and the help |
| Undo-step names (Move %@, Delete %@, Add %@) | %@ সরানো / %@ মুছে ফেলা / %@ যোগ করা | verbal nouns, placed after “পূর্বাবস্থায় ফেরান: %@” |
| From / To (range labels) | শুরু / শেষ | “to” between two values = থেকে (“1 থেকে 5”) |
| Fill (print scaling, canvas, shape) | ভরাট | |
| Forever (animation loop) | অবিরাম লুপ | not চিরকাল, which is literary |
| “A folder named … is in the way” | “… নামে একটি ফোল্ডার আগে থেকেই আছে” | not a literal “in the way” |
| width by height (VoiceOver) | %1$@ বাই %2$@ | as spoken; গুণ reads as multiplication |
| Getting Started (help) | শুরুর কথা | |
| Settings… | সেটিংস… | |
| Quit minivu / Hide minivu / Hide Others | minivu থেকে প্রস্থান করুন / minivu লুকান / অন্যগুলো লুকান | |
| Minimize / Zoom (window) / Bring All to Front | ছোট করুন / জুম / সবকিছু সামনে আনুন | |
| Enter / Exit Full Screen | ফুল স্ক্রিন ব্যবহার করুন / ফুল স্ক্রিন থেকে প্রস্থান করুন | |
| Zoom In / Zoom Out / Actual Size / Fit to Window | জুম ইন করুন / জুম আউট করুন / আসল আকার / উইন্ডোতে মানানসই করুন | |
| window | উইন্ডো | |
| Services | পরিষেবা | |
| AirDrop, Messages, Mail | AirDrop, বার্তা, মেল | |
| Reduce Motion | গতি কমান | review: check Apple's accessibility name |
| Privacy & Security / Screen & System Audio Recording | গোপনীয়তা ও নিরাপত্তা / স্ক্রিন ও সিস্টেম অডিও রেকর্ডিং | |
| System Settings | সিস্টেম সেটিংস | |
| RAW / HDR / SDR | RAW / HDR / SDR | in Latin letters |
| metadata / keywords / caption / title / creator / copyright | মেটাডেটা / কীওয়ার্ড / ক্যাপশন / শিরোনাম / নির্মাতা / কপিরাইট | |
| location | লোকেশন | “GPS position”: GPS অবস্থান; “place names”: স্থানের নাম |
| date taken / date modified / date created | তোলার তারিখ / পরিবর্তনের তারিখ / তৈরির তারিখ | |
| sidecar | সাইডকার | XMP সাইডকার |
| gain map / tone mapped | গেইন ম্যাপ / টোন ম্যাপ করা | |
| shadows / highlights | শ্যাডো / হাইলাইট | the same words in the UI and the help (not ছায়া) |
| magnifier | ম্যাগনিফায়ার | |
| Levels / Curves | লেভেলস / কার্ভস | |
| Lighting / Colors | আলো / রং | |
| Clone Stamp / Healing Brush | ক্লোন স্ট্যাম্প / হিলিং ব্রাশ | |
| Red-Eye Removal | রেড-আই অপসারণ | |
| Remove Background | ব্যাকগ্রাউন্ড সরান | |
| Frame (effect) / frame (video, animation) | ফ্রেম / ফ্রেম | one word in Bengali; the context tells them apart |
| Text and Shapes | টেক্সট এবং আকৃতি | |
| canvas / anchor | ক্যানভাস / অ্যাঙ্কর | |
| Find Duplicates | ডুপ্লিকেট খুঁজুন | |
| Flat View | ফ্ল্যাট ভিউ | |
| external editor | এক্সটার্নাল এডিটর | |
| Custom Order | কাস্টম ক্রম | |
| More Filters… | আরও ফিল্টার… | |
| Select Tagged / Invert Selection | ট্যাগ করাগুলো নির্বাচন করুন / নির্বাচন উল্টে দিন | |
| Find… | খুঁজুন… | |
| Canvas Size… / Perspective… | ক্যানভাসের আকার… / পরিপ্রেক্ষিত… | |
| RAW Adjustments… / Auto Enhance | RAW সমন্বয়… / স্বয়ংক্রিয় উন্নতি | |
| Noise Reduction… / Vignette… / Radius / Feather | নয়েজ হ্রাস… / ভিনিয়েট… / ব্যাসার্ধ / ফেদার | |
| Mixed | মিশ্র | |
| Copy Subject / Copy Text / Copy Frame | বিষয় কপি করুন / টেক্সট কপি করুন / ফ্রেম কপি করুন | |
| Export Slideshow Video… | স্লাইডশো ভিডিও এক্সপোর্ট করুন… | |
| Extract Pages… / Create Multi-Page File… | পৃষ্ঠা বের করুন… / মাল্টি-পেজ ফাইল তৈরি করুন… | |
| Identical Files / Similar Images / Similarity | অভিন্ন ফাইল / অনুরূপ ছবি / সাদৃশ্য | |
| Mark Suggested | প্রস্তাব অনুযায়ী চিহ্নিত করুন | marks every file except the ones suggested to keep |
| Count Colors | রং গুনুন | |
| codec / frame rate / data rate | কোডেক / ফ্রেম রেট / ডেটা রেট | |
| mute / unmute | মিউট করুন / আনমিউট করুন | |

## Left in English

minivu, Finder, Spotlight, Mac, Safari and other brand and app names.
Format names (JPEG, HEIC, TIFF, PDF, XMP, EXIF, IPTC, sRGB, Display P3…).
Names written to disk (minivu Wallpapers, Pictures). Pattern tokens ({name}
and the others). The latitude and longitude letters N/S/E/W. Unit symbols
(px, MP, fps, Mbit/s, pt, dpi). Key names. The paper sizes US Letter and A4.
