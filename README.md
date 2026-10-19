# SupernoteIOS

A Supernote client for iPhone and iPad that **syncs as if it were a Supernote device**. Each iOS device logs in with its own `equipmentNo`, so the cloud treats your Nomad, iPhone and iPad mini as three Supernotes on one account.

| | Status |
|---|---|
| Device login (`login/equipment` + bind) | ✅ |
| Two-way sync: list / download / upload / delete, sync lock, conflict copies | ✅ tested against [allenporter/supernote](https://github.com/allenporter/supernote) |
| `.note` rendering (Nomad / A6X2, Manta, A5X, A6X, landscape, layers) | ✅ pixel-identical to supernotelib |
| PDF / EPUB / images | ✅ PDFKit / QuickLook |
| **Editing** with Apple Pencil, written into the `.note` (strokes + bitmap), syncs back to the Nomad | 🧪 beta (validated with supernotelib and allenporter's parser; on-device check pending) |
| Nomad UI: fixed toolbar, page-number bar, sidebar gestures, e-ink panels | ✅ |
| Tools: needle-point / ink pen / marker, 4 grays, stroke eraser, region eraser, erase all, lasso move/delete, 20-step undo/redo | ✅ |
| New notes (blank / 5 mm dots), add page | ✅ |
| Landscape pages, extra layers, headings/keywords editing, text boxes | view-only |
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

## How editing works

A Nomad page stores the same ink in two places:

- **TOTALPATH**: vector strokes. Each one has its points, pressure, pen, color and width, plus the outline contours the device rasterizes.
- **MAINLAYER**: the RATTA_RLE bitmap the screen actually shows.

`PageEditor` keeps both in sync:

- **New strokes** become TOTALPATH objects. Every field we don't model (timing, trailer) is cloned from a real stroke in the same file, or from a bundled Nomad template. The new stroke is then painted onto the existing bitmap, so the original ink stays byte-identical.
- **Erase, lasso move and undo** rebuild the bitmap from every stroke's contours. That matches the device's own rendering at about 96% IoU.
- **`NoteWriter`** writes *append-only*: the original bytes stay put, and the new bitmap, TOTALPATH, layer and page metadata, and footer are appended. The result is re-parsed before it touches disk.
- **Backups:** the pre-edit version of each note goes to `Application Support/Backups`.

### Verify on your Nomad (before trusting it with real notes)

```sh
swift build
.build/debug/snsync new  test.note dots 2              # fresh 2-page note
.build/debug/snsync scribble test.note test-edited.note # adds 3 test strokes
```

Copy `test-edited.note` to the Nomad's `Note/` folder (USB or sync) and open it. The three waves should appear, and you should be able to erase and lasso them. Then draw one stroke with each pen on the Nomad, sync, and run `snsync strokes <file>` to confirm the pen-type codes (`PenType` in `TotalPath.swift`).

## Credits

The `.note` format and decoder are ported from [jya-dev/supernote-tool](https://github.com/jya-dev/supernote-tool) (Apache-2.0). The protocol comes from [allenporter/supernote](https://github.com/allenporter/supernote) (Apache-2.0). Unofficial; not affiliated with Ratta.
