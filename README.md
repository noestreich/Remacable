# Remacable

Dateien aufs reMarkable schieben, ohne Abo und ohne Root.

Leg eine Datei in den Watch-Ordner — sie landet in der reMarkable-Cloud und
synct aufs Tablet. Das Tablet bleibt unangetastet: der Upload passiert
cloudseitig ueber dieselbe API, die auch die offizielle Desktop-App benutzt.
Kein reMarkable Connect, kein Dropbox-Umweg, kein Mailserver.

Es gibt zwei Fassungen mit demselben Funktionsumfang:

| | Wofuer |
|---|---|
| **[SendToReMarkable.app](SendToReMarkable/README.md)** | Die Mac-App. Menueleiste, Einstellungsfenster, Installation und Kopplung per Klick. **Der normale Weg.** |
| **send2rm.py** (unten) | Die Skript-Fassung: CLI, Droplet und launchd-Agent. Fuer Automatisierung ohne Oberflaeche oder spaeter auf einem Server. |

Beide benutzen dasselbe `rmapi`-Werkzeug und dieselbe Kopplung in `~/.rmapi` —
aber sie sollten **nicht gleichzeitig denselben Ordner** ueberwachen, sonst
geht alles doppelt hoch. Die App erkennt einen laufenden launchd-Agent der
Skript-Fassung und bietet an, ihn abzuschalten.

---

# send2rm — die Skript-Fassung

## Installation

```bash
./install.sh
```

Das Skript laedt [ddvk/rmapi](https://github.com/ddvk/rmapi) (macOS-Binary des
letzten Releases) nach `bin/`, baut das Droplet, legt die Watch-Folder an und
registriert den launchd-Agent mit `WatchPaths` auf allen Quellen.

Danach einmalig koppeln:

