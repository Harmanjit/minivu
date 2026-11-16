# Gereedschap

Het menu **Gereedschap** werkt op wat je bekijkt. In de browser gebruikt een
gereedschap de geselecteerde afbeeldingen, of elke getoonde afbeelding als er
niets is geselecteerd. In de viewer gebruikt het de afbeelding op het scherm.
Gereedschap dat afbeeldingen maakt, en de diavoorstelling, slaat video’s
over.

## Diavoorstelling

**Gereedschap > Start diavoorstelling** speelt de afbeeldingen schermvullend af,
met HDR zoals in de viewer. De diavoorstelling opent op het scherm dat
**Schermvullende viewer opent op** in **Instellingen > Viewer** kiest. Als je
begint vanaf één geselecteerde afbeelding, wordt de hele map vanaf die plek
afgespeeld.

- De **spatiebalk** pauzeert en hervat, de pijltoetsen gaan stap voor stap,
  en **Esc** stopt de voorstelling. Beweeg de aanwijzer om de bedieningsbalk
  te tonen.
- Kies de tijd per dia, de volgorde (op volgorde of willekeurig), of de
  voorstelling aan het einde opnieuw begint, bijschriften, en een van acht
  overgangen of een willekeurige overgang in **Instellingen >
  Diavoorstelling**.
- Daar voeg je ook muziek toe: MP3-, AAC-, WAV- of AIFF-nummers, of mappen
  daarmee. De muziek wordt uitgefaded wanneer de voorstelling eindigt.

### Exporteer als video

**Gereedschap > Exporteer diavoorstellingsvideo…** bewaart de
diavoorstelling als videobestand, om overal af te spelen of te versturen.

- Kies de resolutie (720p, 1080p, 4K of de grootte van je scherm), de
  framesnelheid, de codec (H.264, of HEVC voor kleinere bestanden), de
  kwaliteit, en MP4 of MOV.
- De video gebruikt de tijd per dia, de overgang, de volgorde, de
  bijschriften en de muziek die zijn ingesteld in **Instellingen >
  Diavoorstelling**. Elke afbeelding verschijnt één keer.
- De video heeft standaard dynamisch bereik: HDR-foto’s worden via
  toonmapping omgezet.
- Exporteer… vraagt waar je de video wilt bewaren. Daarna volgt een
  voortgangsbalk met Annuleer.

## Batchconversie

**Gereedschap > Batchconversie…** bewaart kopieën van veel afbeeldingen in
een ander formaat.

- Kies het formaat en de opties ervan, zoals bij Bewaar als, en een
  bestemming: een map, of naast de originelen. **Verwijder locatie** laat de
  GPS-positie weg uit de kopieën; deze optie staat in het begin aan.
- Je kunt de kopieën desgewenst hernoemen met een patroon, de grootte ervan
  wijzigen (op lange zijde, breedte, hoogte of percentage), ze draaien of
  spiegelen, en hun metagegevens behouden of verwijderen.
- **Bewerkingen** toont de bewerkingen van de gekozen voorinstelling, gemaakt
  in de viewer met **Archief > Bewaar als voorinstelling…**, en past ze toe op
  elke afbeelding. **Watermerk** voegt een watermerk toe. Zie
  [Bewerken](help:Editing) en [Effecten en retoucheren](help:Effects).
- **Behoud HDR** houdt HDR-foto’s HDR in JPEG, HEIC en AVIF. Hiervoor zijn
  het kleurprofiel Behoud origineel of Display P3 en 8 bits nodig; anders
  worden HDR-foto’s met standaard dynamisch bereik geschreven, en het venster
  meldt dat.
- **Voorinstelling** bovenaan bewaart elke keuze onder een naam, om opnieuw
  te gebruiken.
- De conversie loopt op de achtergrond met een voortgangsbalk en Annuleer, en
  vermeldt alle bestanden die niet konden worden geconverteerd.
- minivu vraagt het voordat er iets zou worden vervangen, en een vervangen
  bestand gaat naar de prullenmand.

**Bestanden met meerdere pagina’s** bepaalt wat er gebeurt met PDF’s, TIFF’s
met meerdere pagina’s en animaties: **Alleen eerste pagina** of **Elke
pagina**. Elke pagina maakt in TIFF en GIF één bestand met alle pagina’s, en
in andere formaten één bestand per pagina.

## Batch-naamswijziging

**Gereedschap > Batch-naamswijziging…** wijzigt de namen van veel bestanden
tegelijk op basis van een patroon van tekst en tokens: de originele naam, een
teller, de opnamedatum, de wijzigingsdatum, de grootte in pixels en de
extensie. Voeg zoeken en vervangen en een hoofdlettergebruik toe, en
controleer de live lijst met voor en na, die conflicten aangeeft voordat er
iets verandert. De hele naamswijziging is één stap van **Wijzig > Herstel**.
Met **Voorinstelling** bewaar je een patroon onder een naam.

## Pagina’s en stroken

- **Gereedschap > Haal pagina’s eruit…** bewaart elke pagina van een PDF of
  TIFF met meerdere pagina’s, of elk frame van een animatie, als een apart
  bestand. Kies alle pagina’s of een bereik, en het formaat, zoals bij
  Batchconversie. De namen gebruiken het token `{page}`, het paginanummer:
  ‘scan-03.png’.
- **Gereedschap > Maak bestand met meerdere pagina’s…** voegt de afbeeldingen
  samen tot één bestand: een TIFF met meerdere pagina’s, een PDF, een
  geanimeerde GIF of, als je Mac het kan schrijven, een geanimeerde HEIC.
  Sleep in de lijst om de volgorde te wijzigen.
