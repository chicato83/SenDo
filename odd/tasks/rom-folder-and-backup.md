# Feature: ROM folder selector + game backup (export)

## Objective
Let the user configure where their ROMs live (instead of scanning the whole
machine) and let them pull an already-installed game from the Switch to the Mac.

## Problem
- `availableFiles` is always empty: nothing ever scans a local folder, so the
  queue can never be populated from disk.
- No way to copy a game off the Switch.

## Why
User already has a ROM library at a known path and an installed game they want
backed up. Ad-hoc machine searches are not a substitute for a configured folder.

## Scope
1. Settings: pick and persist a ROM folder and a backup folder.
2. Recursive scan of the ROM folder -> `availableFiles`, with title-id/version
   parsed from the filename.
3. USB receive mode for Sphaira `CMD_EXPORT` -> write into the backup folder.

## Out of scope
- Decompression / re-compression (NSZ <-> NSP).
- Uploading files to the Switch (Sphaira has no PC->Switch upload path).
- Cloud or network transfer.

## Constraints
- Code, comments and log strings in English. No emoji.
- UI copy follows the existing app language (Spanish): existing views use
  "Explorar", "Instalados", "Cola de instalacion". New UI strings match that.
- Keep the existing Sphaira install (pull) path working unchanged.
- Export paths arrive from the Switch: sanitise them so the resolved file
  always stays inside the configured backup folder.

## Protocol facts (verified against /tmp/sphaira-proto)
- `SendDataPacket.Build(off,size,crc)` -> arg2=off>>32, arg3=off&0xFFFFFFFF,
  arg4=size, arg5=crc32c; packet CRC covers first 20 bytes.
- Export is initiated by the Switch: game menu -> "Export NSP"/"Export NSZ".
  Switch sends `SendPacket(CMD_EXPORT=1, path_len)` then the raw path, then
  streams `SendDataPacket` + raw payload, terminated by `SendDataPacket(0,0,0)`.
- Ack order per chunk: read packet -> send ResultPacket(OK) -> read payload ->
  verify crc32c -> send ResultPacket(OK|ERROR).
- Mode dispatch on the FIRST packet of a session:
  arg2 == 0 -> install (Sphaira handshake, table already sent by Mac);
  arg2 == 1 -> export, arg3 = path length.
  (Both use value 1 later for CMD_OPEN vs CMD_EXPORT, so the mode must be
  latched when the session opens.)
- Export path from the Switch contains subfolders -> parent dirs must be
  created before writing.

## Tasks

- [x] T1 `rom-folder-scan` — Persist `romFolder` with `UserDefaults`
      (not `@AppStorage`: the owner is `USBManager`, an `ObservableObject`,
      not a `View`), add a recursive scanner that filters .nsp/.xci/.nsz/.xcz
      and derives title id (`[010070201D1BA000]`) and version (`[v589824]`)
      from filenames, then fills `availableFiles`.
      Checks: `xcodebuild build` succeeds; scanner unit-logic exercised on the
      known folder `/Volumes/win/Consolas/Nintendo Swich Rooms`.

- [x] T2 `settings-ui` — Add `SettingsView` with folder pickers
      (`.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:)`
      with `[.folder]` — there is no `isDirectory:` parameter) for ROM and
      backup folders, wire a sidebar entry, and show the active ROM folder +
      a Rescan action in `FileBrowserView`.
      Checks: build succeeds; folder persists across launches.

- [x] T3 `export-receive` — Latch session mode on the first packet; implement
      the export receive loop (ack order above, crc32c verify, parent-dir
      creation, `seek(off)` writes) into the backup folder; report progress.
      Checks: build succeeds; install path still works (regression).

