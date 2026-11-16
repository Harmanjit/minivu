# Privacy

## Geen netwerk

minivu maakt nooit verbinding met het internet. Het draait in de App Sandbox
zonder netwerkrechten, dus macOS laat het helemaal geen verbinding openen. Er
is geen account, geen analyse, geen crashrapportage en geen controle op
updates, en deze help maakt deel uit van de app.

## Wat minivu kan zien

De sandbox beperkt minivu tot:

- je map **Afbeeldingen**;
- mappen en bestanden die je kiest in een paneel voor openen of bewaren, op
  minivu neerzet of vanuit de Finder met minivu opent;
- mappen in de navigatiekolom en recente mappen bij Kopieer naar en Verplaats
  naar, die het onthoudt met bladwijzers die alleen deze Mac en deze app
  kunnen gebruiken;
- zijn eigen container, `~/Library/Containers/com.minivu.app`.

Het werkt alleen met de interne opslag van je Mac, niet met geheugenkaarten,
externe schijven of netwerkschijven.

## Wat minivu bewaart

In zijn container, alleen op je Mac:

- **De catalogus** met sterwaarderingen, markeringen en aangepaste volgordes.
- **De miniatuurcache**, die **Instellingen > Miniaturen > Wis
  miniatuurcache** leegmaakt.
- **Instellingen**, inclusief de mappen in de navigatiekolom, recente mappen,
  muziek voor diavoorstellingen en externe editors.

## Wat minivu in je bestanden wijzigt

Alleen waar je om vraagt:

- **Bewaar** schrijft over het origineel, na het te hebben gevraagd. **Bewaar
  als**, Batchconversie, Contactafdruk en Montage maken nieuwe bestanden.
- Draaien en spiegelen in de browser wijzigen de oriëntatietag van een JPEG,
  en Wijzig opmerking wijzigt de opmerking ervan.
- Wijzig naam, Verplaats, Kopieer, Nieuwe map en Batch-naamswijziging wijzigen
  namen en mappen, en kunnen ongedaan worden gemaakt.
- **Verplaats naar prullenmand**, en het vervangen van een bestand met
  dezelfde naam, plaatsen onderdelen in de prullenmand. minivu verwijdert je
  bestanden niet.
- Bestanden worden eerst volledig geschreven en daarna op hun plek gezet, dus
  een onderbroken bewaaractie laat nooit een half bestand achter.

minivu schrijft ook naar **Afbeeldingen/minivu Captures** (schermafbeeldingen)
en **Afbeeldingen/minivu Wallpapers** (montages, en kopieën die zijn gemaakt
voor Stel in als bureaubladafbeelding, waarvan het de tien nieuwste bewaart).

## Toestemmingen

- **Schermopname**, alleen als je Schermafbeelding > Volledig scherm of
  Selectie gebruikt. Je kunt dit uitschakelen in Systeeminstellingen > Privacy
  en beveiliging.
- **Afdrukken**, via het standaard afdrukpaneel.

Detectie van rode ogen vindt gezichten met het Vision-framework van Apple, op
je Mac.
