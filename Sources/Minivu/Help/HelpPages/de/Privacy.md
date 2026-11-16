# Datenschutz

## Kein Netzwerk

minivu stellt nie eine Verbindung zum Internet her. Es läuft in der
App-Sandbox ohne die Netzwerkberechtigung, sodass macOS es überhaupt keine
Verbindung öffnen lässt. Es gibt keinen Account, keine Analysen, keine
Absturzberichte und keine Suche nach Updates, und diese Hilfe ist Teil des
Programms.

Live Text, „Hintergrund entfernen“, „Motiv kopieren“, die
Rote-Augen-Erkennung, „Automatisch“ in „Perspektive“ und „Ähnliche Bilder“
in „Duplikate suchen“ verwenden das Vision-Framework von Apple, auf deinem
Mac. Nichts wird irgendwohin gesendet.

**Ablage > Teilen …** übergibt die Dateien an den Teilen-Dienst, den du
wählst, etwa AirDrop oder Mail, der sie dann sendet. minivu selbst öffnet
keine Verbindung.

## Was minivu sehen kann

Die Sandbox beschränkt minivu auf:

- deinen Ordner **Bilder**;
- Ordner und Dateien, die du in einem Öffnen- oder Sichern-Fenster wählst,
  auf minivu ablegst oder im Finder mit minivu öffnest;
- Ordner in seiner Seitenleiste und zuletzt verwendete Ordner für „Kopieren
  nach“ und „Bewegen nach“, die es sich mit Lesezeichen merkt, die nur
  dieser Mac und dieses Programm verwenden können;
- ein für ein Wasserzeichen gewähltes Bild, das es sich mit einem
  schreibgeschützten Lesezeichen merkt;
- seinen eigenen Container, `~/Library/Containers/com.minivu.app`.

Es arbeitet nur mit dem internen Speicher deines Mac, nicht mit
Speicherkarten, externen Laufwerken oder Netzwerkfreigaben.

## Was minivu speichert

In seinem Container, nur auf deinem Mac:

- **Den Katalog** mit Sternebewertungen, Kennzeichnungen, eigenen
  Reihenfolgen, Sammlungen, intelligenten Ordnern und den für Filter und
  Suchen gelesenen Fotodetails.
- **Den Miniaturcache** mit den Fingerabdrücken, die „Duplikate suchen“
  erstellt, den **Einstellungen > Miniaturen > Miniaturcache leeren** leert.
- **Einstellungen**, einschließlich der Ordner in der Seitenleiste, zuletzt
  verwendeter Ordner, Diashow-Musik, externer Editoren und Vorgaben.

Suchen lesen nur Ordner, die minivu sehen darf, auf deinem Mac. minivu
fragt Spotlight nicht ab.

## Was minivu an deinen Dateien ändert

Nur das, worum du bittest:

- **Sichern** schreibt nach einer Rückfrage über das Original. **Sichern
  unter**, Stapelkonvertierung, „Seiten extrahieren“, „Mehrseitige Datei
  erstellen“, Bildstreifen, Kontaktabzug, Montage, „Diashow-Video
  exportieren“ und „Webgalerie erstellen“ erstellen neue Dateien.
- Drehen und Spiegeln im Browser ändern die Ausrichtungsangabe eines JPEG,
  und „Kommentar bearbeiten“ ändert seinen Kommentar.
- **Metadaten bearbeiten** schreibt die Angaben, die du änderst, in die
  Datei oder in eine XMP-Filialdatei daneben.
- **Bild > Farbetikett** legt den farbigen Finder-Tag der Datei fest.
  Sterne und Kennzeichnungen werden nur dann in Dateien geschrieben, wenn
  du **Bewertungen in Dateien schreiben (XMP)** in den Einstellungen
  aktivierst.
- Eine minivu-Aktion in der Kurzbefehle-App kann Dateien, die minivu
  ändern darf, konvertieren, ihre Größe ändern, sie umbenennen, bewerten
  oder mit einem Farbetikett versehen.
- Umbenennen, Bewegen, Kopieren, Neuer Ordner und Stapelumbenennung ändern
  Namen und Ordner und lassen sich widerrufen.
- **In den Papierkorb legen** und das Ersetzen einer Datei mit demselben
  Namen legen Objekte in den Papierkorb. minivu löscht deine Dateien nicht.
- Dateien werden zuerst vollständig geschrieben und dann an ihren Platz
  gelegt, sodass ein unterbrochener Sichervorgang nie eine halbe Datei
  hinterlässt.

**Ort.** „Sichern unter“, Stapelkonvertierung, „Webgalerie erstellen“ und
die Kurzbefehle-Aktionen lassen die GPS-Position und die Ortsnamen weg,
sofern du **Ort entfernen** nicht deaktivierst. „Sichern“ behält alles,
auch den Ort. Der Ort eines Videos wird angezeigt, aber nie entfernt.

minivu schreibt außerdem in **Bilder/minivu Captures** (Bildschirmfotos)
und **Bilder/minivu Wallpapers** (Montagen und Kopien, die für „Als
Schreibtischhintergrund festlegen“ erstellt werden, von denen es die zehn
neuesten behält).

## Berechtigungen

- **Bildschirmaufnahme**, nur wenn du „Bildschirmfoto > Ganzer Bildschirm“
  oder „Auswahl“ verwendest. Du kannst sie unter „Systemeinstellungen“ >
  „Datenschutz & Sicherheit“ deaktivieren.
- **Drucken** über das Standard-Druckfenster.
