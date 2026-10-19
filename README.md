# SupernoteIOS

A Supernote client for iPhone and iPad that **syncs as if it were a Supernote device**. Each iOS device logs in with its own `equipmentNo`, so the cloud treats your Nomad, iPhone and iPad mini as three Supernotes on one account.

| | Status |
|---|---|
| Device login (`login/equipment` + bind) | ✅ |
| Two-way sync: list / download / upload / delete, sync lock, conflict copies | ✅ tested against [allenporter/supernote](https://github.com/allenporter/supernote) |
| `.note` rendering (Nomad / A6X2, Manta, A5X, A6X, landscape, layers) | ✅ pixel-identical to supernotelib |
| PDF / EPUB / images | ✅ PDFKit / QuickLook |
| Pen (Apple Pencil, PencilKit layer per page) | 🧪 beta, strokes stay on-device |
| Pen write-back into `.note` (syncs to the Nomad) | ⏳ next |
| Background sync | ⏳ |

## Layout

```
Package.swift                 SupernoteKit (SwiftPM; builds on macOS, iOS, Linux)
Sources/NoteKit/              .note parser + RATTA_RLE decoder + layer compositor
Sources/SyncKit/              device API client, 3-way sync planner, SyncEngine
Sources/snsync/               CLI harness (info / render / ls / sync)
App/SupernoteIOS/             SwiftUI app (iPhone + iPad), PencilKit ink layer
project.yml                   XcodeGen spec for the app
```

## Run the app

```sh
brew install xcodegen
xcodegen                      # generates SupernoteIOS.xcodeproj
open SupernoteIOS.xcodeproj   # set your Team, run on the iPhone or iPad mini
```

Sign in with your server URL and Supernote account. Synced files land in `Documents/Supernote`, which you can also see in Files.app.

## Server

The client works with any server that speaks the Supernote device API:

- **[Supernote Private Cloud](https://support.supernote.com/setting-up-your-own-supernote-private-cloud-beta)**: Ratta's official Docker server (recommended; good fit for BasilNet).
- **[allenporter/supernote](https://github.com/allenporter/supernote)**: an open-source, SQLite-based server (`pip install "supernote[server]" && supernote serve`).
- **cloud.supernote.com**: works the same way, but registering a non-Ratta "device" on Ratta's cloud is likely against their ToS. Use at your own risk.

## CLI

```sh
swift build
.build/debug/snsync info  note.note
.build/debug/snsync render note.note out/          # PGM per page

export SN_SERVER=http://127.0.0.1:8080 SN_ACCOUNT=you@example.com SN_PASSWORD=… SN_EQUIPMENT=SN100BMYMAC0001
.build/debug/snsync ls
.build/debug/snsync sync ./mirror
```

## Pen roadmap

1. ✅ PencilKit canvas per page, stored in Supernote pixel space (1404×1872 on Nomad), outside the sync mirror.
2. Convert `PKStroke` points and pressure into Supernote strokes, rasterize them into MAINLAYER (RATTA_RLE encoder) and append TOTALPATH.
3. Re-write the `.note` file (new blocks + footer), then let `SyncEngine` upload it so the Nomad picks up the edit.
   Reference: allenporter/supernote's experimental `reconstruct` / `merge` commands.

## Credits

The `.note` format and decoder are ported from [jya-dev/supernote-tool](https://github.com/jya-dev/supernote-tool) (Apache-2.0). The protocol comes from [allenporter/supernote](https://github.com/allenporter/supernote) (Apache-2.0). Unofficial; not affiliated with Ratta.