- **Gereedschap > Afbeeldingsstrook…** voegt de afbeeldingen samen tot één
  afbeelding, naast elkaar, onder elkaar of in een raster, met de
  tussenruimte en achtergrond die je kiest. De strook opent in de viewer.

## Zoek duplicaten

**Gereedschap > Zoek duplicaten…** vindt kopieën tussen de geselecteerde
afbeeldingen, in de map, of in de map en haar submappen.

- **Identieke bestanden** vindt bestanden met precies dezelfde inhoud.
  **Vergelijkbare afbeeldingen** vindt afbeeldingen die op elkaar lijken,
  zoals verkleinde kopieën, bewerkingen en burstreeksen. Verplaats de
  schuifregelaar **Gelijkenis** om strenger of ruimer te zoeken.
- In elke groep stelt minivu één bestand voor om te behouden: dat met de
  hoogste resolutie, het grootste bestand of het oudste, zoals je kiest.
  **Vink suggesties aan** vinkt alle andere aan; er wordt niets aangevinkt
  totdat je daarom vraagt.
- **Verplaats naar prullenmand…** verplaatst de aangevinkte bestanden naar de
  prullenmand, na het te hebben gevraagd. **Toon in browser** en
  **Vergelijk** tonen de gevonden bestanden.

## Afdrukken en pagina-instelling

**Archief > Druk af…** gebruikt het standaard afdrukpaneel met de
lay-outopties van minivu: afbeeldingen per pagina, passend of vullend,
afbeeldingen draaien om de cellen te vullen, marges, tussenruimte en
bijschriften, met een live voorvertoning. **Archief > Pagina-instelling…**
kiest het papier.

## Contactafdruk

**Gereedschap > Contactafdruk…** zet miniaturen op pagina’s: kolommen, rijen,
tussenruimte, bijschriften, een koptekst, het paginaformaat en de
achtergrond. Bewaar de contactafdruk als JPEG, PNG, TIFF of een PDF met
meerdere pagina’s.

## Webgalerie

**Gereedschap > Maak webgalerie aan…** maakt een map met webpagina’s die de
afbeeldingen tonen: een pagina met miniaturen, en een pagina voor elke
afbeelding met de links ‘Previous’ en ‘Next’ (vorige en volgende). Open de
index.html ervan in een willekeurige webbrowser, vanaf je Mac of nadat je de
map naar een website hebt gekopieerd.

- Kies de titel, de grootte van miniaturen en afbeeldingen, de kolommen, een
  licht, donker of automatisch thema, de volgorde en de bijschriften.
- Afbeeldingen zijn JPEG, HEIC (alleen Safari) of AVIF. Metagegevens kunnen
  worden behouden, en **Verwijder locatie** staat in het begin aan. **Neem de
  originele bestanden op** voegt voor elk origineel een downloadlink toe.
- De pagina’s gebruiken geen scripts en laden niets van het internet.

## Montage-achtergrond en bureaubladafbeelding

- **Gereedschap > Montage-achtergrond…** maakt een collage van de
  afbeeldingen op het formaat van je scherm, als raster, mozaïek of
  verspreide afdrukken, en stelt deze in als bureaubladafbeelding. Montages
  worden bewaard in **Afbeeldingen/minivu Wallpapers**.
- **Gereedschap > Stel in als bureaubladafbeelding** gebruikt één afbeelding
  zoals die is.

## Schermafbeelding

**Gereedschap > Schermafbeelding** legt het volledige scherm vast, een venster
of een selectie die je sleept (de muisknop loslaten legt vast, **Esc**
annuleert). Schermafbeeldingen worden als PNG-bestanden bewaard in
**Afbeeldingen/minivu Captures** en openen in de viewer.

Voor het vastleggen van het volledige scherm of een selectie is toestemming
voor schermopname nodig. macOS vraagt dit de eerste keer; je kunt het later
wijzigen in **Systeeminstellingen > Privacy en beveiliging > Scherm- en
systeemaudio-opname**. Voor het kiezen van een venster in de vensterkiezer
van het systeem is geen toestemming nodig.

## Externe editors

**Gereedschap > Open in externe editor** stuurt de geselecteerde
afbeeldingen, of de getoonde afbeelding, naar een andere app. De eerste
editor in de lijst is **⌘E**. Kies **Wijzig lijst met editors…** om apps toe
te voegen in **Instellingen > Editors**.

Wanneer een editor een bestand bewaart, toont minivu de nieuwe versie. Als je
niet-bewaarde bewerkingen van dat bestand in minivu had, vraagt het of je ze
wilt behouden of het bestand opnieuw wilt laden.

## Opdrachten

minivu voegt acties toe aan de app Opdrachten: **Converteer afbeeldingen**,
**Wijzig grootte van afbeeldingen**, **Wijzig naam van afbeeldingen**, **Stel
waardering in**, **Stel kleurlabel in** en **Open in minivu**. Zoek naar
‘minivu’ in de acties van de app Opdrachten om ze in je eigen opdrachten te
gebruiken. Als je zo’n opdracht uitvoert, wordt minivu geopend als het nog niet
open is. De acties werken alleen op bestanden op de interne opslag van je Mac.
**Wijzig naam van afbeeldingen** werkt alleen in je map Afbeeldingen en in
mappen in de navigatiekolom van minivu; als een bestand ergens anders staat,
krijgt geen enkel bestand een nieuwe naam.

Om een opdracht vanuit de Finder te gebruiken, maak je er een die afbeeldingen
ontvangt en schakel je **Gebruik als snelle taak** in bij de details ervan. Hij
verschijnt dan in het contextuele menu van de Finder onder **Snelle taken**.