1. [my.remarkable.com/device/desktop/connect](https://my.remarkable.com/device/desktop/connect) oeffnen, 8-stelligen Code holen
2. `./bin/rmapi` starten, Code eingeben, mit `exit` verlassen
3. `python3 send2rm.py --check`

Der Token liegt danach in `~/.rmapi` und gilt dauerhaft. Die Kopplung taucht in
deinem Konto als zusaetzliches Geraet auf und laesst sich dort wieder entziehen.

## Benutzung

| Weg | Wie |
|---|---|
| Watch-Folder | Datei nach `~/reMarkable Inbox` legen |
| Droplet | Datei auf `Send to reMarkable.app` ziehen (ins Dock legen) |
| Terminal | `python3 send2rm.py datei.pdf [--folder /Inbox] [--title "Titel"]` |
| Fremdordner | Quelle in `config.toml` eintragen (siehe unten) |

Der Agent laeuft, sobald sich in einer Quelle etwas tut, zusaetzlich alle 5
Minuten als Netz gegen verlorene Events. Erfolgreiche Uploads bekommen eine
macOS-Benachrichtigung, Fehler auch.

## Watch-Folder und weitere Quellen

Unterordner werden 1:1 in der Cloud gespiegelt:

```
~/reMarkable Inbox/bericht.pdf            ->  /Inbox
~/reMarkable Inbox/Zeitungen/mopo.pdf     ->  /Inbox/Zeitungen   (wird angelegt)
```

Nach dem Upload wandert die Datei nach `Uploaded/` — unter Beibehaltung der
Unterordner — und wird dort nach `cleanup_uploaded_days` (Standard: 30)
geloescht. `keep_uploaded = false` loescht sofort, `cleanup_uploaded_days = 0`
raeumt nie auf.

Uebersprungen werden versteckte Dateien, halbfertige Downloads (`.part`,
`.crdownload`) und Zwischenstaende wie `datei.tmp.pdf`.

`config.toml` erlaubt beliebig viele `[[sources]]`. Fuer Ordner, die jemand
anders verwaltet, gibt es den nicht-invasiven Modus:

```toml
[[sources]]
path = "~/Downloads"
patterns = ["Zeitung_*.pdf"]
target_folder = "/Zeitungen"
move = false            # nichts wird verschoben oder geloescht
max_age_days = 2        # aelteres Archiv ignorieren
stable_wait = 15        # warten, bis nachtraegliche Komprimierung durch ist
```

Dabei merkt sich `~/Library/Application Support/send2rm/seen.json` Pfad,
Groesse und mtime. Aendert sich die Datei, geht sie erneut hoch.

Optional lassen sich Dateinamen vor dem Upload zu Titeln umschreiben:

```toml
[[sources.rename]]                              # aus "BMP_2026_22082026" wird
match = '^BMP_\d{4}_(\d{2})(\d{2})(\d{4})$'     # "Berliner Morgenpost 2026-08-22"
title = 'Berliner Morgenpost \3-\2-\1'
```

## Formate

Das reMarkable kann nur **PDF** und **EPUB**. Alles andere wird vorher
konvertiert:

| Eingabe | Konverter | Ergebnis |
|---|---|---|
| `.pdf` `.epub` | — | direkt |
| `.doc(x)` `.rtf` `.odt` `.xls(x)` `.ppt(x)` `.csv` `.ods` `.odp` | LibreOffice headless | PDF |
| `.mobi` `.azw3` `.fb2` `.html` `.txt` `.md` | Calibre `ebook-convert` | EPUB |
| `.jpg` `.png` `.heic` `.tiff` `.webp` | `sips` | PDF |

LibreOffice laeuft mit eigenem Profil, funktioniert also auch, waehrend
LibreOffice offen ist.

## Betrieb

```bash
python3 send2rm.py --check          # Kopplung und Quellen anzeigen
tail -f ~/Library/Logs/send2rm.log  # Log
launchctl list | grep send2rm       # laeuft der Agent?
./install.sh                        # nach Aenderung an Quellen-Pfaden neu laden
launchctl bootout gui/$UID/com.send2rm.watch   # abschalten
```

Exit-Codes: `0` alles gut, `1` mindestens eine Datei fehlgeschlagen,
`2` Setup kaputt (rmapi fehlt).

## Einen Downloader anbinden

Gilt fuer beide Fassungen — der Watch-Ordner ist derselbe.

Der einfachste Weg: das fremde Skript legt eine **Kopie** in den Watch-Ordner.
Weder an der App noch am Skript ist dafuer etwas zu konfigurieren, und der
Downloader behaelt sein Original.

```python
ZIEL = Path.home() / "reMarkable Inbox" / "Zeitungen"
ZIEL.mkdir(parents=True, exist_ok=True)

# Atomar ablegen: erst unter einem Namen, den der Scanner ignoriert,
# dann umbenennen. Sonst kann der Watcher eine halb kopierte Datei erwischen.
tmp = ZIEL / f".{titel}.pdf.part"
shutil.copy2(pdf_pfad, tmp)
tmp.replace(ZIEL / f"{titel}.pdf")
```

Worauf es ankommt:

* **Erst komprimieren, dann kopieren.** `komprimiere_pdf()` gibt den finalen
  Pfad zurueck — mit dem arbeiten, sonst landet die unkomprimierte Fassung
  oben oder du kollidierst mit Ghostscript.
* **Der Dateiname wird der Titel.** Also gleich `Berliner Morgenpost
  2026-08-22.pdf` nennen; dann braucht es keine `rename`-Regeln.
* **Unterordner waehlen.** `Zeitungen/` landet unter `/Inbox/Zeitungen`. Soll
  es stattdessen `/Zeitungen` auf oberster Ebene sein, eine eigene Quelle mit
  `path = "~/reMarkable Inbox/Zeitungen"` und `target_folder = "/Zeitungen"`
  eintragen und danach `./install.sh` laufen lassen.
* **Kopieren, nicht verschieben** — sonst fehlt dem Downloader seine eigene
  Datei fuer Wiederholungslaeufe und `status.json`.
* **Aufraeumen im Blick behalten.** Die Kopie liegt nach dem Upload in
  `Uploaded/` und verschwindet dort nach 30 Tagen.

Alternativ direkt aufrufen — dann Interpreter **absolut** angeben
(`/usr/local/bin/python3`, nicht `env python3`: unter launchd waere das
`/usr/bin/python3` 3.9, und `tomllib` gibt es erst ab 3.11):

```python
subprocess.run(
    ["/usr/local/bin/python3", "/Pfad/zu/Remacable/send2rm.py",
     str(pdf_pfad), "--folder", "/Zeitungen", "--title", f"{zeitung['name']} {heute:%Y-%m-%d}"],
    capture_output=True, text=True, timeout=600, check=True,
)
```

Der Aufruf wartet, falls gerade ein Scan laeuft, und liefert `0` / `1` zurueck.

## Grenzen

* Die reMarkable-Cloud-API ist **inoffiziell**. reMarkable hat das
  Sync-Protokoll schon einmal umgestellt; wenn Uploads irgendwann fehlschlagen,
  hilft meist `./install.sh` (holt das aktuelle rmapi-Release).
* Das Tablet holt sich das Dokument erst beim naechsten Sync — also wenn es an
  und im WLAN ist.
* Laeuft nur, solange dieser Mac laeuft. Fuer 24/7 muesste derselbe Kern auf
  einen kleinen Server, dann mit Syncthing- oder Nextcloud-Ordner als Quelle.
