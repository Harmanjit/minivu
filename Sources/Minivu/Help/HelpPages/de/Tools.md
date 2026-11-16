# Werkzeuge

Das Menü **Werkzeuge** wirkt auf das, was du gerade ansiehst. Im Browser
verwendet ein Werkzeug die ausgewählten Bilder oder, wenn nichts ausgewählt
ist, alle angezeigten Bilder. Im Betrachter verwendet es das Bild auf dem
Bildschirm. Werkzeuge, die Bilder erstellen, und die Diashow überspringen
Videos.

## Diashow

**Werkzeuge > Diashow starten** spielt die Bilder im Vollbildmodus ab, mit HDR
wie im Betrachter. Die Diashow öffnet sich auf dem Display, das
**Vollbild-Betrachter öffnet auf** unter **Einstellungen > Betrachter**
festlegt. Wird mit einem einzelnen ausgewählten Bild gestartet, wird der ganze
Ordner ab diesem Bild abgespielt.

- Die **Leertaste** hält an und setzt fort, die Pfeiltasten blättern, und
  **Esc** beendet die Diashow. Bewege den Zeiger, um die Steuerleiste
  einzublenden.
- Lege unter **Einstellungen > Diashow** die Anzeigedauer pro Dia, die
  Reihenfolge (der Reihe nach oder gemischt), ob am Ende von vorne begonnen
  wird, Untertitel und einen von acht Übergängen oder einen zufälligen fest.
- Dort kannst du auch Musik hinzufügen: MP3-, AAC-, WAV- oder AIFF-Titel
  oder Ordner damit. Die Musik wird am Ende der Diashow ausgeblendet.

### Als Video exportieren

**Werkzeuge > Diashow-Video exportieren …** sichert die Diashow als
Videodatei, die du überall abspielen oder versenden kannst.

- Wähle die Auflösung (720p, 1080p, 4K oder die Größe deines Bildschirms),
  die Bildrate, den Codec (H.264 oder HEVC für kleinere Dateien), die
  Qualität sowie MP4 oder MOV.
- Das Video verwendet die Anzeigedauer, den Übergang, die Reihenfolge, die
  Untertitel und die Musik aus **Einstellungen > Diashow**. Jedes Bild
  erscheint einmal.
- Das Video hat Standard-Dynamikumfang: HDR-Fotos werden per Tone-Mapping
  umgesetzt.
- „Exportieren …“ fragt, wo es gesichert werden soll. Danach folgt ein
  Fortschrittsbalken mit „Abbrechen“.

## Stapelkonvertierung

**Werkzeuge > Stapelkonvertierung …** sichert Kopien vieler Bilder in einem
anderen Format.

- Wähle das Format und seine Optionen wie bei „Sichern unter“ sowie ein
  Ziel: einen Ordner oder neben den Originalen. **Ort entfernen** lässt die
  GPS-Position in den Kopien weg; die Option ist anfangs aktiviert.
- Optional kannst du die Kopien nach einem Muster umbenennen, ihre Größe
  ändern (nach langer Seite, Breite, Höhe oder Prozent), sie drehen oder
  spiegeln und ihre Metadaten beibehalten oder entfernen.
- **Bearbeitungen** listet die Bearbeitungen der gewählten Vorgabe auf, die
  im Betrachter mit **Ablage > Bearbeitungen als Vorgabe sichern …**
  erstellt wurde, und wendet sie auf jedes Bild an. **Wasserzeichen** fügt
  ein Wasserzeichen hinzu. Siehe [Bearbeiten](help:Editing) und
  [Effekte & Retusche](help:Effects).
- **HDR behalten** behält HDR-Fotos in JPEG, HEIC und AVIF als HDR. Dafür
  ist das Farbprofil „Original beibehalten“ oder „Display P3“ und 8 Bit
  nötig; andernfalls werden HDR-Fotos mit Standard-Dynamikumfang
  geschrieben, und das Fenster weist darauf hin.
- **Vorgabe** oben behält alle Einstellungen unter einem Namen, um sie
  erneut zu verwenden.
