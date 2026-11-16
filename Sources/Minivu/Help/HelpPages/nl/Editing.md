# Bewerken

Bewerken gebeurt in de viewer. Je wijzigingen worden bewaard als een lijst
met stappen en getoond terwijl je ze maakt, maar er verandert niets op schijf
totdat je bewaart.

## Open een gereedschap

Kies een gereedschap uit het menu **Afbeelding**, of beweeg de aanwijzer naar
de linkerrand van de viewer en kies er een uit het paneel. De regelaars van
het gereedschap nemen de plaats van het paneel in en blijven open terwijl je
werkt.

- **Pas toe** voegt de wijziging aan de afbeelding toe, **Annuleer** laat
  deze weg, en **Stel opnieuw in** zet de regelaars terug naar hun
  beginstand.
- In het paneel passen **Draai en spiegel** en **Kleureffecten** elke knop
  meteen toe; **Gereed** sluit ze.
- In het gereedschap waarmee je tekent of schildert, wordt wat je tot dan toe
  hebt gedaan toegepast als je een ander commando kiest, in plaats van dat het
  verloren gaat.

## Het gereedschap

- **Draai linksom**, **Draai rechtsom**, **Spiegel horizontaal**, **Spiegel
  verticaal**.
- **Wijzig grootte/hersample…** stelt een nieuwe grootte in pixels of procent
  in, met of zonder behoud van de beeldverhouding, met een van 11
  hersamplingfilters, van Box en Bilinear tot Lanczos 8.
- **Canvasgrootte…** maakt het canvas rond de afbeelding groter of kleiner,
  in pixels of procent. Kies met het ankerpunt van 3 × 3 waar de afbeelding
  komt te staan, en vul de nieuwe ruimte met een kleur of laat deze
  transparant. Een kleiner canvas snijdt de afbeelding bij.
- **Snijd bij…**: sleep de rechthoek of de grepen ervan. Kies Vrij, de eigen
  vorm van de afbeelding, of 1:1, 4:3, 3:2, 16:9 of 5:4, staand of liggend.
- **Rechttrekken…** draait de afbeelding tot 45° naar beide kanten en snijdt
  de lege hoeken weg.
- **Perspectief…** trekt iets recht dat onder een hoek is gefotografeerd,
  zoals een document of een gebouw. Sleep de vier hoekgrepen naar de hoeken
  van iets dat rechthoekig hoort te zijn, of klik op **Automatisch** om er
  een te laten vinden. **Toon resultaat** toont een voorvertoning van de
  correctie.
- **Pas aan > RAW-aanpassingen…**, alleen voor camera-RAW-bestanden:
  belichting, versterking (contrast), herstel van hoge lichten, witbalans en
  ruisonderdrukking, uitgaande van de eigen instellingen van de camera.
  minivu kan een RAW-bestand niet overschrijven, dus bewaar het resultaat met
  **Bewaar als…**.
- **Pas aan > Belichting…**: helderheid, contrast, gamma, schaduwen en hoge
  lichten.
- **Pas aan > Kleuren…**: kleurtoon, verzadiging, lichtheid, temperatuur en tint,
  en afzonderlijk rood, groen en blauw.
- **Pas aan > Curven…** en **Niveaus…** voor nauwkeurige toonregeling.
- **Pas aan > Verbeter automatisch** verbetert de toon en de kleur met één
  klik. Als de foto niets nodig heeft, geeft minivu een geluidssignaal.
- **Pas aan > Verscherpen…**, **Vervagen…** en **Ruisonderdrukking…**.
  Ruisonderdrukking maakt korrel gladder en behoudt randen; met de
  schuifregelaar Scherpte haal je detail terug.
- **Wijzig opmerking…** stelt de opmerking in die in een JPEG-bestand is
  opgeslagen. Deze wordt in het bestand geschreven als je in de
  opmerkingeneditor op Bewaar klikt.
- **Wijzig metagegevens…** (**⌘I**) wijzigt de gegevens van het bestand. Zie
  Metagegevens hieronder.

Voor effecten, tekenen en retoucheren, zie
[Effecten en retoucheren](help:Effects).

## Metagegevens

Metagegevens zijn de informatie die bij een foto is opgeslagen: wie de foto
heeft gemaakt, wanneer, waar, en een titel of trefwoorden. **Afbeelding >
Wijzig metagegevens…** (**⌘I**) wijzigt ze voor de getoonde afbeelding, of
voor elke afbeelding die in de browser is geselecteerd.

