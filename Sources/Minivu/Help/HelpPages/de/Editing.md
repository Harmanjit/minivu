# Bearbeiten

Bearbeitet wird im Betrachter. Deine Änderungen werden als Liste von
Schritten gespeichert und sofort angezeigt, aber auf der Festplatte ändert
sich nichts, bis du sicherst.

## Ein Werkzeug öffnen

Wähle ein Werkzeug aus dem Menü **Bild** oder bewege den Zeiger an den
linken Rand des Betrachters und wähle eines aus dem Bereich. Die
Steuerelemente des Werkzeugs nehmen den Platz des Bereichs ein, und es
bleibt geöffnet, während du arbeitest.

- **Anwenden** fügt die Änderung zum Bild hinzu, **Abbrechen** verwirft sie,
  und **Zurücksetzen** stellt die Steuerelemente auf ihren Ausgangswert
  zurück.
- Im Bereich wenden **Drehen & Spiegeln** und **Farbeffekte** jede Taste
  sofort an; **Fertig** schließt sie.
- In den Werkzeugen, mit denen du zeichnest oder malst, wird das bisher
  Erstellte angewendet, wenn du einen anderen Befehl wählst, statt es zu
  verwerfen.

## Die Werkzeuge

- **Nach links drehen**, **Nach rechts drehen**, **Horizontal spiegeln**,
  **Vertikal spiegeln**.
- **Größe ändern/Neu berechnen …** legt eine neue Größe in Pixeln oder
  Prozent fest, mit oder ohne Beibehaltung des Seitenverhältnisses, mit
  einem von 11 Neuberechnungsfiltern, von Box und Bilinear bis Lanczos 8.
- **Arbeitsfläche …** vergrößert oder verkleinert die Arbeitsfläche um das
  Bild, in Pixeln oder Prozent. Wähle mit dem 3 × 3-Ankerpunkt, wo das Bild
  liegt, und fülle den neuen Raum mit einer Farbe oder lass ihn
  transparent. Eine kleinere Arbeitsfläche beschneidet das Bild.
- **Beschneiden …**: Ziehe das Rechteck oder seine Griffe. Wähle „Frei“, die
  eigene Form des Bilds oder 1:1, 4:3, 3:2, 16:9 bzw. 5:4, im Hoch- oder
  Querformat.
- **Ausrichten …** dreht das Bild um bis zu 45° in beide Richtungen und
  beschneidet die leeren Ecken.
- **Perspektive …** richtet etwas gerade, das schräg fotografiert wurde,
  etwa ein Dokument oder ein Gebäude. Ziehe die vier Eckgriffe auf die Ecken
  von etwas, das rechteckig sein sollte, oder klicke auf **Automatisch**,
  um ein solches Rechteck zu finden. **Ergebnis anzeigen** zeigt eine
  Vorschau der Korrektur.
- **Anpassen > RAW-Anpassungen …**, nur für Kamera-RAW-Dateien:
  Belichtung, Verstärkung (Kontrast), Wiederherstellung der Lichter,
  Weißabgleich und Rauschreduzierung, ausgehend von den Einstellungen der
  Kamera. minivu kann eine RAW-Datei nicht überschreiben, sichere das
  Ergebnis daher mit **Sichern unter …**.
- **Anpassen > Beleuchtung …**: Helligkeit, Kontrast, Gamma, Tiefen und
  Lichter.
- **Anpassen > Farben …**: Farbton, Sättigung, Hellwert, Temperatur und
  Farbstich sowie Rot, Grün und Blau einzeln.
- **Anpassen > Gradationskurven …** und **Tonwertkorrektur …** für eine
  präzise Tonwertsteuerung.
- **Anpassen > Automatisch verbessern** verbessert Tonwerte und Farben mit
  einem Klick. Braucht das Foto nichts, gibt minivu einen Warnton aus.
- **Anpassen > Scharfzeichnen …**, **Weichzeichnen …** und
  **Rauschreduzierung …**. Die Rauschreduzierung glättet Körnung und
  erhält Kanten; ihr Regler „Schärfe“ holt Details zurück.
- **Kommentar bearbeiten …** legt den in einer JPEG-Datei gespeicherten
  Kommentar fest. Er wird in die Datei geschrieben, wenn du im
  Kommentareditor auf „Sichern“ klickst.
- **Metadaten bearbeiten …** (**⌘I**) ändert die Angaben der Datei. Siehe
  „Metadaten“ unten.

Zu Effekten, Zeichnen und Retusche siehe
[Effekte & Retusche](help:Effects).

## Metadaten

Metadaten sind die Informationen, die mit einem Foto gespeichert sind: wer
es aufgenommen hat, wann, wo, sowie ein Titel oder Schlagwörter. **Bild >
Metadaten bearbeiten …** (**⌘I**) bearbeitet sie für das angezeigte Bild
oder für alle im Browser ausgewählten Bilder.

