# minivu ગુજરાતી (gu) શબ્દાવલિ

macOS ગુજરાતી (Finder, Photos, Preview)ની શબ્દાવલિને અનુસરવાનો પ્રયાસ કર્યો છે. Appleનો ચોક્કસ શબ્દ ચકાસી શકાયો નથી ત્યાં સામાન્ય સૉફ્ટવેરમાં વપરાતો શબ્દ લીધો છે.
બધા અનુવાદ મશીન અનુવાદ છે અને ગુજરાતી માતૃભાષી વ્યક્તિએ તેમની સમીક્ષા કરવી જરૂરી છે.

## લેખન નિયમો

- સંબોધન: "તમે" (Apple ગુજરાતીની જેમ આદરયુક્ત સંબોધન, પરંતુ "આપ" નહીં). આદેશ બહુવચન-આદરાર્થ રૂપમાં: "ખોલો", "પસંદ કરો", "સાચવો".
- મેનૂ આઇટમ અને બટન: ટૂંકું ક્રિયાપદ રૂપ ("ક્રૉપ કરો…", "ટ્રેશમાં ખસેડો"). સંપાદનનાં નામ ("Undo %@"માં આવતાં) સંજ્ઞા અથવા ક્રિયાવાચક નામ રૂપે ("કદ બદલવું", "ડાબે ફેરવવું"), અને "Undo %@" = "%@ પૂર્વવત્ કરો".
- પ્રશ્નાર્થ પુષ્ટિ સંવાદ: "…ખસેડીએ?", "…બદલીએ?", "…ડિલીટ કરીએ?" (Appleની "Move to Trash?" શૈલી).
- ભૂલ સંદેશ: "… શકાયું નથી." / "… શકાતું નથી."
- અનુગ (માં, નું, થી, ને) શબ્દ કે પ્લેસહોલ્ડર સાથે જોડીને: "Finderમાં", "“%@”માં", "%@ માટે".
- અંકો લૅટિન (0-9) રાખ્યા છે; સંખ્યાનું ફૉર્મેટિંગ સિસ્ટમ કરે છે. એકમ સંક્ષેપ: સે (સેકન્ડ), મિ (મિનિટ), ક (કલાક); px, MP, fps, Mbit/s, pt, mm, dpi લૅટિનમાં.
- અવતરણ ચિહ્ન “ ” (Apple જેવાં). મેનૂ પાથ: ફાઇલ > ફોલ્ડર ખોલો…. ઍલિપ્સિસ "…" (U+2026) જાળવેલ છે.
- કીનાં નામ કીબોર્ડ પર છે તેમ અંગ્રેજીમાં: Return, Esc, Space, Tab, Home, End, Page Up/Down, Shift, Option-ક્લિક. ચિહ્નો (⌘ ⌥ ⇧ ⌫ → ←) જેમ છે તેમ. આ જાણીજોઈને છે (ko જેવું), તેથી આ સ્ટ્રિંગ અંગ્રેજી જેવી જ છે.
- વાક્યક્રમ SOV હોવાથી ઘણી જગ્યાએ positional specifiers (%1$lld, %2$@) વાપર્યા છે, દા.ત. "%2$lld માંથી %1$lld".
- બહુવચન: gu માટે CLDR `one` અને `other`. `one` 0 અને 1 બંનેને આવરે છે, તેથી દરેક `one` રૂપમાં સંખ્યા જાળવી છે. ગુજરાતીમાં સંખ્યા પછી નામ ઘણીવાર એકવચનમાં જ રહે છે ("5 ઇમેજ", "3 પેજ"); "ફાઇલ/ફાઇલો", "ચિત્ર/ચિત્રો", "રંગ/રંગો" જેવાં રૂપમાં બહુવચન વાપર્યું છે.
- લેટર-કેસ વિકલ્પો ગુજરાતીમાં સમજાવેલા, કૌંસમાં લૅટિન ઉદાહરણ સાથે (hi, pa, bn, ta જેવું): “મોટા અક્ષર (UPPERCASE)”, “નાના અક્ષર (lowercase)”, “દરેક શબ્દનો પહેલો અક્ષર મોટો (Title Case)”.

