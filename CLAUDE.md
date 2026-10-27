# SupernoteIOS

A Supernote client for iPhone and iPad that syncs as its own Supernote device: two-way sync,
`.note` rendering, and Apple Pencil editing written back into the `.note`. The house rules, pipeline
and skills come from the gi-os kit, loaded at session start (`.gios/`, read-only here).

- Code: `App/SupernoteIOS` app (SwiftUI); `Sources/NoteKit` (.note format, rendering, editing),
  `Sources/SyncKit` (device login, sync engine), `Sources/snsync` CLI: a Swift package tested with
  `swift test`, on macOS in Check (PRE_TEST) and on Linux in `ci.yml`. Keep the package
  Foundation-only so the Linux job stays green. In a cloud session you can run `swift test` for it
  if a Swift toolchain is installed.
- Test fixtures in `Tests/NoteKitTests/Fixtures`; rendering must stay pixel-identical to supernotelib.
