#!/usr/bin/env python3
"""send2rm — Dateien ins reMarkable-Cloud-Konto hochladen.

Betriebsarten:
  send2rm.py DATEI [DATEI ...]   einzelne Dateien hochladen (Droplet, Terminal, Hook)
  send2rm.py --scan              alle konfigurierten Quellen abarbeiten (launchd)
  send2rm.py --check             Setup und Kopplung pruefen

Quellen (config.toml, [[sources]]) kennen zwei Modi:
  move = true    Watch-Folder: Datei wandert nach Uploaded/ bzw. Failed/
  move = false   Fremdordner: Datei bleibt unberuehrt, ein State-File merkt sich,
                 was schon hochgeladen wurde

Nicht unterstuetzte Formate werden vorher konvertiert:
  Office/RTF          -> PDF   (LibreOffice headless)
  Text/HTML/MOBI/AZW3 -> EPUB  (Calibre ebook-convert)
  Bilder              -> PDF   (sips)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent

DEFAULTS = {
    "inbox": "~/reMarkable Inbox",
    "rmapi": str(BASE / "bin" / "rmapi"),
    "rmapi_config": "~/.rmapi",
    "target_folder": "/Inbox",
    "soffice": "/Applications/LibreOffice.app/Contents/MacOS/soffice",
    "ebook_convert": "/Applications/calibre.app/Contents/MacOS/ebook-convert",
    "log_file": "~/Library/Logs/send2rm.log",
    "state_file": "~/Library/Application Support/send2rm/seen.json",
    "notify": True,
    "keep_uploaded": True,
    "cleanup_uploaded_days": 30,
    "stable_wait": 2.0,
    "max_mb": 200,
}

PASSTHROUGH = {".pdf", ".epub"}
OFFICE = {".doc", ".docx", ".rtf", ".odt", ".ott", ".xls", ".xlsx", ".csv",
          ".ods", ".ppt", ".pptx", ".odp"}
EBOOK = {".mobi", ".azw", ".azw3", ".fb2", ".lit", ".pdb", ".htm", ".html",
         ".txt", ".md", ".markdown"}
IMAGE = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".gif",
         ".bmp", ".webp"}
# Halbfertige Downloads und Zwischenstaende nie anfassen — greift auch bei
# mehrteiligen Endungen wie "BMP_2026_22082026.tmp.pdf"
SKIP_SUFFIX = {".part", ".crdownload", ".download", ".tmp", ".partial"}
ARCHIVE_DIRS = {"Uploaded", "Failed"}

log = logging.getLogger("send2rm")


# --------------------------------------------------------------------------- setup

def load_config() -> dict:
    cfg = dict(DEFAULTS)
    path = Path(os.environ.get("SEND2RM_CONFIG", BASE / "config.toml"))
    if path.exists():
        with path.open("rb") as fh:
            cfg.update(tomllib.load(fh))
    for key in ("inbox", "rmapi", "rmapi_config", "soffice", "ebook_convert",
                "log_file", "state_file"):
        cfg[key] = str(Path(os.path.expanduser(cfg[key])))
    return cfg


def get_sources(cfg: dict) -> list[dict]:
    """Normalisiert [[sources]]; ohne Konfiguration bleibt es beim Watch-Folder."""
    raw = cfg.get("sources") or [{"path": cfg["inbox"], "move": True}]
    sources = []
    for entry in raw:
        sources.append({
            "path": Path(os.path.expanduser(entry["path"])),
            "target_folder": entry.get("target_folder", cfg["target_folder"]),
            "move": bool(entry.get("move", True)),
            "patterns": entry.get("patterns") or ["*"],
            "subfolders": bool(entry.get("subfolders", True)),
            "rename": entry.get("rename") or [],
            "stable_wait": float(entry.get("stable_wait", cfg["stable_wait"])),
            "max_age_days": float(entry.get("max_age_days", 0)),
        })
    return sources


def setup_logging(cfg: dict) -> None:
    log_file = Path(cfg["log_file"])
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        handlers=[logging.FileHandler(log_file), logging.StreamHandler(sys.stderr)],
    )


def notify(cfg: dict, title: str, text: str) -> None:
    if not cfg.get("notify"):
        return
    script = f"display notification {applescript_str(text)} with title {applescript_str(title)}"
    subprocess.run(["osascript", "-e", script], capture_output=True)


def applescript_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


# --------------------------------------------------------------------------- state

def load_state(cfg: dict) -> dict:
    path = Path(cfg["state_file"])
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        log.warning("State-Datei unlesbar, starte neu: %s", path)
        return {}


def save_state(cfg: dict, state: dict) -> None:
    path = Path(cfg["state_file"])
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    tmp.replace(path)


def fingerprint(path: Path) -> str:
    st = path.stat()
    return f"{st.st_size}:{int(st.st_mtime)}"


def already_sent(state: dict, path: Path) -> bool:
    return state.get(str(path)) == fingerprint(path)


def prune_state(state: dict) -> dict:
    """Eintraege verschwundener Dateien entfernen, damit das File nicht waechst."""
    return {k: v for k, v in state.items() if Path(k).exists()}


# --------------------------------------------------------------------------- rmapi

def rmapi(cfg: dict, *args: str, timeout: int = 600) -> subprocess.CompletedProcess:
    env = dict(os.environ, RMAPI_CONFIG=cfg["rmapi_config"])
    return subprocess.run(
        [cfg["rmapi"], *args], capture_output=True, text=True, env=env, timeout=timeout
    )


def ensure_folder(cfg: dict, folder: str) -> None:
    """Zielordner anlegen, Ebene fuer Ebene.

    Existiert ein Ordner schon, meldet rmapi einen Fehler — den ignorieren wir.
    """
    path = ""
    for part in [p for p in folder.strip("/").split("/") if p]:
        path += "/" + part
        res = rmapi(cfg, "mkdir", path, timeout=60)
        if res.returncode != 0 and "exist" not in (res.stderr + res.stdout).lower():
            log.debug("mkdir %s: %s", path, res.stderr.strip())


def existing_names(cfg: dict, folder: str) -> set[str]:
    """Namen im Zielordner — Kollisionen vorher abfangen, rmapi put schlaegt sonst fehl."""
    res = rmapi(cfg, "ls", folder, timeout=120)
    if res.returncode != 0:
        return set()
    names = set()
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            names.add(parts[-1].strip())
    return names


def unique_title(stem: str, taken: set[str]) -> str:
    if stem not in taken:
        taken.add(stem)
        return stem
    for n in range(2, 100):
        candidate = f"{stem} ({n})"
        if candidate not in taken:
            taken.add(candidate)
            return candidate
    return f"{stem} {datetime.now():%Y-%m-%d %H%M%S}"


def apply_rename(stem: str, rules: list[dict]) -> str:
    """Erste passende Regel gewinnt; 'title' darf \\1, \\2 ... verwenden."""
    for rule in rules:
        pattern = rule.get("match")
        title = rule.get("title")
        if not pattern or not title:
            continue
        try:
            if re.search(pattern, stem):
                return re.sub(pattern, title, stem)
        except re.error as exc:
            log.warning("Ungueltige rename-Regel %r: %s", pattern, exc)
    return stem


# --------------------------------------------------------------------------- konvertierung

def run(cmd: list[str], timeout: int = 900) -> subprocess.CompletedProcess:
    log.debug("run: %s", " ".join(cmd))
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def convert(src: Path, tmp: Path, cfg: dict) -> Path:
    """Gibt die hochzuladende Datei zurueck (PDF oder EPUB)."""
    ext = src.suffix.lower()

    if ext in PASSTHROUGH:
        return src

    if ext in OFFICE:
        soffice = cfg["soffice"]
        if not Path(soffice).exists():
            raise RuntimeError("LibreOffice nicht gefunden — fuer Office-Dateien noetig")
        # Eigenes User-Profil, sonst scheitert der Aufruf, solange LibreOffice offen ist
        profile = tmp / "loprofile"
        res = run([soffice, f"-env:UserInstallation=file://{profile}", "--headless",
                   "--convert-to", "pdf", "--outdir", str(tmp), str(src)])
        out = tmp / (src.stem + ".pdf")
        if not out.exists():
            raise RuntimeError(f"LibreOffice-Konvertierung fehlgeschlagen: {res.stderr.strip()[:200]}")
        return out

    if ext in EBOOK:
        conv = cfg["ebook_convert"]
        if not Path(conv).exists():
            raise RuntimeError("Calibre (ebook-convert) nicht gefunden")
        out = tmp / (src.stem + ".epub")
        res = run([conv, str(src), str(out)])
        if not out.exists():
            raise RuntimeError(f"Calibre-Konvertierung fehlgeschlagen: {res.stderr.strip()[:200]}")
        return out

    if ext in IMAGE:
        out = tmp / (src.stem + ".pdf")
        res = run(["sips", "-s", "format", "pdf", str(src), "--out", str(out)])
        if not out.exists():
            raise RuntimeError(f"Bildkonvertierung fehlgeschlagen: {res.stderr.strip()[:200]}")
        return out

    raise RuntimeError(f"Format {ext or '(ohne Endung)'} wird nicht unterstuetzt")


# --------------------------------------------------------------------------- upload

def send_file(src: Path, cfg: dict, folder: str, taken: set[str],
              rename: list[dict] | None = None, forced_title: str | None = None) -> None:
    size_mb = src.stat().st_size / 1024 / 1024
    if size_mb > cfg["max_mb"]:
        raise RuntimeError(f"Datei ist {size_mb:.0f} MB (Limit {cfg['max_mb']} MB)")

    with tempfile.TemporaryDirectory(prefix="send2rm-") as tmpdir:
        tmp = Path(tmpdir)
        payload = convert(src, tmp, cfg)

        # Der Dateiname wird zum Titel auf dem Geraet
        title = unique_title(forced_title or apply_rename(src.stem, rename or []), taken)
        staged = tmp / f"{title}{payload.suffix}"
        if payload.resolve() != staged.resolve():
            shutil.copy2(payload, staged)

        res = rmapi(cfg, "put", str(staged), folder)
        if res.returncode != 0:
            raise RuntimeError((res.stderr or res.stdout).strip()[:300] or "rmapi put fehlgeschlagen")
        log.info("hochgeladen: %s -> %s/%s%s", src.name, folder.rstrip("/"), title, payload.suffix)


# --------------------------------------------------------------------------- quellen scannen

def is_stable(path: Path, wait: float) -> bool:
    """Wartet kurz und prueft, ob die Datei noch waechst (Kopie, Download, Ghostscript)."""
    try:
        first = path.stat()
        time.sleep(wait)
        second = path.stat()
    except FileNotFoundError:
        return False
    return first.st_size == second.st_size and first.st_mtime == second.st_mtime


def scan_source(source: dict, state: dict) -> list[Path]:
    directory = source["path"]
    if source["move"]:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Uploaded").mkdir(exist_ok=True)
        (directory / "Failed").mkdir(exist_ok=True)
    elif not directory.is_dir():
        log.warning("Quelle fehlt: %s", directory)
        return []

    now = time.time()
    seen: set[Path] = set()
    out: list[Path] = []
    # Unterordner werden spaeter 1:1 in der Cloud gespiegelt
    iterator = directory.rglob if source["subfolders"] else directory.glob

    for pattern in source["patterns"]:
        for entry in sorted(iterator(pattern)):
            if entry in seen or entry.is_dir():
                continue
            seen.add(entry)
            rel = entry.relative_to(directory)
            if any(part.startswith(".") for part in rel.parts):
                continue
            if set(rel.parts[:-1]) & ARCHIVE_DIRS:
                continue
            if set(s.lower() for s in entry.suffixes) & SKIP_SUFFIX:
                continue
            if source["max_age_days"] and (now - entry.stat().st_mtime) > source["max_age_days"] * 86400:
                continue
            if not source["move"] and already_sent(state, entry):
                continue
            out.append(entry)
    return out


def cloud_folder(base: str, rel_dir: Path) -> str:
    """Unterordner der Quelle 1:1 auf den Cloud-Pfad abbilden."""
    base = base.rstrip("/")
    if str(rel_dir) in (".", ""):
        return base or "/"
    return f"{base}/{rel_dir.as_posix()}"


def cleanup_archive(directory: Path, days: float) -> None:
    """Alte Dateien aus Uploaded/ entfernen — sonst waechst das Archiv endlos.

    0 schaltet die Aufraeumerei ab.
    """
    if not days or not directory.is_dir():
        return
    cutoff = time.time() - days * 86400
    for entry in directory.rglob("*"):
        if not entry.is_file() or entry.name.startswith("."):
            continue
        if entry.stat().st_mtime >= cutoff:
            continue
        try:
            entry.unlink()
            log.info("Archiv aufgeraeumt (aelter als %g Tage): %s", days, entry.name)
        except OSError as exc:
            log.warning("konnte %s nicht loeschen: %s", entry, exc)


def archive(src: Path, target_dir: Path) -> None:
    target_dir.mkdir(parents=True, exist_ok=True)
    dest = target_dir / src.name
    if dest.exists():
        dest = target_dir / f"{src.stem} {datetime.now():%Y-%m-%d %H%M%S}{src.suffix}"
    shutil.move(str(src), str(dest))


def acquire_lock(wait: bool):
    """Serialisiert launchd-Scan, Droplet und Skript-Hooks.

    Ein Scan bricht ab, wenn schon einer laeuft — er wiederholt sich ohnehin.
    Ein expliziter Upload wartet stattdessen, sonst ginge die Datei verloren.
    """
    handle = (Path(tempfile.gettempdir()) / "send2rm.lock").open("w")
    deadline = time.time() + 900
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if not wait:
                log.info("laeuft bereits — beende")
                sys.exit(0)
            if time.time() > deadline:
                raise RuntimeError("anderer send2rm-Lauf blockiert seit 15 Minuten")
            time.sleep(2)


# --------------------------------------------------------------------------- ablauf

class Uploader:
    """Haelt die Ordner-Inhalte pro Zielordner, damit rmapi ls nicht pro Datei laeuft."""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self._taken: dict[str, set[str]] = {}

    def taken(self, folder: str) -> set[str]:
        if folder not in self._taken:
            ensure_folder(self.cfg, folder)
            self._taken[folder] = existing_names(self.cfg, folder)
        return self._taken[folder]

    def send(self, path: Path, folder: str, rename: list[dict] | None = None,
             title: str | None = None) -> None:
        send_file(path, self.cfg, folder, self.taken(folder), rename, title)


def scan_all(cfg: dict, uploader: Uploader) -> tuple[int, int]:
    state = prune_state(load_state(cfg))
    ok = failed = 0

    for source in get_sources(cfg):
        candidates = [p for p in scan_source(source, state)
                      if is_stable(p, source["stable_wait"])]
        if not candidates:
            continue
        log.info("%s: %d Datei(en)", source["path"], len(candidates))

        for path in candidates:
            rel_dir = path.parent.relative_to(source["path"])
            try:
                uploader.send(path, cloud_folder(source["target_folder"], rel_dir),
                              source["rename"])
                ok += 1
                if source["move"]:
                    if cfg["keep_uploaded"]:
                        archive(path, source["path"] / "Uploaded" / rel_dir)
                    else:
                        path.unlink()
                else:
                    state[str(path)] = fingerprint(path)
                    save_state(cfg, state)  # sofort sichern, sonst droht ein Doppel-Upload
            except Exception as exc:  # noqa: BLE001 — jede Datei einzeln ueberleben
                failed += 1
                log.error("FEHLER bei %s: %s", path.name, exc)
                notify(cfg, "reMarkable: Fehler", f"{path.name}: {exc}")
                if source["move"]:
                    archive(path, source["path"] / "Failed" / rel_dir)

        if source["move"] and cfg["keep_uploaded"]:
            cleanup_archive(source["path"] / "Uploaded", cfg["cleanup_uploaded_days"])

    save_state(cfg, state)
    return ok, failed


def send_explicit(paths: list[Path], cfg: dict, uploader: Uploader, folder: str,
                  title: str | None = None) -> tuple[int, int]:
    ok = failed = 0
    for path in paths:
        try:
            uploader.send(path, folder, title=title if len(paths) == 1 else None)
            ok += 1
        except Exception as exc:  # noqa: BLE001
            failed += 1
            log.error("FEHLER bei %s: %s", path.name, exc)
            notify(cfg, "reMarkable: Fehler", f"{path.name}: {exc}")
    return ok, failed


def main() -> int:
    parser = argparse.ArgumentParser(description="Dateien ans reMarkable schicken")
    parser.add_argument("files", nargs="*", type=Path, help="Dateien zum Hochladen")
    parser.add_argument("--scan", action="store_true", help="konfigurierte Quellen abarbeiten")
    parser.add_argument("--folder", help="Zielordner in der Cloud (ueberschreibt config.toml)")
    parser.add_argument("--title", help="Titel auf dem Geraet (nur bei genau einer Datei)")
    parser.add_argument("--check", action="store_true", help="Setup und Kopplung pruefen")
    args = parser.parse_args()

    cfg = load_config()
    setup_logging(cfg)

    if not Path(cfg["rmapi"]).exists():
        print(f"rmapi fehlt: {cfg['rmapi']} — bitte ./install.sh ausfuehren", file=sys.stderr)
        return 2

    if args.check:
        res = rmapi(cfg, "ls", "/", timeout=60)
        if res.returncode != 0:
            print("rmapi ist noch nicht autorisiert.\n"
                  f"  {cfg['rmapi']}\n"
                  "starten und den 8-stelligen Code von\n"
                  "  https://my.remarkable.com/device/desktop/connect\n"
                  f"eingeben.\n\nFehler: {(res.stderr or res.stdout).strip()[:300]}", file=sys.stderr)
            return 1
        print("OK — rmapi ist verbunden. Wurzelverzeichnis der Cloud:")
        print(res.stdout.strip() or "(leer)")
        print("\nQuellen:")
        for source in get_sources(cfg):
            modus = "verschiebt nach Uploaded/" if source["move"] else "laesst Dateien liegen"
            print(f"  {source['path']}  ->  {source['target_folder']}"
                  f"  [{', '.join(source['patterns'])}, {modus}]")
        return 0

    lock = acquire_lock(wait=not args.scan)  # noqa: F841 — Lock haelt bis Prozessende
    uploader = Uploader(cfg)

    if args.scan:
        ok, failed = scan_all(cfg, uploader)
    else:
        if not args.files:
            parser.print_help()
            return 2
        missing = [p for p in args.files if not p.exists()]
        for path in missing:
            print(f"nicht gefunden: {path}", file=sys.stderr)
        ok, failed = send_explicit(
            [p for p in args.files if p.exists()], cfg, uploader,
            args.folder or cfg["target_folder"], args.title,
        )
        failed += len(missing)

    if ok:
        plural = "Dokument" if ok == 1 else "Dokumente"
        notify(cfg, "reMarkable", f"{ok} {plural} hochgeladen")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