## શબ્દો

| English | ગુજરાતી | નોંધ |
|---|---|---|
| browser | બ્રાઉઝર | ફોલ્ડર સૂચિ અને થંબનેલ ગ્રિડવાળી વિન્ડો |
| viewer | વ્યૂઅર | |
| catalog / ratings database | કૅટલૉગ / રેટિંગ ડેટાબેઝ | |
| collection | કલેક્શન | |
| smart folder | સ્માર્ટ ફોલ્ડર | Finder જેવું |
| saved search | સાચવેલી શોધ | |
| sidebar | સાઇડબાર | |
| Favorites | મનપસંદ | Finder સાઇડબાર હેડર |
| preview pane | પ્રિવ્યૂ પેન | |
| thumbnail | થંબનેલ | |
| filmstrip | ફિલ્મસ્ટ્રિપ | |
| tag (minivuનું નિશાન) | ટૅગ | ક્રિયાપદ: ટૅગ કરો / ટૅગ દૂર કરો; વિશેષણ: ટૅગ કરેલી |
| Finder tags | Finder ટૅગ | |
| rating / Rate N Stars | રેટિંગ / %lld સ્ટાર રેટિંગ આપો | |
| star | સ્ટાર | |
| label / colour label | લેબલ / કલર લેબલ | |
| Red, Orange, Yellow, Green, Blue, Purple, Gray | લાલ, નારંગી, પીળો, લીલો, વાદળી, જાંબલી, ગ્રે | Finder ટૅગ રંગો |
| crop | ક્રૉપ કરો / ક્રૉપ | |
| straighten | સીધું કરો | |
| resize | કદ બદલો | સંપાદનનું નામ: કદ બદલવું |
| rotate left / right | ડાબે ફેરવો / જમણે ફેરવો | |
| flip horizontal / vertical | આડું ફ્લિપ કરો / ઊભું ફ્લિપ કરો | |
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
| image / picture / photo | ઇમેજ / ચિત્ર / ફોટો | મૂળના ભેદ જાળવ્યા છે |
| Pictures folder | Pictures | Finder ડિસ્પ્લે નામ; પાથમાં લૅટિન |
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
| Getting Started (help topic) | શરૂઆત | બીજાં વિષય-શીર્ષકોની જેમ સંજ્ઞા |
| Strength / Free (crop) / aspect ratio | તીવ્રતા / મુક્ત આકાર / પાસા ગુણોત્તર | |
| Use as Quick Action / Quick Actions | ઝડપી ક્રિયા તરીકે વાપરો / ઝડપી ક્રિયાઓ | સમીક્ષક macOS Shortcuts અને Finderનાં ગુજરાતી લેબલ, અને Shortcuts ઍપનું ગુજરાતી નામ ચકાસે |
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
| Quick Look | ક્વિક લુક | વર્તમાન કૅટલૉગમાં વપરાયું નથી |
| Live Text | લાઇવ ટેક્સ્ટ | |
| Services | સેવાઓ | |
| AirDrop, Messages, Mail | AirDrop, Messages, Mail | Appleનાં નામ લૅટિનમાં રાખ્યાં; સમીક્ષક Appleનું ગુજરાતી નામ ચકાસે |
| Reduce Motion | ગતિ ઘટાડો | |
| Screen & System Audio Recording | સ્ક્રીન અને સિસ્ટમ ઑડિયો રેકોર્ડિંગ | |
| Privacy & Security | ગોપનીયતા અને સુરક્ષા | |
| System Settings / Accessibility | સિસ્ટમ સેટિંગ્સ / ઍક્સેસિબિલિટી | |
| RAW / HDR / SDR / JPEG… | RAW / HDR / SDR / JPEG… | ફૉર્મેટ નામ અનુવાદિત નથી |
| metadata / keywords / caption / title / creator / copyright | મેટાડેટા / કીવર્ડ / કૅપ્શન / શીર્ષક / સર્જક / કૉપિરાઇટ | |
| location | લોકેશન | |
| date taken / date modified / date created | લીધાની તારીખ / સુધાર્યાની તારીખ / બનાવ્યાની તારીખ | Info panel “Modified” પણ સુધાર્યાની તારીખ |
| GPS position | GPS સ્થાન | સ્થિતિ નહીં (એ state છે) |
| changed (by another app) / replaced | ફેરફાર કર્યો / બદલો | બદલો ફક્ત Replace માટે; replaced file = જૂની ફાઇલ, જેની જગ્યાએ નવી ફાઇલ આવી |
| channel / animated / transparency / aperture | ચેનલ / એનિમેટેડ / પારદર્શિતા / અપર્ચર | |
| Theme: System, Bright, Gray, Dark | સિસ્ટમ, બ્રાઇટ, ગ્રે, ડાર્ક | macOS જેવાં લિપ્યંતર |
| Font weight | ફૉન્ટની જાડાઈ | વજન નહીં |
| arrowhead size | તીરના માથાનું કદ | |
| From / To (range labels) | શરૂઆત / સુધી | બે મૂલ્યો વચ્ચે “to” = થી |
| Earlier / Later (date shift) | પહેલાંની તરફ / પછીની તરફ | |
| sidecar | સાઇડકાર | XMP સાઇડકાર |
| gain map / tone mapped | ગેઇન મૅપ / ટોન મૅપ કરેલું | |
| magnifier | મૅગ્નિફાયર | |
| Levels / Curves | લેવલ્સ / કર્વ્સ | |
| Lighting / Colors | લાઇટિંગ / રંગો | |
| Clone Stamp / Healing Brush | ક્લોન સ્ટૅમ્પ / હીલિંગ બ્રશ | |
| Red-Eye Removal | રેડ-આઇ દૂર કરવી | |
| Remove Background | બૅકગ્રાઉન્ડ દૂર કરો | |
| Frame (effect) / frame (video) | ફ્રેમ / ફ્રેમ | બંને "ફ્રેમ"; સમીક્ષક સંદર્ભ ચકાસે |
| Text and Shapes | ટેક્સ્ટ અને આકારો | |
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

