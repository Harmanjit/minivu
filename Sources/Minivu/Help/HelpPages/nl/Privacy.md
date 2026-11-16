# Privacy

## Geen netwerk

minivu maakt nooit verbinding met het internet. Het draait in de App Sandbox
zonder netwerkrechten, dus macOS laat het helemaal geen verbinding openen. Er
is geen account, geen analyse, geen crashrapportage en geen controle op
updates, en deze help maakt deel uit van de app.

Livetekst, Verwijder achtergrond, Kopieer onderwerp, detectie van rode ogen,
Automatisch bij Perspectief en Vergelijkbare afbeeldingen bij Zoek
duplicaten gebruiken het Vision-framework van Apple, op je Mac. Er wordt
niets verstuurd.

**Archief > Deel…** geeft de bestanden door aan de deelvoorziening die je
kiest, zoals AirDrop of Mail, die ze vervolgens verstuurt. minivu zelf opent
geen verbinding.

## Wat minivu kan zien

De sandbox beperkt minivu tot:

- je map **Afbeeldingen**;
- mappen en bestanden die je kiest in een paneel voor openen of bewaren, op
  minivu neerzet of vanuit de Finder met minivu opent;
- mappen in de navigatiekolom en recente mappen bij Kopieer naar en Verplaats
  naar, die het onthoudt met bladwijzers die alleen deze Mac en deze app
  kunnen gebruiken;
- een afbeelding die voor een watermerk is gekozen, die het onthoudt met een
  alleen-lezen bladwijzer;
- zijn eigen container, `~/Library/Containers/com.minivu.app`.

Het werkt alleen met de interne opslag van je Mac, niet met geheugenkaarten,
externe schijven of netwerkschijven.

## Wat minivu bewaart

In zijn container, alleen op je Mac:

- **De catalogus** met sterwaarderingen, markeringen, aangepaste volgordes,
  collecties, slimme mappen en de fotogegevens die voor filters en
  zoekopdrachten zijn gelezen.
- **De miniatuurcache**, met de vingerafdrukken die Zoek duplicaten maakt,
  die **Instellingen > Miniaturen > Wis miniatuurcache** leegmaakt.
- **Instellingen**, inclusief de mappen in de navigatiekolom, recente mappen,
  muziek voor diavoorstellingen, externe editors en voorinstellingen.

Zoekopdrachten lezen alleen mappen die minivu mag zien, op je Mac. minivu
raadpleegt Spotlight niet.

## Wat minivu in je bestanden wijzigt

Alleen waar je om vraagt:

- **Bewaar** schrijft over het origineel, na het te hebben gevraagd. **Bewaar
  als**, Batchconversie, Haal pagina’s eruit, Maak bestand met meerdere
  pagina’s, Afbeeldingsstrook, Contactafdruk, Montage, Exporteer
  diavoorstellingsvideo en Maak webgalerie aan maken nieuwe bestanden.
- Draaien en spiegelen in de browser wijzigen de oriëntatietag van een JPEG-,
  HEIC-, TIFF- of PNG-bestand, en Wijzig opmerking wijzigt de opmerking van een
  JPEG.
- **Wijzig metagegevens** schrijft de gegevens die je wijzigt in het
  bestand, of in een XMP-sidecarbestand ernaast.
- **Afbeelding > Label** stelt de Finder-kleurtag van het bestand in. Sterren
  en markeringen worden alleen in bestanden geschreven als je **Schrijf
  waarderingen in bestanden (XMP)** inschakelt in Instellingen.
- Een minivu-actie in de app Opdrachten kan bestanden die minivu mag
  wijzigen converteren, de grootte ervan wijzigen, hernoemen, waarderen of
  labelen.
- Wijzig naam, Verplaats, Kopieer, Nieuwe map en Batch-naamswijziging wijzigen
  namen en mappen, en kunnen ongedaan worden gemaakt.
- **Verplaats naar prullenmand** plaatst onderdelen in de prullenmand. Als
  kopiëren, verplaatsen, neerzetten of plakken een bestand met dezelfde naam
  vervangt, gaat het oude bestand naar de prullenmand. Dat geldt ook voor een
  bestand dat Batchconversie, Haal pagina’s eruit, Contactafdruk of Exporteer
  diavoorstellingsvideo vervangt.
- **Bewaar**, en **Bewaar als**, Maak bestand met meerdere pagina’s,
  Afbeeldingsstrook of Bewaar frame als over een bestaand bestand, vervangen dat
  bestand voorgoed. Het gaat niet naar de prullenmand en dit kan niet ongedaan
  worden gemaakt.
- Bestanden worden eerst volledig geschreven en daarna op hun plek gezet, dus
  een onderbroken bewaaractie laat nooit een half bestand achter.

**Locatie.** Bewaar als, Batchconversie, Maak webgalerie aan en de acties
voor Opdrachten laten de GPS-positie en de plaatsnamen weg, tenzij je
**Verwijder locatie** uitschakelt. Bewaar behoudt alles, ook de locatie. De
locatie van een video wordt getoond maar nooit verwijderd.

minivu schrijft ook naar **Afbeeldingen/minivu Captures** (schermafbeeldingen)
en **Afbeeldingen/minivu Wallpapers** (montages, en kopieën die zijn gemaakt
voor Stel in als bureaubladafbeelding, waarvan het de tien nieuwste bewaart).

## Toestemmingen

- **Schermopname**, alleen als je Schermafbeelding > Volledig scherm of
  Selectie gebruikt. Je kunt dit uitschakelen in Systeeminstellingen > Privacy
  en beveiliging.
- **Afdrukken**, via het standaard afdrukpaneel.