- Die Konvertierung läuft im Hintergrund mit Fortschrittsbalken und
  „Abbrechen“ und listet alle Dateien auf, die nicht konvertiert werden
  konnten.
- minivu fragt, bevor etwas ersetzt würde, und eine ersetzte Datei wird in
  den Papierkorb gelegt.

**Mehrseitige Dateien** legt fest, was mit PDFs, mehrseitigen TIFFs und
Animationen geschieht: **Nur erste Seite** oder **Jede Seite**. „Jede
Seite“ erstellt bei TIFF und GIF eine Datei mit allen Seiten und bei
anderen Formaten eine Datei pro Seite.

## Stapelumbenennung

**Werkzeuge > Stapelumbenennung …** benennt viele Dateien auf einmal nach
einem Muster aus Text und Platzhaltern um: Originalname, Zähler,
Aufnahmedatum, Änderungsdatum, Pixelgröße und Suffix. Füge Suchen und
Ersetzen sowie eine Groß-/Kleinschreibung hinzu und prüfe die
Vorher-Nachher-Liste, die Namenskonflikte live markiert, bevor sich etwas
ändert. Die gesamte Umbenennung ist ein einziger Schritt von **Bearbeiten >
Widerrufen**. Eine **Vorgabe** behält ein Muster unter einem Namen.

## Seiten und Streifen

- **Werkzeuge > Seiten extrahieren …** sichert jede Seite eines PDF oder
  mehrseitigen TIFF oder jeden Frame einer Animation als eigene Datei.
  Wähle alle Seiten oder einen Bereich und das Format wie bei der
  Stapelkonvertierung. Die Namen verwenden den Platzhalter `{page}`, die
  Seitennummer: „scan-03.png“.
- **Werkzeuge > Mehrseitige Datei erstellen …** fügt die Bilder zu einer
  Datei zusammen: einem mehrseitigen TIFF, einem PDF, einem animierten GIF
  oder, sofern dein Mac es schreiben kann, einem animierten HEIC. Ziehe in
  der Liste, um die Reihenfolge zu ändern.
- **Werkzeuge > Bildstreifen …** fügt die Bilder zu einem Bild zusammen,
  nebeneinander, untereinander oder in einem Raster, mit dem Abstand und
  Hintergrund, den du wählst. Der Streifen wird im Betrachter geöffnet.

## Duplikate suchen

**Werkzeuge > Duplikate suchen …** findet Kopien unter den ausgewählten
Bildern, im Ordner oder im Ordner und seinen Unterordnern.

- **Identische Dateien** findet Dateien mit genau demselben Inhalt.
  **Ähnliche Bilder** findet Bilder, die sich ähneln, etwa verkleinerte
  Kopien, Bearbeitungen und Serienaufnahmen. Bewege den Regler
  **Ähnlichkeit**, um die Suche strenger oder großzügiger zu machen.
- In jeder Gruppe schlägt minivu eine Datei zum Behalten vor: die mit der
  höchsten Auflösung, die größte Datei oder die älteste, wie du wählst.
  **Vorschläge markieren** markiert alle anderen; nichts wird markiert,
  bevor du darum bittest.
- **In den Papierkorb legen …** legt die markierten Dateien nach einer
  Rückfrage in den Papierkorb. **Im Browser zeigen** und **Vergleichen**
  zeigen die gefundenen Dateien an.

## Drucken und Papierformat

**Ablage > Drucken …** verwendet das Standard-Druckfenster mit den
Layoutoptionen von minivu: Bilder pro Seite, Einpassen oder Füllen, Drehen
der Bilder zum Füllen der Zellen, Ränder, Abstand und Untertitel, mit einer
Live-Vorschau. **Ablage > Papierformat …** wählt das Papier aus.

## Kontaktabzug

**Werkzeuge > Kontaktabzug …** ordnet Miniaturen auf Seiten an: Spalten,
Zeilen, Abstand, Untertitel, eine Kopfzeile, Seitengröße und Hintergrund.
Sichere ihn als JPEG, PNG, TIFF oder mehrseitiges PDF.

