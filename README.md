<p align="center">
  <img src="docs/icon.png" width="128" alt="Remacable">
</p>

<h1 align="center">Remacable</h1>

<p align="center">Send files to your reMarkable — no subscription, root access, or third-party service required.</p>

<p align="center">English · <a href="README.de.md">Deutsch</a></p>

<p align="center">
  <img src="docs/hero-and-menu.png" width="700" alt="Remacable in the menu bar">
</p>

Remacable is a small Mac app that lives in the menu bar. Drop a file onto the
bird or place it in a watched folder: it is uploaded to your reMarkable cloud,
and your tablet picks it up during its next sync.

The tablet itself stays untouched. Uploads use the same interface as the
official desktop app. You do not need **reMarkable Connect**, custom access to
the device, or a third-party server.

## What it is useful for

* Automatically send **newspapers, newsletters, and reports** to the tablet as
  soon as another app saves them to a folder.
* Skip manual conversion for **Word, Excel, PowerPoint, and images**. reMarkable
  accepts only PDF and EPUB, so Remacable converts other formats automatically.
* Send an occasional file by dropping it onto the menu bar icon.

## Installation

**1. Get the app.** Download the built app from
[Releases](https://github.com/noestreich/Remacable/releases), unzip it, and move
it to *Applications*. It is signed and notarized by Apple, so it opens without
a warning. You can also build it yourself using the instructions below.

**2. Install the helper.** The Settings window opens on first launch. Under
**General → rmapi → Install**, Remacable downloads the upload tool itself—one
click, with no Terminal work.

**3. Pair your account.** Click **Pair…** to open `my.remarkable.com`, get an
8-character code, and enter it in the app. Remacable registers as an additional
device that you can remove from your reMarkable account at any time.

<p align="center">
  <img src="docs/allgemein.png" width="620" alt="Settings, General tab">
</p>

When both status indicators are green, everything is ready. Enable **Launch at
Login** if you want Remacable to start automatically after a restart. You can
also choose **System Default**, **English**, or **Deutsch** under **Language**.

## Three ways to upload

| Method | How it works |
|---|---|
| **Drag and drop** | Drop a file onto the bird in the menu bar |
| **Watch folder** | Put a file in `~/reMarkable Inbox` for automatic upload |
| **Choose files** | Select *Choose Files…* from the menu |

You receive a short notification after an upload. The document appears on the
tablet once it is awake and connected to Wi-Fi.

## Watching folders

You can add as many watched folders as you need. Anything placed in them is
uploaded automatically, which is useful for files another app produces on a
schedule, such as a daily newspaper download.

<p align="center">
  <img src="docs/ordner.png" width="620" alt="Settings, Folders tab">
</p>

Each folder has its own settings:

| Setting | What it does |
|---|---|
| **Destination folder in the cloud** | Places the document in a folder such as `/Newspapers` |
| **Mirror subfolders** | Recreates the folder structure on the tablet |
| **After upload** | Leaves the file in place or moves it to `Uploaded/` |
| **File patterns** | Includes only matching files, such as `Newspaper_*.pdf` |
| **Only recent files** | Skips older files when watching is enabled |
| **Wait before uploading** | Avoids reading a file before another app has finished writing it |
| **Rename** | Turns `BMP_2026_23082026` into `Morning News 2026-08-23` |

Two safeguards help prevent surprises:

* **New folders start disabled.** Configure the folder first, then enable it.
  If matching files are already present, Remacable asks whether to upload them
  or watch only for future files.
* **Folders managed by other apps stay untouched.** By default, nothing is
  moved or deleted and no subfolders are created.

The **Current Status** section shows what would be uploaded right now and, when
nothing is pending, why.

## Follow activity in the log

<p align="center">
  <img src="docs/protokoll.png" width="620" alt="Settings, Log tab">
</p>

## Formats

reMarkable accepts only **PDF** and **EPUB**. Remacable converts other formats
before uploading them, using a helper application where needed:

| Input | Output | Requires |
|---|---|---|
| PDF, EPUB | — | nothing |
| Word, Excel, PowerPoint, RTF, ODT, CSV | PDF | [LibreOffice](https://www.libreoffice.org) |
| Text, Markdown, HTML, MOBI, AZW3 | EPUB | [Calibre](https://calibre-ebook.com) |
| JPG, PNG, HEIC, TIFF | PDF | nothing (built into macOS) |

The *General* tab shows a green indicator beside each helper that is available.
If one is missing, only the formats that depend on it are unavailable.

## Good to know

* Uploads happen only **while the app is running**, so enable **Launch at
  Login** for continuous watching.
* The reMarkable interface used by the app is **unofficial**. If uploads stop
  working, updating *rmapi* will often help; the app shows when a newer version
  is available.
* macOS may ask for permission when you watch a folder in *Downloads*,
  *Documents*, or on the Desktop.
* Files go only to reMarkable using your own pairing, never through another
  service.

## Building from source

Xcode or the Command Line Tools are required:

```bash
./build.sh
```

This creates `Remacable.app`. If a “Developer ID Application” certificate is
available in the keychain, the app is signed with Hardened Runtime and a secure
timestamp. Otherwise, it is signed ad hoc.

For a release, store the notarization credentials once and submit the built
archive to Apple:

```bash
xcrun notarytool store-credentials "Remacable" --apple-id "YOUR-APPLE-ID" --team-id YOUR-TEAM-ID
ditto -c -k --keepParent --sequesterRsrc Remacable.app Remacable.zip
xcrun notarytool submit Remacable.zip --keychain-profile "Remacable" --wait
xcrun stapler staple Remacable.app   # package it again afterward
```

The menu bar icon is generated from a monochrome source image. The tool trims
the edges and scales it to the requested height:

```bash
swift Tools/make-menubar-icon.swift source.png Resources/MenuBarIcon.png 44
```

The code lives in `Sources/Remacable/`: `UploadEngine` collects, converts, and
uploads files; `Watching` uses FSEvents; `RmapiClient` communicates with the
cloud; and the remaining files implement the interface.

## Acknowledgments

The core upload work is handled by **[ddvk/rmapi](https://github.com/ddvk/rmapi)**,
which communicates with the reMarkable cloud API. Remacable downloads rmapi
during setup, keeps it current, and provides the interface around it.

rmapi originated with [juruen/rmapi](https://github.com/juruen/rmapi); ddvk's
fork maintains support for the newer sync protocol. Both are licensed under
AGPL-3.0. Remacable invokes rmapi unchanged as a separate program rather than
embedding it.

reMarkable is not affiliated with this project, and the interface it uses is
not officially documented.