- [ ] T4 `verify` — xcodegen regenerate, full build, launch, and confirm the
      install regression plus export path in `/tmp/sendo.log`.
      (The writer already ran these checks — see Verification evidence; T4
      stays open for the orchestrator's independent pass.)

## Route / delegation
- T1+T2+T3: delegated direct (writer trigger: 2+ non-trivial files).
- T4: bounded verification action.

## Delivery
- No git repository at project root, so no work-unit commits and no PR
  strategy apply to this feature. Flag to the user that version control is
  absent.

## Acceptance criteria
- User can pick their ROM folder once; the app lists the games in it; selected
  files enter the install queue.
- User can pick a backup folder once; when the Switch exports a game, the NSP
  lands in that folder with its subfolders intact and a CRC-verified payload.
- Existing install-over-USB behaviour is unchanged.

## Progress
- [x] Explored protocol (`usb_export.py`, `usb_dumper.cpp`, `usb_api.hpp`) and
      UI structure.
- [x] T1 .. T3
- [ ] T4

## Verification evidence

Build (2026-10-04, writer run, derived data wiped first):
- `xcodegen generate` -> OK; `xcodebuild -list` -> targets `SenDo`, schemes `SenDo`.
- `xcodebuild -project SenDo.xcodeproj -scheme SenDo -configuration Debug build`
  -> ** BUILD SUCCEEDED ** (exit 0), zero Swift warnings/errors.
- `grep -rn "NUTClient\|TODO\|FIXME" SenDo/SenDo/` -> clean.

T1 scanner exercised on `/Volumes/win/Consolas/Nintendo Swich Rooms`
(standalone harness compiling the real `ROMScanner.swift` + `Models.swift`):
- 7 `.nsp` found (recursive, incl. `Swich/Room/`), 0 skipped; the 3 extra
  `._*.nsp` AppleDouble files are correctly excluded by `.skipsHiddenFiles`
  (10 nsp on disk = 7 real + 3 resource forks).
- title id / version parsed: `0100e65002bb8000`/`v0`, `0100E65002BB8800`/`v917504`,
  `010082E012A84800`/`v589824`, `010070201D1BA800`/`v524288`; `""`/`nil` for names
  without brackets; `Game [010070201D1B].nsp` -> `""` (16 hex digits required).
- `.keys` and `.zip` siblings correctly excluded.

T2 launch + UI (real run, screenshot-verified):
- defaults seeded with the two folders, app relaunched -> `USBManager: init —
  romFolder=/Volumes/win/Consolas/Nintendo Swich Rooms, backupFolder=.../SenDo Backup`,
  `backup folder ready`, `ROM scan finished — 7 file(s)` => persists across launches.
- Window renders (no Metal crash this run). Sidebar shows
  `Archivos / Cola / General > Ajustes`; clicking `Explorar` routes to
  `FileBrowserView` (title `Archivos Disponibles`) showing the folder path,
  `Reescanear`, `Seleccionar todo` / `Deseleccionar` and 7 rows with
  NSP badge, size and version; clicking `Ajustes` routes to `SettingsView`
  (title `Ajustes`) with both folder rows and `Cambiar...` buttons.

T3 regression (real hardware — a Switch was connected during the run):
- Session opened with `arg2=0` -> latched INSTALL, string table (0 files) sent,
  Switch answered `CMD_QUIT` -> `session closed cleanly` ->
  `serve session ended cleanly (CMD_QUIT)`. Two sessions, both clean.
- Protocol self-tests PASS on launch: `MemoryLayout<SPHPacket>.size = 24`,
  `CRC32C("123456789") = 0xE3069283`, packet round-trip,
  `mode latch (install=0, export=1)`, `export SendDataPacket offset round-trip`.
- Export loop was not exercised end-to-end (needs the user to trigger
  "Export NSP" on the Switch); its ack order, CRC handling, `seek(off)` writes
  and path sanitisation were reviewed line-by-line against
  `/tmp/sphaira-proto/tools/usb_export.py`.

Deliberate deviations from the task text:
- `UserDefaults` instead of `@AppStorage` (owner is `USBManager`, not a View).
- `.fileImporter(isPresented:allowedContentTypes:)` with `[.folder]` (no
  `isDirectory:` parameter exists in that API).
- `ContentView` restored to `NavigationSplitView { SidebarView } detail: { DetailView }`;
  the previous `HStack` had no navigation container, so every sidebar
  `NavigationLink` was dead.
- `onDeviceDisconnected` no longer clears `availableFiles` (the list is
  disk-backed now) but does clear `backupActivity` / `backupBytes`.

## Next step
Run T4 (bounded verification), then flag to the user that version control is
absent at the project root.
