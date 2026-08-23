# Send to reMarkable — Mac-App

Menüleisten-App, die Ordner überwacht und alles darin in die reMarkable-Cloud
lädt. Kein Abo, kein Root, kein Python: die App enthält die komplette Logik,
extern aufgerufen werden nur `rmapi` (Upload), LibreOffice, Calibre und `sips`
(Konvertierung).

## Bauen

```bash
./build.sh
```

Erzeugt `SendToReMarkable.app` (SwiftPM, ad-hoc signiert). Danach entweder
direkt starten oder nach `/Applications` kopieren:

```bash
cp -R SendToReMarkable.app /Applications/
```

Für „Beim Anmelden starten" sollte die App in `/Applications` liegen — macOS
registriert Anmeldeobjekte sonst je nach Ablageort nicht zuverlässig.

## Erste Schritte

1. App starten — Papierflieger-Symbol in der Menüleiste
2. **Einstellungen → Allgemein → Installieren**: lädt das aktuelle
   [rmapi](https://github.com/ddvk/rmapi)-Release nach
   `~/Library/Application Support/SendToReMarkable/bin/`
3. **Koppeln …**: öffnet my.remarkable.com, 8-stelligen Code eintragen. Der
   Token landet in `~/.rmapi` — dieselbe Datei, die auch das CLI benutzt
4. Fertig. Alles, was in `~/reMarkable Inbox` landet, geht hoch

## Was die App kann

**Menüleiste** — der Vogel als Template-Symbol: macOS färbt ihn passend zur
Menüleiste ein, hell auf dunkel und umgekehrt. Ist die Überwachung aus, wird er
blass dargestellt. Dazu Status auf einen Blick, Überwachung an/aus, „Jetzt prüfen",
Watch-Ordner im Finder öffnen. **Dateien lassen sich direkt auf das Symbol in
der Menüleiste ziehen** — das Symbol hebt sich hervor, sobald etwas darüber
schwebt. (Ein Drop-Bereich *im* aufgeklappten Menü wäre nutzlos: das Panel
schließt sich, sobald man die Datei anfasst.)

**Ordner** — beliebig viele Quellen, jede einzeln abschaltbar, mit:

| Einstellung | Bedeutung |
|---|---|
| Zielordner | Wohin in der Cloud, z. B. `/Inbox` |
| Unterordner spiegeln | `Inbox/Zeitungen/x.pdf` → `/Inbox/Zeitungen` (wird angelegt) |
| Nach dem Upload | Unberührt liegen lassen (Standard) **oder** nach `Uploaded/` verschieben |
| Dateimuster | z. B. `Zeitung_*.pdf, *.epub` |
| Nur neuere Dateien | Altbestand beim ersten Lauf überspringen |
| Wartezeit | Schutz vor halb geschriebenen Dateien |
| Umbenennen | Regex → Titel, z. B. `^BMP_\d{4}_(\d{2})(\d{2})(\d{4})$` → `Zeitung \3-\2-\1` |

Neue Ordner starten im Modus **„unberührt liegen lassen"**: nichts wird
verschoben oder gelöscht, und es werden keine Unterordner angelegt — fremde
Archive bleiben so, wie ihr Besitzer sie hinterlassen hat. Ein Merkzettel
(`seen.json`) hält fest, was schon oben war.

`Uploaded/` und `Failed/` gibt es nur, wo „nach Uploaded verschieben"
eingeschaltet ist — voreingestellt ist das allein beim mitgelieferten
Haupt-Watch-Ordner `~/reMarkable Inbox`. Dort ist es sinnvoll: der Ordner ist
eine Ablage, kein Archiv.

Ohne `Failed/` bliebe eine defekte Datei liegen und würde alle fünf Minuten
erneut scheitern. Deshalb landen dauerhafte Fehler — nicht unterstütztes
Format, gescheiterte Konvertierung, zu groß — im Merkzettel und werden nicht
wiederholt. Netz- und rmapi-Fehler zählen bewusst nicht dazu, die dürfen es
beim nächsten Lauf wieder versuchen. Der Abschnitt **Zurzeit** zeigt
je Ordner, was gerade hochginge — und wenn nichts ansteht, warum nicht: zu
alt, schon erledigt, passt nicht zum Muster. Dort lässt sich der Merkzettel
auch zurücksetzen, damit alles noch einmal hochgeht.

Wird ein Ordner aus der Liste entfernt, verschwindet sein Merkzettel mit ihm —
ein später neu angelegter Ordner desselben Pfads fängt also bei null an.

**Allgemein** — Anmeldeobjekt, Benachrichtigungen, Größenlimit, Aufräumen von
`Uploaded/` nach X Tagen, Pfade zu LibreOffice und Calibre mit Statusanzeige.

Neben der installierten rmapi-Version steht, was GitHub gerade anbietet:
`aktuell`, oder orange `→ v0.0.36`, wenn es etwas Neueres gibt. Geprüft wird
beim Start, beim Öffnen der Einstellungen und einmal täglich — heruntergeladen
wird nichts von allein, das macht erst **Aktualisieren**.

**Protokoll** — mitlaufendes Log, auch als Datei unter
`~/Library/Logs/SendToReMarkable.log`.

## Formate

reMarkable kann nur PDF und EPUB — alles andere wird vorher konvertiert:

| Eingabe | Konverter | Ergebnis |
|---|---|---|
| `.pdf` `.epub` | — | direkt |
| `.doc(x)` `.rtf` `.odt` `.xls(x)` `.ppt(x)` `.csv` `.ods` `.odp` | LibreOffice headless | PDF |
| `.mobi` `.azw3` `.fb2` `.html` `.txt` `.md` | Calibre `ebook-convert` | EPUB |
| `.jpg` `.png` `.heic` `.tiff` `.webp` | `sips` | PDF |

Übersprungen werden versteckte Dateien, halbfertige Downloads (`.part`,
`.crdownload`) und Zwischenstände wie `datei.tmp.pdf`.

## Wo was liegt

```
~/Library/Application Support/SendToReMarkable/
    settings.json      Einstellungen
    seen.json          Merkzettel für „unberührt liegen lassen"
    bin/rmapi          das Upload-Werkzeug
~/.rmapi               Kopplungs-Token (geteilt mit dem CLI)
~/Library/Logs/SendToReMarkable.log
~/reMarkable Inbox/    Standard-Watch-Ordner, mit Uploaded/ und Failed/
```

## Aufbau

```
Resources/
    AppIcon.icns         App-Icon (Finder, Anmeldeobjekte)
    MenuBarIcon.png      Menüleisten-Symbol, freigestellt und auf Höhe gebracht
Tools/
    make-menubar-icon.swift   erzeugt MenuBarIcon.png aus einer Vorlage
Sources/SendToReMarkable/
    Support.swift        Pfade, Log, Prozessaufrufe, Benachrichtigungen
    Settings.swift       Modell und Speicherung
    RmapiClient.swift    Installation, Kopplung, mkdir/ls/put
    Converter.swift      LibreOffice, Calibre, sips
    UploadEngine.swift   Einsammeln, Konvertieren, Hochladen, Archivieren
    Watching.swift       FSEvents, Anmeldeobjekt, Koordination
    AppMain.swift        App-Einstieg und Menüleiste
    SettingsWindow.swift Reiter „Allgemein", Kopplung
    FoldersTab.swift     Reiter „Ordner" und „Protokoll"
```

Uploads laufen auf einer seriellen Queue — nie zwei gleichzeitig. FSEvents
meldet Änderungen gebündelt (1,5 s), zusätzlich prüft ein Zeitgeber alle fünf
Minuten nach, falls ein Ereignis verlorengeht.

## Symbole austauschen

`Resources/AppIcon.icns` ersetzen — `build.sh` legt es ins Bundle und trägt es
in die Info.plist ein. Für die Menüleiste eine einfarbige Vorlage durch das
Werkzeug schicken; es schneidet den Rand weg, skaliert auf Höhe und übersetzt
Schwarz in Deckkraft:

```bash
swift Tools/make-menubar-icon.swift vorlage.png Resources/MenuBarIcon.png 44
```

## Debug-Schalter

Zwei Umgebungsvariablen beim Start, praktisch zum Nachschauen ohne Klicken:

```bash
S2R_OPEN_MENU=1 ./SendToReMarkable.app/Contents/MacOS/SendToReMarkable   # Menü aufklappen
S2R_TAB=ordner  ./SendToReMarkable.app/Contents/MacOS/SendToReMarkable   # Reiter vorwählen
```

## Grenzen

* Läuft nur, solange die App läuft — also „Beim Anmelden starten" aktivieren.
* Die reMarkable-Cloud-API ist **inoffiziell**. Wenn Uploads irgendwann
  fehlschlagen, in den Einstellungen auf **Aktualisieren** klicken; das holt
  das neueste rmapi-Release.
* Das Tablet holt sich neue Dokumente erst beim nächsten Sync.
* Ad-hoc signiert: beim ersten Start ggf. über „Systemeinstellungen →
  Datenschutz & Sicherheit" freigeben.
* Wird ein Ordner in `~/Downloads`, `~/Documents` oder auf dem Schreibtisch
  überwacht, fragt macOS einmalig nach Dateizugriff.