- **Beschrijving:** titel, bijschrift, maker en copyright.
- **Trefwoorden:** voeg trefwoorden toe, gescheiden door komma’s, of
  verwijder er een uit elke afbeelding.
- **Opnamedatum:** verschuif de datum met dagen, uren, minuten en seconden,
  of stel een nieuwe datum en tijd in.
- **Locatie:** **Verwijder locatie** haalt de GPS-positie en de plaatsnamen
  eruit.

Bij meerdere afbeeldingen toont een veld waarvan de waarde verschilt
‘Gemengd’. Laat het leeg om de eigen waarde van elk bestand te behouden.
Alleen velden die je wijzigt, worden geschreven.

Metagegevens worden in het bestand geschreven zonder het beeld opnieuw te
coderen. Camera-RAW-bestanden, en formaten die minivu niet kan herschrijven,
krijgen in plaats daarvan een XMP-sidecar: een klein bestand met dezelfde
naam naast de foto, dat andere apps ook lezen.

## Herstel

Met **Wijzig > Herstel** en **Opnieuw** ga je terug en vooruit door je
bewerkingen, tot 50 stappen. Herstellen kost geen extra geheugen, dus ga zo
vaak terug als je wilt. Nadat je hebt bewaard, begint de herstelgeschiedenis
opnieuw.

## Bewaar

- **Archief > Bewaar** schrijft de bewerkte afbeelding over het origineel, in
  hetzelfde formaat, dezelfde kleurruimte en dezelfde bitdiepte, met de
  metagegevens. minivu vraagt het voordat het origineel wordt vervangen; als
  je hebt aangegeven dat dit niet meer gevraagd moet worden, schakel je
  **Vraag voordat het origineel wordt overschreven** weer in bij
  **Instellingen > Algemeen**.
- minivu kan sommige formaten niet terugschrijven, zoals RAW, WebP, PDF,
  geanimeerde bestanden en bestanden met meerdere pagina’s. Voor die
  bestanden opent Bewaar het venster Bewaar als.
- **Archief > Bewaar als…** bewaart een nieuw bestand. Kies het formaat (JPEG,
  PNG, HEIC, AVIF als je Mac het kan schrijven, TIFF, BMP, GIF, TGA, JPEG
  2000 of ICO) en de opties ervan: kwaliteit, kleurprofiel, metagegevens,
  progressief, 16 of 10 bits per kanaal, TIFF-compressie en de achtergrond
  voor transparantie.
- **Verwijder locatie**, onder Behoud metagegevens, laat de GPS-positie en
  de plaatsnamen weg uit het nieuwe bestand. Deze optie staat in het begin
  aan. Bewaar, en Bewaar als over het originele bestand, behouden de locatie
  altijd. Het paneel toont de bestandsgrootte die de opties opleveren, en
  kan het origineel en het gecomprimeerde resultaat naast elkaar vergelijken
  op 100, 200 of 400%. Opties worden per formaat onthouden.
- **Archief > Zet terug naar bewaarde versie** gooit je niet-bewaarde
  bewerkingen weg.
- **Archief > Bewaar als voorinstelling…** bewaart de bewerkingen als
  voorinstelling, zodat **Gereedschap > Batchconversie…** ze op veel
  afbeeldingen kan toepassen. Het venster toont de stappen die het kan
  gebruiken en de stappen die het weglaat, met de reden. Zie
  [Gereedschap](help:Tools).
- Als je met niet-bewaarde bewerkingen naar een andere afbeelding gaat,
  teruggaat naar de browser of stopt, vraagt minivu of je ze eerst wilt
  bewaren.

> Als een andere app het bestand wijzigt terwijl je niet-bewaarde bewerkingen
> hebt, vraagt minivu of je je bewerkingen wilt behouden of het bestand
> opnieuw wilt laden. Als je ze behoudt, wordt Bewaar Bewaar als, zodat geen
> van beide versies verloren gaat.

Bij het bewaren blijven JPEG-, HEIC- en AVIF-foto’s met een gain map (extra
gegevens die een HDR-scherm vertellen hoe helder elk deel mag zijn) HDR. Andere
HDR-foto’s worden met standaard dynamisch bereik bewaard, en minivu zegt dat
voordat het bewaart.
