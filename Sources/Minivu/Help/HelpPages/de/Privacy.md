# Datenschutz

## Kein Netzwerk

minivu stellt nie eine Verbindung zum Internet her. Es läuft in der
App-Sandbox ohne die Netzwerkberechtigung, sodass macOS es überhaupt keine
Verbindung öffnen lässt. Es gibt keinen Account, keine Analysen, keine
Absturzberichte und keine Suche nach Updates, und diese Hilfe ist Teil des
Programms.

## Was minivu sehen kann

Die Sandbox beschränkt minivu auf:

- deinen Ordner **Bilder**;
- Ordner und Dateien, die du in einem Öffnen- oder Sichern-Fenster wählst,
  auf minivu ablegst oder im Finder mit minivu öffnest;
- Ordner in seiner Seitenleiste und zuletzt verwendete Ordner für „Kopieren
  nach“ und „Bewegen nach“, die es sich mit Lesezeichen merkt, die nur
  dieser Mac und dieses Programm verwenden können;
- seinen eigenen Container, `~/Library/Containers/com.minivu.app`.

Es arbeitet nur mit dem internen Speicher deines Mac, nicht mit
Speicherkarten, externen Laufwerken oder Netzwerkfreigaben.

## Was minivu speichert

In seinem Container, nur auf deinem Mac:

- **Den Katalog** mit Sternebewertungen, Kennzeichnungen und eigenen
  Reihenfolgen.
- **Den Miniaturcache**, den **Einstellungen > Miniaturen > Miniaturcache
  leeren** leert.
- **Einstellungen**, einschließlich der Ordner in der Seitenleiste, zuletzt
  verwendeter Ordner, Diashow-Musik und externer Editoren.

## Was minivu an deinen Dateien ändert

Nur das, worum du bittest:

- **Sichern** schreibt nach einer Rückfrage über das Original. **Sichern
  unter**, Stapelkonvertierung, Kontaktabzug und Montage erstellen neue
  Dateien.
- Drehen und Spiegeln im Browser ändern die Ausrichtungsangabe eines JPEG,
  und „Kommentar bearbeiten“ ändert seinen Kommentar.
- Umbenennen, Bewegen, Kopieren, Neuer Ordner und Stapelumbenennung ändern
  Namen und Ordner und lassen sich widerrufen.
- **In den Papierkorb legen** und das Ersetzen einer Datei mit demselben
  Namen legen Objekte in den Papierkorb. minivu löscht deine Dateien nicht.
- Dateien werden zuerst vollständig geschrieben und dann an ihren Platz
  gelegt, sodass ein unterbrochener Sichervorgang nie eine halbe Datei
  hinterlässt.

minivu schreibt außerdem in **Bilder/minivu Captures** (Bildschirmfotos)
und **Bilder/minivu Wallpapers** (Montagen und Kopien, die für „Als
Schreibtischhintergrund festlegen“ erstellt werden, von denen es die zehn
neuesten behält).

## Berechtigungen

- **Bildschirmaufnahme**, nur wenn du „Bildschirmfoto > Ganzer Bildschirm“
  oder „Auswahl“ verwendest. Du kannst sie unter „Systemeinstellungen“ >
  „Datenschutz & Sicherheit“ deaktivieren.
- **Drucken** über das Standard-Druckfenster.

Die Rote-Augen-Erkennung findet Gesichter mit dem Vision-Framework von
Apple, auf deinem Mac.