- **Beschreibung:** Titel, Bildunterschrift, Urheber und Copyright.
- **Schlagwörter:** Füge Schlagwörter hinzu, durch Kommas getrennt, oder
  entferne eines aus allen Bildern.
- **Aufnahmedatum:** Verschiebe das Datum um Tage, Stunden, Minuten und
  Sekunden, oder lege ein neues Datum und eine neue Uhrzeit fest.
- **Ort:** **Ort entfernen** entfernt die GPS-Position und die Ortsnamen.

Bei mehreren Bildern zeigt ein Feld, dessen Wert sich unterscheidet,
„Gemischt“ an. Lass es leer, um den eigenen Wert jeder Datei zu behalten.
Nur Felder, die du änderst, werden geschrieben.

Metadaten werden in die Datei geschrieben, ohne das Bild neu zu codieren.
Kamera-RAW-Dateien und Formate, die minivu nicht neu schreiben kann,
erhalten stattdessen eine XMP-Filialdatei: eine kleine Datei mit demselben
Namen neben dem Foto, die auch andere Programme lesen.

## Widerrufen

**Bearbeiten > Widerrufen** und **Wiederholen** gehen in deinen
Bearbeitungen zurück und vor, bis zu 50 Schritte. Widerrufen kostet keinen
zusätzlichen Arbeitsspeicher, du kannst also so oft zurückgehen, wie du
möchtest. Nach dem Sichern beginnt der Widerrufverlauf von vorne.

## Sichern

- **Ablage > Sichern** schreibt das bearbeitete Bild über das Original, im
  selben Format, Farbraum und in derselben Bittiefe, mit seinen Metadaten.
  minivu fragt, bevor das Original ersetzt wird; wenn du festgelegt hast,
  nicht mehr gefragt zu werden, aktiviere **Vor dem Überschreiben des
  Originals fragen** wieder unter **Einstellungen > Allgemein**.
- Manche Formate kann minivu nicht zurückschreiben, etwa RAW, WebP, PDF
  sowie animierte und mehrseitige Dateien. Bei diesen öffnet „Sichern“ das
  Fenster „Sichern unter“.
- **Ablage > Sichern unter …** sichert eine neue Datei. Wähle das Format
  (JPEG, PNG, HEIC, AVIF, sofern dein Mac es schreiben kann, TIFF, BMP,
  GIF, TGA, JPEG 2000 oder ICO) und seine Optionen: Qualität, Farbprofil,
  Metadaten, progressiv, 16 oder 10 Bit pro Kanal, TIFF-Komprimierung und
  den Hintergrund für Transparenz.
- **Ort entfernen** unter „Metadaten beibehalten“ lässt die GPS-Position
  und die Ortsnamen in der neuen Datei weg. Die Option ist anfangs
  aktiviert. „Sichern“ und „Sichern unter“ über die Originaldatei behalten
  den Ort immer. Das Fenster zeigt die Dateigröße an, die sich mit den
  Optionen ergibt, und kann einen Vergleich von Original und komprimiertem
  Ergebnis nebeneinander bei 100, 200 oder 400 % öffnen. Die Optionen werden für jedes Format gespeichert.
- **Ablage > Auf gesicherte Version zurücksetzen** verwirft deine nicht
  gesicherten Bearbeitungen.
- **Ablage > Bearbeitungen als Vorgabe sichern …** behält die
  Bearbeitungen als Vorgabe, sodass **Werkzeuge > Stapelkonvertierung …**
  sie auf viele Bilder anwenden kann. Das Fenster listet die Schritte auf,
  die es verwenden kann, und die, die es weglässt, mit dem Grund. Siehe
  [Werkzeuge](help:Tools).
- Wenn du mit nicht gesicherten Bearbeitungen zu einem anderen Bild
  wechselst, zum Browser zurückkehrst oder das Programm beendest, fragt
  minivu, ob sie zuerst gesichert werden sollen.

> Ändert ein anderes Programm die Datei, während du nicht gesicherte
> Bearbeitungen hast, fragt minivu, ob du deine Bearbeitungen behalten oder
> die Datei neu laden möchtest. Wenn du sie behältst, wird aus „Sichern“
> „Sichern unter“, sodass keine Version verloren geht.

Beim Sichern bleiben JPEG-, HEIC- und AVIF-Fotos mit einer Gain-Map
(Zusatzdaten, die einem HDR-Bildschirm sagen, wie hell jeder Teil sein darf) in
HDR. Andere HDR-Fotos werden mit Standard-Dynamikumfang gesichert, und minivu
sagt dir das vorher.