## અંગ્રેજીમાં જ રાખેલું

minivu, ફૉર્મેટ નામ (JPEG, HEIC, TIFF…), ડિસ્ક પર લખાતાં નામ (minivu Wallpapers, Pictures), પૅટર્ન ટોકન ({name} વગેરે), EXIF હોકાયંત્ર દિશા N/S/E/W, કીનાં નામ, એકમ ચિહ્નો (px, MP, fps, Mbit/s), US Letter, Apple ઉત્પાદન નામ (Mac, MacBook Pro, Pro Display XDR, Liquid Retina XDR, Safari, Spotlight).

## સમીક્ષક માટે પહેલાં ચકાસવાનું

- Apple macOS ગુજરાતીના ચોક્કસ શબ્દો: Trash (ટ્રેશ vs કચરાપેટી), Edit મેનૂ (સંપાદિત કરો), Quit, Reveal in Finder, Minimize, Live Text, AirDrop/Messages/Mail.
- "Frame" (અસર) અને વીડિયો "frame" બંને "ફ્રેમ" છે.
- લિંગ/વચન સંમતિ: "%@ સંબંધિત નવો ફેરફાર…" (MinivuCore, metadata field) અને "%@ ડિલીટ કરવું/ખસેડવું" (Undo steps) જેવાં જોડાયેલાં વાક્યો.
- "%@ seconds", "%@ × %@ pixels" જેવી કી પ્લુરલ કી નથી; ગુજરાતીમાં સંખ્યા પછી એકવચન સ્વાભાવિક છે, તેથી સમસ્યા ઓછી.