## Webgalerie

**Werkzeuge > Webgalerie erstellen …** erstellt einen Ordner mit Webseiten,
die die Bilder zeigen: eine Seite mit Miniaturen und eine Seite für jedes
Bild mit Links zum vorherigen und zum nächsten Bild. Öffne ihre Datei
index.html in einem beliebigen Webbrowser, auf deinem Mac oder nachdem du
den Ordner auf eine Website kopiert hast.

- Wähle den Titel, die Größen der Miniaturen und Bilder, die Spalten, ein
  helles, dunkles oder automatisches Design, die Reihenfolge und die
  Untertitel.
- Bilder sind JPEG, HEIC (nur Safari) oder AVIF. Metadaten können
  beibehalten werden, und **Ort entfernen** ist anfangs aktiviert.
  **Originaldateien einbeziehen** fügt für jedes Original einen
  Download-Link hinzu.
- Die Seiten verwenden keine Skripte und laden nichts aus dem Internet.

## Montage-Hintergrundbild und Schreibtischhintergrund

- **Werkzeuge > Montage-Hintergrundbild …** erstellt aus den Bildern eine
  Collage in der Größe deines Displays, als Raster, Mosaik oder verstreute
  Abzüge, und legt sie als Schreibtischhintergrund fest. Montagen werden in
  **Bilder/minivu Wallpapers** gesichert.
- **Werkzeuge > Als Schreibtischhintergrund festlegen** verwendet ein Bild
  unverändert.

## Bildschirmfoto

**Werkzeuge > Bildschirmfoto** nimmt den ganzen Bildschirm, ein Fenster oder
eine von dir aufgezogene Auswahl auf (Loslassen der Maustaste nimmt auf, **Esc**
bricht ab). Aufnahmen werden als PNG-Dateien in **Bilder/minivu Captures**
gesichert und im Betrachter geöffnet.

Für die Aufnahme des ganzen Bildschirms oder einer Auswahl ist die
Berechtigung zur Bildschirmaufnahme erforderlich. macOS fragt beim ersten
Mal danach; du kannst sie später unter **Systemeinstellungen > Datenschutz &
Sicherheit > Bildschirm- & Systemaudioaufnahme** ändern. Für die Auswahl
eines Fensters in der Fensterauswahl des Systems ist keine Berechtigung
nötig.

## Externe Editoren

**Werkzeuge > In externem Editor öffnen** sendet die ausgewählten Bilder
oder das angezeigte Bild an ein anderes Programm. Der erste Editor in der
Liste hat den Kurzbefehl **⌘E**. Wähle **Editorliste bearbeiten …**, um
unter **Einstellungen > Editoren** Programme hinzuzufügen.

Wenn ein Editor eine Datei sichert, zeigt minivu die neue Version an. Hattest
du in minivu nicht gesicherte Bearbeitungen an dieser Datei, fragt minivu,
ob du sie behalten oder die Datei neu laden möchtest.

## Kurzbefehle

minivu fügt der Kurzbefehle-App Aktionen hinzu: **Bilder konvertieren**,
**Bildgröße ändern**, **Bilder umbenennen**, **Bewertung festlegen**,
**Farbetikett festlegen** und **In minivu öffnen**. Suche in den Aktionen der
Kurzbefehle-App nach „minivu“, um sie in deinen eigenen Kurzbefehlen zu
verwenden. Wird ein solcher Kurzbefehl ausgeführt, öffnet er minivu, falls es
nicht geöffnet ist. Die Aktionen funktionieren nur mit Dateien auf dem internen
Speicher deines Mac. **Bilder umbenennen** funktioniert nur in deinem Ordner
„Bilder“ und in Ordnern in der Seitenleiste von minivu. Liegt eine Datei
woanders, benennt die Aktion keine der Dateien um.

Um einen Kurzbefehl im Finder zu verwenden, erstelle einen, der Bilder empfängt,
und aktiviere in seinen Details **Als Schnellaktion verwenden**. Er erscheint
dann im Kontextmenü des Finder unter **Schnellaktionen**.
